// SPDX-License-Identifier: GPL-2.0-only
// Translates the switch.* part of system_cfg into netifd UCI (network) and
// switchdev-config UCI (switchdev). Edits a uci cursor; never commits.
//
// What the controller sends, and the UCI it becomes:
//   switch.vlan.M.{id,mode,status}         bridge-vlan per VLAN id; mode is the
//   switch.vlan.M.port.N.mode              default membership, port keys override
//   switch.port.N.pvid                     the port's untagged VLAN ("u*")
//   switch.port.N.status=disabled          device enabled 0
//   switch.port.N.{autoneg,speed,duplex}   device autoneg/speed/duplex
//   switch.port.N.flowctrl=enabled         device pause (absent: off)
//   switch.port.N.eee                      device eee
//   switch.port.N.isolation=enabled        device isolate
//   switch.port.N.opmode=aggregate, lag=L  bonding device lagL, 802.3ad
//   switch.port.N.opmode=mirror, mirror_port=S  switchdev mirror S -> N
//   switch.port.N.egress_rate_limit_kbps   switchdev ratelimit egress
//   switch.port.N.poe                      device pse (PoE-capable ports only)
//   switch.jumboframes, switch.mtu         device mtu on every port and bridge
//   switch.stp.{status,version,priority}   bridge stp, stp_proto, priority
//   switch.vlan.M.igmp_*                   bridge igmp_snooping, bridge-vlan
//                                          mcast_snooping / mcast_querier,
//                                          device multicast_fast_leave
// Anything else under switch.* is reported back as unhandled.

import { stat, readfile } from 'fs';
import { setopt, matches_any, bridge_members, uci_list } from 'unifi.util';

const HANDLED = [
	/^switch\.vlan\.[0-9]+\.(id|mode|status|igmp_snooping|igmp_fastleave|igmp_querier_status)$/,
	/^switch\.vlan\.[0-9]+\.port\.[0-9]+\.mode$/,
	/^switch\.port\.[0-9]+\.(name|opmode|lag|pvid|status|autoneg|speed|duplex|flowctrl|eee|isolation|mirror_port|egress_rate_limit_kbps|poe)$/,
	/^switch\.(managementvlan|jumboframes|mtu|stp\.status|stp\.version|stp\.priority)$/,
	// Informational or controller-internal: nothing to apply.
	/^switch\.(wevent\.|power_source\.|routing_enabled)/,
	/^switch\.vlan\.[0-9]+\.igmp_(maxresponse|mcrtrexpiretime|groupmembership|supression|querier)$/,
	/^switch\.multicast\./
];

export function handled(key) {
	return matches_any(HANDLED, key);
};

// Whether the optional switchdev-config package is installed.
export function has_switchdev() {
	return !!stat('/etc/init.d/switchdev');
};

// LACP needs the bonding driver, loaded or installed.
function has_bonding() {
	return !!(stat('/sys/module/bonding') || stat('/sys/class/net/bonding_masters') ||
		stat(`/lib/modules/${trim(readfile('/proc/sys/kernel/osrelease') ?? '')}/bonding.ko`));
}

// switch_caps for the inform, from what this device can carry out.
export function caps() {
	let sd = has_switchdev();

	return {
		feature_caps: 4 | 64 | 256 | 524288 | (sd ? 32 : 0) | (has_bonding() ? 8192 : 0),
		max_aggregate_sessions: 3,
		max_mirror_sessions: sd ? 1 : 0,
		stp_caps: 0,
		vlan_caps: 7
	};
};

function find_section(c, pkg, type, match_fn) {
	let found = null;

	c.foreach(pkg, type, (s) => {
		if (!found && match_fn(s))
			found = s['.name'];
	});

	return found;
}

function ensure_device(c, name) {
	let sec = find_section(c, 'network', 'device', (s) => s.name == name);

	if (!sec) {
		sec = 'unifi_' + replace(name, /[^A-Za-z0-9_]/g, '_');
		c.set('network', sec, 'device');
		c.set('network', sec, 'name', name);
	}

	return sec;
}

