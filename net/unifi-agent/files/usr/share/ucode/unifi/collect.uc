// SPDX-License-Identifier: GPL-2.0-only
// Reads the device and renders the inform payload.

import { readfile, stat, lsdir } from 'fs';
import * as util from 'unifi.util';
import * as wifi from 'unifi.wifi';
import * as sw from 'unifi.switch';
import { is_fiber } from 'unifi.profile';
import { cursor } from 'uci';

const STP_STATES = [ 'disabled', 'listening', 'learning', 'forwarding', 'blocking' ];

let cpu_prev = null;
let sfp_cache = {};

// The last uplink found: its devices and the gateway's MAC address.
let last_uplink = { devs: [], mac: null };

function num(path) {
	let s = util.read(path);
	return (s != null && match(s, /^-?[0-9]+$/)) ? +s : null;
}

function sysnet(dev, attr) {
	return util.read(`/sys/class/net/${dev}/${attr}`);
}

function stat_counter(dev, name) {
	return num(`/sys/class/net/${dev}/statistics/${name}`) ?? 0;
}

function cpu_percent() {
	let l = match(readfile('/proc/stat') ?? '', /^cpu +([0-9 ]+)/);

	if (!l)
		return 0;

	let v = map(split(trim(l[1]), / +/), (x) => +x);
	let idle = v[3] + (v[4] ?? 0), total = 0;

	for (let x in v)
		total += x;

	let pct = 0;

	if (cpu_prev && total > cpu_prev[1])
		pct = 100.0 * (1 - (idle - cpu_prev[0]) * 1.0 / (total - cpu_prev[1]));

	cpu_prev = [ idle, total ];

	return pct;
}

function meminfo() {
	let m = {};

	for (let line in split(readfile('/proc/meminfo') ?? '', '\n')) {
		let kv = match(line, /^(\w+): +([0-9]+)/);

		if (kv)
			m[kv[1]] = +kv[2] * 1024;
	}

	return m;
}

function temperature() {
	let t = num('/sys/devices/virtual/thermal/thermal_zone0/temp') ??
		num('/sys/class/thermal/thermal_zone0/temp');

	return (t != null) ? t / 1000 : null;
}

export function system_stats() {
	let la = split(util.read('/proc/loadavg') ?? '0 0 0', ' ');
	let mem = meminfo();
	let used = (mem.MemTotal ?? 0) - (mem.MemAvailable ?? mem.MemFree ?? 0);
	let cpu = cpu_percent();
	let uptime = int(+split(util.read('/proc/uptime') ?? '0', ' ')[0]);

	return {
		uptime,
		sys_stats: {
			loadavg_1: la[0], loadavg_5: la[1], loadavg_15: la[2],
			mem_total: mem.MemTotal ?? 0, mem_used: used,
			mem_buffer: (mem.Buffers ?? 0) + (mem.Cached ?? 0)
		},
		'system-stats': {
			cpu: sprintf('%.1f', cpu),
			mem: sprintf('%.1f', mem.MemTotal ? 100.0 * used / mem.MemTotal : 0),
			uptime: `${uptime}`
		}
	};
}

