// SPDX-License-Identifier: GPL-2.0-only
// What the agent presents to the controller: the UniFi model, and which
// local port or radio stands behind each UniFi port or radio.
//
// Built from /etc/config/unifi-agent, the model catalog and the hardware.
// Everything the controller is told about the device comes from here.

import { cursor } from 'uci';
import { stat, readfile } from 'fs';
import * as util from 'unifi.util';

const MODELS = '/usr/share/unifi-agent/models.json';

// port_table[].speed_caps bits (controller capability_bits).
const SPEED_BITS = {
	'10': [ 1, 2 ], '100': [ 4, 8 ], '1000': [ 16, 32 ],
	'2500': [ 64, 64 ], '5000': [ 128, 128 ], '10000': [ 256, 256 ]
};
export const SPEED_AUTONEG = 1048576;

const BANDS = { '2g': 'ng', '5g': 'na', '6g': '6e' };

export function is_fiber(media) {
	return !!match(media ?? '', /^Q?SFP/);
};

export function load_models(path) {
	let m = util.read_json(path ?? MODELS) ?? {};
	delete m._source;
	return m;
};

// A catalog entry's ports as [{ idx, media, poe_caps }].
export function model_ports(entry) {
	let ports = [];

	for (let run in entry?.ports ?? [])
		for (let i = 0; i < run[1]; i++)
			push(ports, { idx: length(ports) + 1, media: run[0], poe_caps: run[2] });

	return ports;
};

// Parses `ethtool <dev>` output into speeds, autoneg and the port type.
export function parse_ethtool(text) {
	let r = { speeds: [], speed_caps: 0, autoneg: false, fibre: false };
	let section = null;

	for (let line in split(text ?? '', '\n')) {
		let m = match(line, /^\s*([A-Za-z -]+):\s*(.*)$/);

		if (m)
			section = m[1];

		let rest = m ? m[2] : line;

		if (section == 'Supported link modes') {
			for (let mode in split(trim(rest), /\s+/)) {
				let s = match(mode, /^([0-9]+)base[A-Za-z0-9]+\/(Full|Half)$/);
				let bits = s ? SPEED_BITS[s[1]] : null;

				if (!bits)
					continue;

				r.speed_caps |= bits[s[2] == 'Full' ? 1 : 0];

				if (!(+s[1] in r.speeds))
					push(r.speeds, +s[1]);
			}
		}
		else if (m && section == 'Supports auto-negotiation')
			r.autoneg = (m[2] == 'Yes');
		else if (m && (section == 'Supported ports' || section == 'Port'))
			r.fibre ||= !!match(m[2], /FIBRE/);
	}

	if (r.autoneg)
		r.speed_caps |= SPEED_AUTONEG;

	r.speeds = sort(r.speeds, (a, b) => a - b);

	return r;
};

// What the hardware says about one local port.
function probe_port(dev) {
	let et = parse_ethtool(util.run([ 'ethtool', dev ]));
	let eee = util.run([ 'ethtool', '--show-eee', dev ]);
	let sfp = !!stat(`/sys/class/net/${dev}/of_node/sfp`) || et.fibre;
	let max = et.speeds[-1] ?? 0;

	if (sfp && !length(et.speeds)) {
		// Phylink reports no modes while the cage is empty.
		max = 10000;
		et.speed_caps = 32 | 256;
		et.speeds = [ 1000, 10000 ];
	}

	return {
		media: sfp ? ((max >= 10000) ? 'SFP+' : 'SFP') : 'GE',
		speed_caps: et.speed_caps,
		speeds: et.speeds,
		max_speed: max,
		eee: !!eee && !match(eee, /not supported/)
	};
}

// Bridge ports from the network config, in natural order.
// A bond the agent created stands for its member ports, so a LAG does not
// change the mapping found at the next start.
function bridge_ports(uci, bridge) {
	let ports = util.bridge_members(uci, bridge), bonds = {};

	uci.foreach('network', 'device', (s) => {
		if (s.type == 'bonding' && match(s['.name'], /^unifi_lag[0-9]+$/))
			bonds[s.name] = util.uci_list(s.ports);
	});

	let out = [];

	for (let d in ports)
		for (let m in (bonds[d] ?? [ d ]))
			push(out, m);

	return sort(uniq(out), util.natcmp);
}

// The bridge behind the management interface (lan on br-lan, or on
// switch.1 with VLAN filtering), else the first bridge.
function find_bridge(uci, iface) {
	let dev = split(uci.get('network', iface, 'device') ?? '', '.')[0];
	let found = null, first = null;

	uci.foreach('network', 'device', (s) => {
		if (s.type != 'bridge')
			return;

		first ??= s.name;

		if (s.name == dev)
			found = s.name;
	});

	return found ?? first ?? 'br-lan';
}

function local_radios(uci) {
	let radios = [];

	uci.foreach('wireless', 'wifi-device', (s) => {
		let band = BANDS[s.band] ?? ((+s.channel > 14 || s.hwmode == '11a') ? 'na' : 'ng');
		push(radios, { device: s['.name'], radio: band, disabled: s.disabled == '1', channel: s.channel });
	});

	return radios;
}