// Parsed view of the switch.* keys.
export function parse(cfg) {
	let vlans = {}, ports = {};

	for (let k, v in cfg) {
		let m;

		if ((m = match(k, /^switch\.vlan\.([0-9]+)\.port\.([0-9]+)\.mode$/))) {
			vlans[m[1]] ??= { ports: {} };
			vlans[m[1]].ports[m[2]] = v;
		}
		else if ((m = match(k, /^switch\.vlan\.([0-9]+)\.([a-z_]+)$/))) {
			vlans[m[1]] ??= { ports: {} };
			vlans[m[1]][m[2]] = v;
		}
		else if ((m = match(k, /^switch\.port\.([0-9]+)\.(.+)$/))) {
			ports[m[1]] ??= {};
			ports[m[1]][m[2]] = v;
		}
	}

	return { vlans, ports };
};

// VLAN membership per UniFi port: { vid: { idx: 'u*' | 'u' | 't' } }.
export function membership(sw, nports) {
	let out = {}, native = null;

	for (let slot, v in sw.vlans)
		if (v.status != 'disabled' && v.mode == 'untagged')
			native ??= +v.id;

	native ??= 1;

	for (let slot, v in sw.vlans) {
		if (v.status == 'disabled' || v.id == null)
			continue;

		let vid = +v.id, members = {};

		for (let n = 1; n <= nports; n++) {
			let port = sw.ports[n] ?? {};
			let mode = v.ports[n] ?? v.mode;
			let pvid = +(port.pvid ?? native);

			if (port.opmode == 'mirror')
				continue;

			if (pvid == vid && mode != 'exclude')
				members[n] = 'u*';
			else if (mode == 'tagged')
				members[n] = 't';
			else if (mode == 'untagged')
				members[n] = 'u';
		}

		out[vid] = members;
	}

	return out;
};