// Parses `ethtool -m` into the sfp_* fields the controller shows.
export function parse_sfp(text) {
	let f = {}, types = [], out = { sfp_found: false };

	// ucode regexes are POSIX: no lazy quantifiers, so the key ends on its
	// last non-blank character instead.
	for (let line in split(text ?? '', '\n')) {
		let m = match(line, /^[ \t]*([^:]*[^: \t])[ \t]*: (.*)$/);

		if (!m)
			continue;

		f[m[1]] ??= trim(m[2]);

		if (m[1] == 'Transceiver type')
			push(types, trim(m[2]));
	}

	if (!length(f))
		return out;

	let first = (v) => trim(split(v ?? '', /\s+[(\[]/)[0]);
	// No light at all prints "-inf dBm": report it as -40 dBm.
	let dbm = (v) => {
		if (match(v ?? '', /-inf dBm/))
			return '-40.00';

		let m = match(v ?? '', /(-?[0-9.]+) dBm/);
		return m ? sprintf('%.2f', +m[1]) : null;
	};
	let degc = (v) => { let m = match(v ?? '', /(-?[0-9.]+) degrees C/); return m ? sprintf('%.2f', +m[1]) : null; };
	// The most telling of the listed types: 10G optics first, then cables,
	// then 1G; else the first type as printed.
	let comp = join('; ', types);
	let cm = null;

	for (let re in [ /(10G Base-[A-Z]+)/i, /(Active Cable|Passive Cable)/i, /(1000BASE-[A-Z]+)/i ])
		if ((cm = match(comp, re)))
			break;

	out.sfp_found = true;
	out.sfp_eeprom = true;
	out.sfp_vendor = f['Vendor name'];
	out.sfp_part = f['Vendor PN'];
	out.sfp_serial = f['Vendor SN'];
	out.sfp_rev = f['Vendor rev'];
	out.sfp_compliance = cm ? cm[1] : first(types[0]);
	out.sfp_temperature = degc(f['Module temperature']);
	out.sfp_voltage = (match(f['Module voltage'] ?? '', /([0-9.]+) V/) ?? [])[1];
	out.sfp_current = (match(f['Laser bias current'] ?? '', /([0-9.]+) mA/) ?? [])[1];
	out.sfp_txpower = dbm(f['Laser output power']);
	out.sfp_rxpower = dbm(f['Receiver signal average optical power'] ?? f['Receiver signal OMA']);

	// ethtool decodes no fault bits for SFP; QSFP/CMIS print per-lane lists
	// such as "[ Yes, No, No, No ]" or "None".
	if (f['Tx fault'] != null)
		out.sfp_txfault = !!match(f['Tx fault'], /Yes/);

	if (f['Rx loss of signal'] != null)
		out.sfp_rxfault = !!match(f['Rx loss of signal'], /Yes/);

	// Drop what is unknown; false is a value (in ucode false == '' is true).
	for (let k in keys(out))
		if (out[k] == null || (type(out[k]) == 'string' && out[k] == ''))
			delete out[k];

	return out;
}

function sfp_info(dev) {
	let now = time(), c = sfp_cache[dev];

	if (!c || now - c.at > 60)
		c = sfp_cache[dev] = { at: now, info: parse_sfp(util.run([ 'ethtool', '-m', dev ])) };

	return c.info;
}

function port_name(p) {
	return p.name ?? `Port ${p.idx}`;
}

// The port that carries a member: itself, or the bond it is enslaved to.
function bridge_member(dev) {
	let master = readfile(`/sys/class/net/${dev}/master/uevent`);
	let m = master ? match(master, /INTERFACE=(\S+)/) : null;

	return (m && stat(`/sys/class/net/${m[1]}/bonding`)) ? m[1] : dev;
}

// One port_table row. dyn holds the live values that need ethtool.
export function port_row(p, dyn) {
	let dev = p.dev;
	let up = sysnet(dev, 'carrier') == '1';
	let speed = up ? (num(`/sys/class/net/${dev}/speed`) ?? 0) : 0;
	let member = bridge_member(dev);
	let brstate = num(`/sys/class/net/${member}/brport/state`);
	let mtu = num(`/sys/class/net/${dev}/mtu`) ?? 1500;

	let row = {
		port_idx: p.idx,
		name: port_name(p),
		ifname: dev,
		media: p.model_media ?? p.media,
		enable: sysnet(dev, 'flags') != null ? !!(hex(sysnet(dev, 'flags')) & 1) : true,
		up,
		speed: (speed > 0) ? speed : 0,
		full_duplex: up && sysnet(dev, 'duplex') == 'full',
		autoneg: dyn?.autoneg ?? true,
		speed_caps: p.speed_caps,
		port_caps: 0,
		poe_caps: 0,
		port_poe: false,
		jumbo: mtu > 1500,
		is_uplink: false,
		stp_state: (brstate != null) ? STP_STATES[brstate] ?? 'disabled' : 'disabled',
		stp_pathcost: num(`/sys/class/net/${member}/brport/path_cost`) ?? 0,
		rx_bytes: stat_counter(dev, 'rx_bytes'),
		tx_bytes: stat_counter(dev, 'tx_bytes'),
		rx_packets: stat_counter(dev, 'rx_packets'),
		tx_packets: stat_counter(dev, 'tx_packets'),
		rx_errors: stat_counter(dev, 'rx_errors'),
		tx_errors: stat_counter(dev, 'tx_errors'),
		rx_dropped: stat_counter(dev, 'rx_dropped'),
		tx_dropped: stat_counter(dev, 'tx_dropped'),
		rx_multicast: stat_counter(dev, 'multicast'),
		tx_multicast: 0,
		rx_broadcast: 0,
		tx_broadcast: 0
	};

	if (member != dev) {
		row.lag_member = true;
		row.aggregated_by = member;
	}

	if (p.poe) {
		// netifd's pse option drives the PSE; report what UCI asks for.
		row.poe_caps = 7;
		row.port_poe = true;
		row.poe_mode = dyn?.pse ? 'auto' : 'off';
		row.poe_enable = !!dyn?.pse;
	}

	if (dyn?.flowctrl != null) {
		row.flowctrl_rx = dyn.flowctrl;
		row.flowctrl_tx = dyn.flowctrl;
	}

	if (p.eee)
		row.port_caps |= 1;

	if (is_fiber(row.media))
		for (let k, v in sfp_info(dev))
			row[k] = v;

	return row;
}

// `bridge -j fdb show br <bridge>`: learned addresses per port.
export function mac_tables(fdb, ports) {
	let by_dev = {}, own = {};

	for (let p in ports) {
		by_dev[p.dev] = [];
		by_dev[bridge_member(p.dev)] ??= by_dev[p.dev];
	}

	for (let e in fdb) {
		let list = by_dev[e.ifname];

		if (!list || !e.mac || 'self' in (e.flags ?? []) || e.state == 'permanent')
			continue;

		let row = { mac: e.mac, age: 0, uptime: 0, static: (e.state == 'static') };

		if (e.vlan)
			row.vlan = e.vlan;

		if (!own[`${e.ifname}/${e.mac}/${e.vlan}`]++)
			push(list, row);
	}

	return by_dev;
}

// The default gateway: its address, the device it is reached through and,
// when that device is a VLAN of the bridge, the VLAN.
function gateway(bridge) {
	let r = util.run_json([ 'ip', '-j', '-4', 'route', 'show', 'default' ])?.[0];
	let v = match(r?.dev ?? '', /^(.+)\.([0-9]+)$/);

	return r?.gateway ? { ip: r.gateway, dev: r.dev, vid: (v?.[1] == bridge) ? +v[2] : null } : null;
}

// The gateway's MAC address, from a neighbour entry that holds one.
function gateway_mac(gw) {
	for (let n in util.run_json([ 'ip', '-j', 'neigh', 'show', gw.ip, 'dev', gw.dev ]) ?? [])
		if (n.lladdr && !('FAILED' in (n.state ?? [])) && !('INCOMPLETE' in (n.state ?? [])))
			return n.lladdr;

	return null;
}

// The uplink: the ports carrying the bridge port where mac was learned (all
// members of a bond), on VLAN vid when given. member_of maps a port's
// device to the bridge port that carries it.
export function uplink_ports(fdb, ports, mac, vid, member_of) {
	for (let e in fdb) {
		if (!mac || e.mac != mac || 'self' in (e.flags ?? []) || e.state == 'permanent' || (vid && e.vlan && +e.vlan != vid))
			continue;

		let up = filter(ports, (p) => p.dev == e.ifname || member_of(p.dev) == e.ifname);

		if (length(up))
			return up;
	}

	return [];
}

// Marks the uplink ports (up) in the payload m. The controller takes as
// uplink the port_table row whose LLDP neighbour's local_port_name equals
// m.uplink: a bond member with a neighbour, else one with carrier. Without a
// neighbour there, the gateway (gwmac) stands in for one.
export function report_uplink(m, up, gwmac) {
	let idxs = map(up, (p) => p.idx);
	let row_of = (p) => filter(m.port_table, (r) => r.port_idx == p.idx)[0];
	let has_lldp = (p) => length(filter(m.lldp_table, (r) => r.local_port_idx == p.idx)) > 0;

	for (let r in m.port_table)
		r.is_uplink = r.port_idx in idxs;

	let pick = filter(up, has_lldp)[0] ?? filter(up, (p) => row_of(p)?.up)[0] ?? up[0];

	if (!pick)
		return;

	m.uplink = port_name(pick);

	if (gwmac && !has_lldp(pick))
		push(m.lldp_table, { local_port_idx: pick.idx, local_port_name: m.uplink, chassis_id: gwmac, is_wired: true });
}

// `lldpcli -f json0 show neighbors`, keyed by local port.
export function lldp_table(ports) {
	let j = util.run_json([ 'lldpcli', '-f', 'json0', 'show', 'neighbors' ]);
	let idx = {}, out = [];

	for (let p in ports)
		idx[p.dev] = p;

	for (let ifc in j?.lldp?.[0]?.interface ?? []) {
		let p = idx[ifc.name];
		let ch = ifc.chassis?.[0], port = ifc.port?.[0];

		if (!p || !ch)
			continue;

		let row = {
			local_port_idx: p.idx,
			local_port_name: port_name(p),
			chassis_id: ch.id?.[0]?.value,
			port_id: port?.id?.[0]?.value,
			is_wired: true
		};

		if (ch.name?.[0]?.value)
			row.chassis_name = ch.name[0].value;

		if (ch.descr?.[0]?.value)
			row.chassis_descr = ch.descr[0].value;

		if (port?.descr?.[0]?.value)
			row.port_descr = port.descr[0].value;

		push(out, row);
	}

	return out;
}

// netifd device options per device name, as the agent last applied them.
let devopts_cache = {};

// libuci also loads changes staged with the CLI; while there are any for
// network, keep reporting what was read before them.
function device_options() {
	let c = cursor();

	if (length(c.changes('network')?.network ?? []))
		return devopts_cache;

	let out = {};

	c.foreach('network', 'device', (s) => {
		if (s.name)
			out[s.name] = s;
	});

	return devopts_cache = out;
}

// Per-port values: autoneg live from ethtool; flow control and PoE as
// configured, since netifd's pause and pse options are what the controller set.
function port_dynamic(dev, opts) {
	let out = util.run([ 'ethtool', dev ]) ?? '';
	let an = match(out, /Auto-negotiation: (on|off)/);

	return {
		autoneg: an ? an[1] == 'on' : null,
		flowctrl: (opts?.pause != null) ? util.bool(opts.pause, false) : null,
		pse: util.bool(opts?.pse, false)
	};
}

function cidr_mask(bits) {
	let m = [];

	for (let i = 0; i < 4; i++) {
		let b = (bits > 8) ? 8 : (bits > 0 ? bits : 0);
		push(m, (0xff << (8 - b)) & 0xff);
		bits -= 8;
	}

	return join('.', m);
}

function mgmt_address(iface) {
	let st = util.run_json([ 'ubus', 'call', `network.interface.${iface}`, 'status' ]);
	let a = st?.['ipv4-address']?.[0];
	let gw = filter(st?.route ?? [], (r) => r.target == '0.0.0.0')[0]?.nexthop;

	if (a)
		return { ip: a.address, netmask: cidr_mask(a.mask), gateway_ip: gw };

	// No netifd (or not up yet): the first global IPv4 address.
	for (let l in util.run_json([ 'ip', '-j', '-4', 'addr', 'show', 'scope', 'global' ]) ?? [])
		for (let ai in l.addr_info ?? [])
			return { ip: ai.local, netmask: cidr_mask(ai.prefixlen) };

	return {};
}


// The whole inform payload.
export function inform(profile, state, extra) {
	let sys = system_stats();
	let mgmt = mgmt_address(profile.mgmt_interface);
	let mac = profile.mac ?? sysnet(profile.bridge, 'address') ?? '00:00:00:00:00:00';
	let adopted = !!state.authkey;
	let temp = temperature();

	let m = {
		mac,
		serial: uc(replace(mac, /:/g, '')),
		model: profile.model,
		model_display: profile.model_display,
		version: state.version ?? profile.version,
		hostname: profile.hostname ?? util.read('/proc/sys/kernel/hostname') ?? 'OpenWrt',
		ip: mgmt.ip ?? state.ip ?? '0.0.0.0',
		netmask: mgmt.netmask,
		gateway_ip: mgmt.gateway_ip,
		inform_url: state.inform_url ?? profile.inform_url,
		uptime: sys.uptime,
		time: time(),
		cfgversion: state.cfgversion ?? '',
		default: !adopted,
		_default_key: !adopted,
		state: adopted ? 4 : 1,
		isolated: false,
		locating: !!state.locating,
		selfrun_beacon: true,
		bootrom_version: 'unknown',
		fw_caps: 3,
		sys_stats: sys.sys_stats,
		'system-stats': sys['system-stats']
	};

	if (temp != null) {
		m.has_temperature = true;
		m.general_temperature = int(temp);
		m.overheating = false;
	}

	if (length(profile.ports)) {
		let fdb_now = () => util.run_json([ 'bridge', '-j', 'fdb', 'show', 'br', profile.bridge ]) ?? [];
		let fdb = fdb_now();
		let gw = gateway(profile.bridge);
		let gwmac = gw ? gateway_mac(gw) : null;
		let up = uplink_ports(fdb, profile.ports, gwmac, gw?.vid, bridge_member);

		// The uplink is the port toward the gateway. When it is not known, make
		// the gateway answer once: that resolves its address and has the bridge
		// learn it again after ageing out.
		if (gw && !length(up)) {
			util.run([ 'ping', '-c', '1', '-W', '1', gw.ip ]);
			fdb = fdb_now();
			gwmac = gateway_mac(gw);
			up = uplink_ports(fdb, profile.ports, gwmac, gw.vid, bridge_member);
		}

		// While the gateway's address is not resolved, keep the last uplink
		// (by device, as ports are rebuilt with the profile) as long as it has
		// carrier.
		if (gwmac)
			last_uplink = { devs: map(up, (p) => p.dev), mac: gwmac };
		else {
			up = filter(profile.ports, (p) => p.dev in last_uplink.devs && sysnet(p.dev, 'carrier') == '1');
			gwmac = length(up) ? last_uplink.mac : null;
		}

		let macs = mac_tables(fdb, profile.ports);
		let devopts = device_options();

		m.port_table = map(profile.ports, (p) => {
			let row = port_row(p, port_dynamic(p.dev, devopts[p.dev]));
			row.mac_table = macs[p.dev] ?? [];
			return row;
		});

		m.ethernet_table = [ { mac, name: 'eth0', num_port: length(profile.model_ports) } ];
		m.lldp_table = lldp_table(profile.ports);

		report_uplink(m, up, gwmac);
	}

	if (profile.type == 'usw') {
		m.switch_caps = sw.caps();
		m.stp_priority = util.read(`/sys/class/net/${profile.bridge}/bridge/priority`) ?? '32768';
	}

	if (profile.type == 'uap')
		for (let k, v in wifi.inform_tables(profile, state))
			m[k] = v;

	for (let k, v in extra ?? {})
		m[k] = v;

	for (let k in keys(m))
		if (m[k] == null)
			delete m[k];

	return m;
}