// Picks the catalog model closest to the local hardware: same radio bands
// for an AP; for a switch the same copper and fibre counts, else the
// smallest model that has room for both.
export function suggest(models, ports, radios) {
	let want_c = length(filter(ports, (p) => !is_fiber(p.media)));
	let want_f = length(filter(ports, (p) => is_fiber(p.media)));
	let fmedia = filter(ports, (p) => is_fiber(p.media))[0]?.media;
	let bands = join(',', sort(uniq(map(radios, (r) => r.radio))));
	let best = [], kind = length(radios) ? 'uap' : 'usw';

	for (let name, e in models) {
		if (e.type != kind)
			continue;

		let mp = model_ports(e);
		let c = length(filter(mp, (p) => !is_fiber(p.media)));
		let f = length(filter(mp, (p) => is_fiber(p.media)));
		let score;

		if (kind == 'uap') {
			if (join(',', sort(uniq(map(e.radios ?? [], (r) => r.radio)))) != bands)
				continue;

			// Prefer the models other projects measured, then fewer ports.
			score = ((name == 'U7PG2' || name == 'U7PRO') ? 0 : 1000) + ((c > want_c) ? c - want_c : want_c - c);
		}
		else {
			if (c < want_c || f < want_f)
				continue;

			score = (c - want_c) + (f - want_f);

			if (want_f && !length(filter(mp, (p) => p.media == fmedia)))
				score += 50;

			if (length(filter(mp, (p) => p.poe_caps)))
				score += 0.5;
		}

		push(best, [ score, name ]);
	}

	best = sort(best, (a, b) => (a[0] - b[0]) || ((a[1] < b[1]) ? -1 : 1));

	return map(best, (b) => b[1]);
};

// Assigns local ports to the model's ports: explicit `unifi` indexes first,
// then copper to copper and fibre to fibre, in order.
export function map_ports(mports, local) {
	let used = {}, out = [];

	for (let l in local) {
		if (l.unifi && !used[l.unifi] && l.unifi <= length(mports)) {
			used[l.unifi] = true;
			push(out, { ...l, idx: +l.unifi, model_media: mports[l.unifi - 1].media });
		}
	}

	for (let l in local) {
		if (l.unifi)
			continue;

		for (let p in mports) {
			if (!used[p.idx] && is_fiber(p.media) == is_fiber(l.media)) {
				used[p.idx] = true;
				push(out, { ...l, idx: p.idx, model_media: p.media });
				break;
			}
		}
	}

	return sort(out, (a, b) => a.idx - b.idx);
};

// Loads the agent config and builds the profile. opts.probe = false skips
// the hardware (for tests); opts.uci_dir points at another config tree.
export function load(opts) {
	opts ??= {};

	let uci = cursor(opts.uci_dir);
	let main = uci.get_all('unifi-agent', 'main') ?? {};
	let models = opts.models ?? load_models(opts.models_path);
	let iface = main.interface ?? 'lan';
	let bridge = main.bridge ?? find_bridge(uci, iface);
	let probe = opts.probe ?? probe_port;
	let ports = [], radios = [];

	// Ports: from `config port` sections, else every bridge port.
	let port_sections = 0, radio_sections = 0;

	uci.foreach('unifi-agent', 'port', (s) => {
		port_sections++;

		if (s.device && util.bool(s.enabled, true))
			push(ports, { dev: s.device, unifi: s.unifi ? +s.unifi : null, media: s.media,
				poe: util.bool(s.poe, false), name: s.name });
	});

	// Discovery only without any port section; disabled ones count.
	if (!port_sections)
		ports = map(bridge_ports(uci, bridge), (d) => ({ dev: d }));

	for (let p in ports) {
		let hw = probe(p.dev);
		p.media ??= hw.media;
		p.speed_caps = hw.speed_caps;
		p.speeds = hw.speeds;
		p.max_speed = hw.max_speed;
		p.eee = hw.eee;
	}

	// Radios: from `config radio` sections, else every wifi-device.
	uci.foreach('unifi-agent', 'radio', (s) => {
		radio_sections++;

		if (s.device && util.bool(s.enabled, true))
			push(radios, { device: s.device, radio: s.band });
	});

	// Every radio, disabled ones too: the controller may have turned it off
	// and must be able to turn it on again.
	if (!radio_sections && util.bool(main.wireless, true))
		radios = local_radios(uci);

	let model = main.model ?? 'auto';
	let candidates = suggest(models, ports, radios);

	if (model == 'auto' || !models[model])
		model = candidates[0] ?? (length(radios) ? 'U7PG2' : 'USWED76');

	let entry = models[model] ?? {};
	let mports = model_ports(entry);
	let mapped = map_ports(mports, ports);

	// Radios take the model's radio rows of the same band, in order.
	let mradios = [ ...(entry.radios ?? []) ], rmapped = [];

	for (let r in radios) {
		for (let i, m in mradios) {
			if (m && m.radio == r.radio) {
				push(rmapped, { ...m, device: r.device, channel: r.channel, name: `wifi${length(rmapped)}` });
				mradios[i] = null;
				break;
			}
		}
	}

	return {
		enabled: util.bool(main.enabled, false),
		inform_url: main.inform_url,
		// Unset means log only: applying needs an explicit yes.
		apply: util.bool(main.apply, false),
		interval: (+main.interval >= 1) ? +main.interval : 10,
		bridge,
		mgmt_interface: iface,
		model,
		model_display: entry.name ?? model,
		type: entry.type ?? 'usw',
		version: main.version ?? entry.version ?? '7.4.1.16850',
		model_ports: mports,
		ports: mapped,
		unmapped: filter(ports, (p) => !(p.dev in map(mapped, (m) => m.dev))),
		radios: rmapped,
		unmapped_radios: filter(radios, (r) => !(r.device in map(rmapped, (m) => m.device))),
		candidates: slice(candidates, 0, 5),
		ssh_port: util.bool(main.ssh_adopt, false) ? +(main.ssh_port ?? 2222) : null,
		locate_led: main.locate_led,
		hostname: main.hostname,
		mac: main.mac
	};
};