// Applies the switch.* keys to cursor c. Returns notes (strings).
export function plan(cfg, profile, c) {
	let notes = [];
	let sw = parse(cfg);
	let bridge = profile.bridge;
	let brsec = find_section(c, 'network', 'device', (s) => s.type == 'bridge' && s.name == bridge);

	if (!brsec)
		return [ `bridge ${bridge} not found in network config; switch settings skipped` ];

	let by_idx = {};

	for (let p in profile.ports)
		by_idx[p.idx] = p;

	for (let n in keys(sw.ports))
		if (!by_idx[n])
			push(notes, `UniFi port ${n} has no local port; its settings are ignored`);

	// Link aggregation: one bond per lag id, named lagL, holding its members.
	let lags = {}, lag_of = {};

	for (let n, sp in sw.ports) {
		if (sp.opmode == 'aggregate' && sp.lag && by_idx[n]) {
			lags[sp.lag] ??= [];
			push(lags[sp.lag], +n);
			lag_of[n] = `lag${sp.lag}`;
		}
	}

	// Without the management VLAN among the controller's VLANs, bonds,
	// bridge ports and VLANs stay as they are: changing them alone could
	// leave ports, or the device itself, without a VLAN.
	let mvid = +(cfg['switch.managementvlan'] ?? 1);
	let members = membership(sw, length(profile.model_ports));
	let vlan_ok = members[mvid] != null;
	let managed = {}, brports = bridge_members(c, bridge);

	for (let p in profile.ports)
		managed[p.dev] = p.idx;

	// The bonds this agent created, by device name; other bonds are the user's.
	let own_bonds = {};

	c.foreach('network', 'device', (s) => {
		if (s.type == 'bonding' && match(s['.name'], /^unifi_lag[0-9]+$/))
			own_bonds[s.name] = true;
	});

	for (let l in keys(lags))
		own_bonds[`lag${l}`] = true;

	if (vlan_ok) {
		let bonds = {};

		c.foreach('network', 'device', (s) => {
			if (s.type == 'bonding' && match(s['.name'], /^unifi_lag[0-9]+$/))
				bonds[s['.name']] = true;
		});

		for (let l, members in lags) {
			let sec = `unifi_lag${l}`;

			if (!bonds[sec]) {
				c.set('network', sec, 'device');
				c.set('network', sec, 'type', 'bonding');
			}

			delete bonds[sec];
			setopt(c, 'network', sec, 'name', `lag${l}`);
			setopt(c, 'network', sec, 'ports', map(sort(members, (a, b) => a - b), (n) => by_idx[n].dev));
			setopt(c, 'network', sec, 'policy', '802.3ad');
			setopt(c, 'network', sec, 'xmit_hash_policy', 'layer2+3');
			setopt(c, 'network', sec, 'lacp_rate', 'slow');
		}

		for (let sec in keys(bonds))
			c.delete('network', sec);

		// Bridge ports: members of a lag are replaced by the bond. Ports the
		// controller does not manage stay as they are.
		let old = brports;

		brports = [];

		for (let d in old)
			if (!(d in brports) && !(managed[d] && lag_of[managed[d]]) && !own_bonds[d])
				push(brports, d);

		for (let p in profile.ports)
			if (!lag_of[p.idx] && !(p.dev in brports))
				push(brports, p.dev);

		for (let l in keys(lags))
			push(brports, `lag${l}`);

		setopt(c, 'network', brsec, 'ports', brports);
	}

	// Bridge-wide settings.
	let jumbo = cfg['switch.jumboframes'] == 'enabled';
	let mtu = jumbo ? +(cfg['switch.mtu'] ?? 9216) : null;
	let stp = cfg['switch.stp.status'] == 'enabled';

	setopt(c, 'network', brsec, 'mtu', mtu);
	setopt(c, 'network', brsec, 'stp', stp ? '1' : null);
	setopt(c, 'network', brsec, 'stp_proto', stp ? ((cfg['switch.stp.version'] == 'stp') ? 'stp' : 'rstp') : null);
	setopt(c, 'network', brsec, 'priority', (stp && cfg['switch.stp.priority'] != null) ? +cfg['switch.stp.priority'] : null);

	let igmp = false, snoop = {}, querier = {}, fastleave = {};

	for (let slot, v in sw.vlans) {
		if (v.igmp_snooping == 'true')
			igmp = true;

		snoop[v.id] = (v.igmp_snooping == 'true');

		querier[v.id] = (v.igmp_snooping == 'true' && v.igmp_querier_status == 'true');
		fastleave[v.id] = (v.igmp_snooping == 'true' && v.igmp_fastleave == 'true');
	}

	setopt(c, 'network', brsec, 'igmp_snooping', igmp ? '1' : null);
	setopt(c, 'network', brsec, 'multicast_querier', null);

	// VLANs: the agent owns every bridge-vlan of the bridge.
	let want = {};

	// Existing bridge-vlan memberships of ports the controller does not manage.
	let unmanaged_vlans = {}, unmanaged_seen = {};

	c.foreach('network', 'bridge-vlan', (s) => {
		if (s.device != bridge)
			return;

		for (let e in uci_list(s.ports)) {
			let d = split(e, ':')[0];

			if (!managed[d] && !own_bonds[d]) {
				unmanaged_vlans[+s.vlan] ??= [];
				push(unmanaged_vlans[+s.vlan], e);
				unmanaged_seen[d] = true;
			}
		}
	});

	for (let vid, m in members) {
		let list = [];

		for (let n, mode in m) {
			let dev = lag_of[n] ?? by_idx[n]?.dev;
			let entry = (mode == 'u') ? dev : `${dev}:${mode}`;

			if (dev && !(entry in list))
				push(list, entry);
		}

		// Ports the controller does not manage keep the VLAN memberships they
		// had; one that had none is untagged on the management VLAN.
		for (let e in unmanaged_vlans[vid] ?? [])
			if (!(e in list))
				push(list, e);

		if (vid == mvid)
			for (let d in brports)
				if (!managed[d] && !own_bonds[d] && !unmanaged_seen[d])
					push(list, `${d}:u*`);

		want[vid] = sort(list);
	}

	if (!vlan_ok) {
		// Filtering without the management VLAN would cut the device off.
		push(notes, `management VLAN ${mvid} is not among the controller's VLANs; VLAN settings left unchanged`);
	}
	else {
		setopt(c, 'network', brsec, 'vlan_filtering', '1');

		let have = {};

		c.foreach('network', 'bridge-vlan', (s) => {
			if (s.device == bridge)
				have[s['.name']] = s;
		});

		for (let name, s in have) {
			let vid = +s.vlan;

			if (!want[vid] || name != `unifi_vlan${vid}`)
				c.delete('network', name);
		}

		for (let vid, ports in want) {
			let sec = `unifi_vlan${vid}`;

			if (!have[sec]) {
				c.set('network', sec, 'bridge-vlan');
				c.set('network', sec, 'device', bridge);
				c.set('network', sec, 'vlan', `${vid}`);
			}

			setopt(c, 'network', sec, 'ports', ports);
			setopt(c, 'network', sec, 'mcast_snooping', igmp ? (snoop[vid] ? '1' : '0') : null);
			setopt(c, 'network', sec, 'mcast_querier', querier[vid] ? '1' : null);
		}

		// The management interface rides the management VLAN.
		let iface = profile.mgmt_interface;

		if (c.get('network', iface, 'device') != null)
			setopt(c, 'network', iface, 'device', `${bridge}.${mvid}`);
	}

	// Per-port device options.
	for (let p in profile.ports) {
		let sp = sw.ports[p.idx] ?? {};
		let sec = ensure_device(c, p.dev);
		let forced = sp.autoneg == 'disabled';
		let fl = false;

		// SFP/SFP+ ports: 10GBASE-R has no autonegotiation, so a pause setting
		// is forced, and setting one left an LG510S SFP+ port in 1000base-x
		// with no link after a reboot. Flow control and EEE stay unset there.
		let fiber = !!match(p.model_media ?? p.media ?? '', /^Q?SFP/);

		for (let vid, m in members)
			if (m[p.idx] && fastleave[vid])
				fl = true;

		setopt(c, 'network', sec, 'enabled', (sp.status == 'disabled') ? '0' : null);
		setopt(c, 'network', sec, 'autoneg', forced ? '0' : null);
		setopt(c, 'network', sec, 'speed', forced ? sp.speed : null);
		setopt(c, 'network', sec, 'duplex', forced ? ((sp.duplex == 'disabled') ? '0' : '1') : null);
		setopt(c, 'network', sec, 'pause', fiber ? null : ((sp.flowctrl == 'enabled') ? '1' : '0'));
		setopt(c, 'network', sec, 'isolate', (sp.isolation == 'enabled') ? '1' : null);
		setopt(c, 'network', sec, 'mtu', mtu);
		setopt(c, 'network', sec, 'multicast_fast_leave', fl ? '1' : null);

		if (fiber)
			setopt(c, 'network', sec, 'eee', null);
		else if (sp.eee != null)
			setopt(c, 'network', sec, 'eee', (sp.eee == 'enabled') ? '1' : '0');

		if (p.poe && sp.poe != null)
			setopt(c, 'network', sec, 'pse', (sp.poe == 'shutdown' || sp.poe == 'off') ? '0' : '1');

		if (forced && !(+sp.speed in (p.speeds ?? [])))
			push(notes, `port ${p.idx} (${p.dev}): forced speed ${sp.speed} not in ${join('/', p.speeds ?? [])}`);
	}

	// Mirror and egress rate limits go to switchdev-config, if installed.
	if (has_switchdev()) {
		let mirror = null, limits = {};

		for (let n, sp in sw.ports) {
			if (sp.opmode == 'mirror' && sp.mirror_port && by_idx[n] && by_idx[sp.mirror_port])
				mirror = { source: by_idx[sp.mirror_port].dev, target: by_idx[n].dev };

			if (sp.egress_rate_limit_kbps && by_idx[n])
				limits[by_idx[n].dev] = int((+sp.egress_rate_limit_kbps + 999) / 1000);
		}

		let msec = 'unifi_mirror';

		if (mirror) {
			if (c.get('switchdev', msec) == null)
				c.set('switchdev', msec, 'mirror');

			setopt(c, 'switchdev', msec, 'enabled', '1');
			setopt(c, 'switchdev', msec, 'source', [ mirror.source ]);
			setopt(c, 'switchdev', msec, 'target', mirror.target);
			setopt(c, 'switchdev', msec, 'direction', 'both');
		}
		else if (c.get('switchdev', msec) != null) {
			c.delete('switchdev', msec);
		}

		let have_rl = {};

		c.foreach('switchdev', 'ratelimit', (s) => {
			if (match(s['.name'], /^unifi_rl_/))
				have_rl[s['.name']] = true;
		});

		for (let dev, mbit in limits) {
			let sec = 'unifi_rl_' + replace(dev, /[^A-Za-z0-9_]/g, '_');

			if (!have_rl[sec])
				c.set('switchdev', sec, 'ratelimit');

			delete have_rl[sec];
			setopt(c, 'switchdev', sec, 'enabled', '1');
			setopt(c, 'switchdev', sec, 'port', dev);
			setopt(c, 'switchdev', sec, 'egress', mbit);
		}

		for (let sec in keys(have_rl))
			c.delete('switchdev', sec);
	}
	else {
		for (let n, sp in sw.ports)
			if (sp.opmode == 'mirror' || sp.egress_rate_limit_kbps)
				push(notes, `port ${n}: mirroring and rate limits need switchdev-config`);
	}

	return notes;
};
