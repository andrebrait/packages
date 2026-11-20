// SPDX-License-Identifier: GPL-2.0-only
// The access point side: radio.*, wireless.*, aaa.*, macacl.* and bridge.*
// keys to OpenWrt wireless/network UCI, and the radio_table and vap_table
// the controller reads.
//
// The translation follows unifi-openwrt (internal/translate, GPL-2.0-or-later,
// https://github.com/antoniocosta/unifi-openwrt), which was tested against
// UniFi Network 10.6 on real access points.

import { readfile, stat } from 'fs';
import * as util from 'unifi.util';
import { setopt } from 'unifi.util';

const COUNTRIES = '/usr/share/unifi-agent/countries.json';
const RUN_DIR = '/tmp/unifi-agent';

let countries = null;

const HANDLED = [
	/^radio\.[0-9]+\.(phyname|ieee_mode|channel|txpower|countrycode|status|outdoor)$/,
	/^radio\.countrycode$/,
	/^wireless\.[0-9]+\.(devname|id|ssid|parent|usage|status|hide_ssid|l2_isolation|uapsd|dtim_period|element_adopt|vwire|vport|is_guest|mode)$/,
	/^aaa\.[0-9]+\.(ssid|wpa|wpa\.psk|wpa\.key\.[0-9]+\.mgmt|wpa3\.support|wpa3\.transition|pmf\.status|pmf\.mode|status|hide_ssid|ft\.status|11k\.status|bss_transition|security|devname|id|is_guest|ifname|br\.devname|driver|verbose|eapol_version)$/,
	/^macacl\./,
	/^bridge\.[0-9]+\./
];

export function handled(key) {
	return util.matches_any(HANDLED, key);
};

function country(per, global) {
	countries ??= util.read_json(COUNTRIES) ?? {};

	let raw = ltrim(per || global || '', '0');

	return raw ? countries[raw] : null;
}

// What this hostapd supports (unifi-openwrt's feature probe).
let feat = null;

function features() {
	if (feat)
		return feat;

	let bin = stat('/usr/sbin/hostapd') ? '/usr/sbin/hostapd' : (stat('/usr/sbin/wpad') ? '/usr/sbin/wpad' : null);
	let has = (s) => bin && system([ 'grep', '-q', s, bin ]) == 0;

	feat = {
		r: !!bin && system(`${bin} -v11r >/dev/null 2>&1`) == 0,
		k: has('rrm_neighbor_report'),
		v: has('bss_transition')
	};

	return feat;
}

export function set_features(f) {
	feat = f;
};

export function indices(cfg, top) {
	let set = {};

	for (let k in keys(cfg)) {
		let m = match(k, regexp(`^${top}\\.([0-9]+)\\.`));

		if (m)
			set[m[1]] = true;
	}

	return sort(map(keys(set), (x) => +x), (a, b) => a - b);
};

// ieee_mode (11nght20, 11naht80, ...) to an OpenWrt htmode, keeping the
// radio's HE/EHT family (any band) or VHT family (5 GHz) when it has one.
export function htmode(mode, cur) {
	if (!mode)
		return null;

	let width = '20';

	for (let w in [ '160', '80', '40' ])
		if (substr(mode, -length(w)) == w) {
			width = w;
			break;
		}

	cur ??= '';

	for (let fam in [ 'EHT', 'HE' ])
		if (substr(cur, 0, length(fam)) == fam)
			return `${fam}${width}`;

	if (index(mode, 'he') >= 0)
		return `HE${width}`;

	if (index(mode, 'vht') >= 0 || (index(mode, 'na') >= 0 && substr(cur, 0, 3) == 'VHT'))
		return `VHT${width}`;

	return (width == '80' || width == '160') ? `VHT${width}` : `HT${width}`;
};

function key_mgmt_list(cfg, a) {
	let out = [];

	for (let i = 1; i <= 4; i++)
		for (let m in split(cfg[`${a}wpa.key.${i}.mgmt`] ?? '', /\s+/))
			if (m != '')
				push(out, m);

	return out;
}

// [ encryption, note ]; encryption null means "do not broadcast".
export function encryption(cfg, a) {
	if (!cfg[`${a}wpa`] && !cfg[`${a}wpa.psk`]) {
		let s = cfg[`${a}security`];

		if (s && s != 'none' && s != 'open')
			return [ null, `security "${s}" (WEP) is not supported` ];

		if (cfg[`${a}wpa3.support`] == 'enabled')
			return [ null, 'Enhanced Open (OWE) is not supported' ];

		return [ 'none', null ];
	}

	let mgmt = key_mgmt_list(cfg, a);
	let psk = ('WPA-PSK' in mgmt) || ('WPA-PSK-SHA256' in mgmt);
	let sae = 'SAE' in mgmt;

	if (sae && cfg[`${a}wpa3.transition`] == 'enabled')
		psk = true;

	if (sae && psk)
		return [ 'sae-mixed', null ];

	if (sae)
		return [ 'sae', null ];

	if (psk || !length(mgmt))
		return [ 'psk2+ccmp', null ];

	return [ null, `key management ${join(' ', mgmt)} is not supported (only WPA2/WPA3 personal)` ];
};

// wpa_key_mgmt as a UniFi AP advertises it (no WPA-PSK-SHA256 unless asked).
export function key_mgmt(cfg, a, enc, ft) {
	if (enc == 'none')
		return null;

	let mgmt = key_mgmt_list(cfg, a), out = [];

	if (enc == 'sae-mixed' && cfg[`${a}wpa3.transition`] == 'enabled')
		push(mgmt, 'WPA-PSK');

	for (let m in [ 'SAE', 'WPA-PSK', 'WPA-PSK-SHA256' ]) {
		if (!(m in mgmt))
			continue;

		push(out, m);

		if (ft && m == 'SAE')
			push(out, 'FT-SAE');
		else if (ft && m == 'WPA-PSK')
			push(out, 'FT-PSK');
	}

	return length(out) ? join(' ', out) : null;
};

function pmf(status, mode) {
	return (status != 'enabled') ? '0' : ((mode == '2') ? '2' : '1');
}

// VAP devname -> VLAN id, from the bridge.N sections (br0.<vid> with the
// VAP among its ports).
export function vlan_of(cfg) {
	let out = {};

	for (let n in indices(cfg, 'bridge')) {
		let m = match(cfg[`bridge.${n}.devname`] ?? '', /\.([0-9]{1,4})$/);

		if (!m || m[1] == '0')
			continue;

		for (let k, v in cfg)
			if (index(k, `bridge.${n}.port.`) == 0 && substr(k, -8) == '.devname')
				out[v] = +m[1];
	}

	return out;
};

// MAC ACL for one VAP: [ policy, macs ].
function mac_acl(cfg, devname) {
	for (let n in indices(cfg, 'macacl')) {
		let p = `macacl.${n}.`;

		if (cfg[p + 'devname'] != devname)
			continue;

		let policy = cfg[p + 'policy'] ?? 'disable';
		let macs = [];

		for (let k, v in cfg)
			if (index(k, p + 'mac.') == 0)
				push(macs, lc(v));

		return [ (policy == 'allow' || policy == 'deny') ? policy : 'disable', sort(macs) ];
	}

	return [ 'disable', [] ];
}

// VLAN networks for WLANs: an unaddressed bridge over <uplink>.<vid>, as
// unifi-openwrt does on a plain AP. On a VLAN-filtering bridge the VLAN
// device br-lan.<vid> is used instead.
function plan_vlans(c, profile, vids, notes, switch_keys) {
	let bridge = profile.bridge, filtering = false;
	let brports = util.bridge_members(c, bridge), uplink = brports[0];

	// netifd filters VLANs on a bridge with bridge-vlan sections, too.
	c.foreach('network', 'device', (s) => {
		if (s.type == 'bridge' && s.name == bridge && s.vlan_filtering == '1')
			filtering = true;
	});

	c.foreach('network', 'bridge-vlan', (s) => {
		if (s.device == bridge && !match(s['.name'], /^unifi_wvlan[0-9]+$/))
			filtering = true;
	});

	// On a filtering bridge the VLAN needs bridge membership. The switch
	// translation owns it when the controller sends switch keys; otherwise
	// the bridge's ports carry the VLAN tagged.
	let have_vid = {};

	c.foreach('network', 'bridge-vlan', (s) => {
		if (s.device == bridge && !match(s['.name'], /^unifi_wvlan[0-9]+$/))
			have_vid[+s.vlan] = true;
	});

	let want_w = {};

	if (filtering && !switch_keys) {
		for (let vid in vids) {
			if (have_vid[vid])
				continue;

			let sec = `unifi_wvlan${vid}`;

			want_w[sec] = true;

			if (c.get('network', sec) == null) {
				c.set('network', sec, 'bridge-vlan');
				c.set('network', sec, 'device', bridge);
				c.set('network', sec, 'vlan', `${vid}`);
			}

			setopt(c, 'network', sec, 'ports', map(brports, (d) => `${d}:t`));
		}
	}

	let stale_w = [];

	c.foreach('network', 'bridge-vlan', (s) => {
		if (match(s['.name'], /^unifi_wvlan[0-9]+$/) && !want_w[s['.name']])
			push(stale_w, s['.name']);
	});

	for (let s in stale_w)
		c.delete('network', s);

	let want = {};

	for (let vid in vids) {
		let ifc = `unifi_v${vid}`;

		want[ifc] = true;

		if (c.get('network', ifc) == null)
			c.set('network', ifc, 'interface');

		setopt(c, 'network', ifc, 'proto', 'none');

		if (filtering) {
			setopt(c, 'network', ifc, 'device', `${bridge}.${vid}`);
			continue;
		}

		if (!uplink) {
			push(notes, `VLAN ${vid}: ${bridge} has no port to carry it`);
			continue;
		}

		let dev = `unifi_brv${vid}`;

		want[dev] = true;

		if (c.get('network', dev) == null)
			c.set('network', dev, 'device');

		setopt(c, 'network', dev, 'type', 'bridge');
		setopt(c, 'network', dev, 'name', `br-v${vid}`);
		setopt(c, 'network', dev, 'ports', [ `${uplink}.${vid}` ]);
		setopt(c, 'network', ifc, 'device', `br-v${vid}`);
	}

	let stale = [];

	for (let t in [ 'interface', 'device' ])
		c.foreach('network', t, (s) => {
			if (match(s['.name'], /^unifi_(v|brv)[0-9]+$/) && !want[s['.name']])
				push(stale, s['.name']);
		});

	for (let s in stale)
		c.delete('network', s);
}

// Applies the AP keys to cursor c. Returns notes.
export function plan(cfg, profile, c, switch_keys) {
	let notes = [];
	let f = features();
	let phy = {};		// wifi0 -> profile radio

	for (let r in profile.radios)
		phy[r.name] = r;

	// Radios.
	for (let n in indices(cfg, 'radio')) {
		let p = `radio.${n}.`;
		let r = phy[cfg[p + 'phyname']];

		if (!r) {
			push(notes, `radio.${n} (${cfg[p + 'phyname']}): not a radio this device reports`);
			continue;
		}

		let sec = r.device;
		let tp = cfg[p + 'txpower'];
		let cc = country(cfg[p + 'countrycode'], cfg['radio.countrycode']);
		let ht = htmode(cfg[p + 'ieee_mode'], c.get('wireless', sec, 'htmode'));

		setopt(c, 'wireless', sec, 'disabled', (cfg[p + 'status'] == 'disabled') ? '1' : null);

		if (cfg[p + 'channel'])
			setopt(c, 'wireless', sec, 'channel', cfg[p + 'channel']);

		if (ht)
			setopt(c, 'wireless', sec, 'htmode', ht);

		if (cc)
			setopt(c, 'wireless', sec, 'country', cc);

		setopt(c, 'wireless', sec, 'txpower', (tp && match(tp, /^[0-9]+$/)) ? tp : null);

		if (cfg[p + 'outdoor'] != null) {
			let out = cfg[p + 'outdoor'] == 'enabled';
			setopt(c, 'wireless', sec, 'country3', out ? '0x4f' : null);
			setopt(c, 'wireless', sec, 'ieee80211d', out ? '1' : null);
		}
	}

	// WLANs: wireless.N (the VAP) with aaa.N (its security).
	let vlans = vlan_of(cfg), vids = {}, wanted = {};

	for (let n in indices(cfg, 'wireless')) {
		let w = `wireless.${n}.`, a = `aaa.${n}.`;

		if (cfg[w + 'usage'] == 'uplink' || cfg[w + 'vwire'] == 'enabled' || cfg[w + 'vport'] == 'enabled') {
			push(notes, `wireless.${n}: mesh VAP, not supported`);
			continue;
		}

		let r = phy[cfg[w + 'parent']];
		let ssid = cfg[w + 'ssid'] ?? cfg[a + 'ssid'];

		if (!r) {
			push(notes, `wireless.${n} ("${ssid}" on ${cfg[w + 'parent']}): radio not on this device`);
			continue;
		}

		let sec = null;

		c.foreach('wireless', 'wifi-iface', (s) => {
			if (!sec && s.device == r.device && s.ssid == ssid && s.mode == 'ap')
				sec = s['.name'];
		});

		let enc = encryption(cfg, a);

		if (!enc[0]) {
			// Never broadcast a WLAN with other security than configured.
			push(notes, `wireless.${n} ("${ssid}"): ${enc[1]}; left off`);

			if (sec) {
				wanted[sec] = true;
				setopt(c, 'wireless', sec, 'disabled', '1');
			}

			continue;
		}

		if (!sec) {
			sec = `unifi_${r.device}_${n}`;
			c.set('wireless', sec, 'wifi-iface');
		}

		wanted[sec] = true;

		let vid = vlans[cfg[w + 'devname']];
		let network = profile.mgmt_interface;

		if (vid) {
			vids[vid] = true;
			network = `unifi_v${vid}`;
		}

		let ft = cfg[a + 'ft.status'] == 'enabled';
		let k11 = cfg[a + '11k.status'] == 'enabled';
		let v11 = cfg[a + 'bss_transition'] == 'enabled';

		for (let x in [ [ ft, f.r, '802.11r' ], [ k11, f.k, '802.11k' ], [ v11, f.v, '802.11v' ] ])
			if (x[0] && !x[1])
				push(notes, `${sec}: ${x[2]} requested, but this hostapd lacks it (needs the full wpad)`);

		let secured = enc[0] != 'none';
		let km = key_mgmt(cfg, a, enc[0], ft && f.r);
		let acl = mac_acl(cfg, cfg[w + 'devname']);

		setopt(c, 'wireless', sec, 'device', r.device);
		setopt(c, 'wireless', sec, 'mode', 'ap');
		setopt(c, 'wireless', sec, 'network', network);
		setopt(c, 'wireless', sec, 'ssid', ssid);
		setopt(c, 'wireless', sec, 'disabled', (cfg[w + 'status'] == 'disabled' || cfg[a + 'status'] == 'disabled') ? '1' : null);
		setopt(c, 'wireless', sec, 'hidden', (cfg[w + 'hide_ssid'] == 'true' || cfg[a + 'hide_ssid'] == 'true') ? '1' : null);
		setopt(c, 'wireless', sec, 'isolate', (cfg[w + 'l2_isolation'] == 'enabled') ? '1' : null);
		setopt(c, 'wireless', sec, 'uapsd', (cfg[w + 'uapsd'] == 'enabled') ? null : '0');
		setopt(c, 'wireless', sec, 'dtim_period', cfg[w + 'dtim_period']);
		setopt(c, 'wireless', sec, 'encryption', enc[0]);
		setopt(c, 'wireless', sec, 'ieee80211w', secured ? pmf(cfg[a + 'pmf.status'], cfg[a + 'pmf.mode']) : null);
		setopt(c, 'wireless', sec, 'key', secured ? cfg[a + 'wpa.psk'] : null);
		setopt(c, 'wireless', sec, 'ieee80211r', f.r ? (ft ? '1' : '0') : null);
		setopt(c, 'wireless', sec, 'ieee80211k', f.k ? (k11 ? '1' : '0') : null);
		setopt(c, 'wireless', sec, 'bss_transition', f.v ? (v11 ? '1' : '0') : null);
		setopt(c, 'wireless', sec, 'hostapd_bss_options', km ? [ `wpa_key_mgmt=${km}` ] : null);
		setopt(c, 'wireless', sec, 'macfilter', (acl[0] != 'disable') ? acl[0] : null);
		setopt(c, 'wireless', sec, 'maclist', (acl[0] != 'disable' && length(acl[1])) ? acl[1] : null);
	}

	// AP interfaces the controller no longer lists are disabled, never deleted.
	let devices = map(profile.radios, (r) => r.device), off = [];

	c.foreach('wireless', 'wifi-iface', (s) => {
		if ((s.device in devices) && s.mode == 'ap' && !wanted[s['.name']] && s.disabled != '1')
			push(off, s);
	});

	for (let s in off) {
		c.set('wireless', s['.name'], 'disabled', '1');
		push(notes, `${s['.name']} ("${s.ssid}") is not in the controller's config: disabled`);
	}

	plan_vlans(c, profile, map(keys(vids), (v) => +v), notes, switch_keys);

	return notes;
};

// ---- Status: radio_table, vap_table ----

function ubus(obj, method, args) {
	return util.run_json([ 'ubus', 'call', obj, method, sprintf('%J', args ?? {}) ]);
}

function net_counter(dev, name) {
	let v = util.read(`/sys/class/net/${dev}/statistics/${name}`);
	return (v != null) ? +v : 0;
}

function arp_table() {
	let out = {};

	for (let line in split(readfile('/proc/net/arp') ?? '', '\n')) {
		let f = split(trim(line), /\s+/);

		if (length(f) >= 4 && match(f[3], /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/))
			out[f[3]] = f[0];
	}

	return out;
}

// The devname and WLAN id the controller gave each SSID on each radio,
// from the last system_cfg.
function vap_names() {
	let cfg = util.parse_kv(readfile(`${RUN_DIR}/system_cfg`) ?? '');
	let out = {};

	for (let n in indices(cfg, 'wireless')) {
		let w = `wireless.${n}.`;
		out[`${cfg[w + 'parent']}/${cfg[w + 'ssid']}`] = {
			devname: cfg[w + 'devname'], id: cfg[w + 'id'], is_guest: cfg[w + 'is_guest'] == 'true'
		};
	}

	return out;
}

const WIDTH_IDX = { '20': 0, '40': 1, '80': 2, '160': 3, '320': 4 };

// One client, from `ubus call iwinfo assoclist` (rates in kbit/s).
export function sta_row(s, arp) {
	let width = s.rx?.mhz ?? s.tx?.mhz ?? 20;
	let mac = lc(s.mac ?? '');

	let row = {
		mac,
		signal: s.signal,
		rssi: (s.signal != null) ? s.signal + 95 : null,
		noise: s.noise,
		tx_rate: s.tx?.rate ?? 0,
		rx_rate: s.rx?.rate ?? 0,
		uptime: s.connected_time ?? 0,
		idletime: int((s.inactive ?? 0) / 1000),
		tx_bytes: s.tx?.bytes ?? 0,
		rx_bytes: s.rx?.bytes ?? 0,
		tx_packets: s.tx?.packets ?? 0,
		rx_packets: s.rx?.packets ?? 0,
		tx_retries: s.tx?.retries ?? 0,
		chwidth: WIDTH_IDX[`${width}`] ?? 0,
		authorized: s.authorized ?? true
	};

	if (arp?.[mac])
		row.ip = arp[mac];

	return row;
};

export function inform_tables(profile, state) {
	let status = ubus('network.wireless', 'status') ?? {};
	let names = vap_names();
	let arp = arp_table();
	let radio_table = [], vap_table = [], n = 0;

	for (let r in profile.radios) {
		let st = status[r.device] ?? {};
		let chan = null, txp = null;

		for (let ifc in st.interfaces ?? []) {
			let dev = ifc.ifname;

			if (!dev || ifc.config?.mode != 'ap')
				continue;

			let info = ubus('iwinfo', 'info', { device: dev }) ?? {};
			let assoc = ubus('iwinfo', 'assoclist', { device: dev })?.results ?? [];
			let ssid = info.ssid ?? ifc.config?.ssid;
			let meta = names[`${r.name}/${ssid}`] ?? {};
			let stas = map(assoc, (s) => sta_row(s, arp));

			chan ??= info.channel;
			txp ??= info.txpower;

			push(vap_table, {
				name: meta.devname ?? `ath${n++}`,
				id: meta.id,
				essid: ssid,
				bssid: info.bssid ? lc(info.bssid) : null,
				radio: r.radio,
				radio_name: r.name,
				channel: info.channel,
				tx_power: info.txpower,
				up: true,
				state: 'RUN',
				usage: 'user',
				is_guest: !!meta.is_guest,
				num_sta: length(stas),
				rx_bytes: net_counter(dev, 'rx_bytes'),
				tx_bytes: net_counter(dev, 'tx_bytes'),
				rx_packets: net_counter(dev, 'rx_packets'),
				tx_packets: net_counter(dev, 'tx_packets'),
				rx_errors: net_counter(dev, 'rx_errors'),
				tx_errors: net_counter(dev, 'tx_errors'),
				sta_table: stas
			});
		}

		push(radio_table, {
			name: r.name,
			radio: r.radio,
			channel: chan ?? st.config?.channel ?? r.channel,
			ht: r.ht,
			tx_power: txp,
			min_txpower: r.min_txpower,
			max_txpower: r.max_txpower,
			nss: r.nss,
			radio_caps: r.radio_caps ?? 0,
			antenna_gain: r.antenna_gain ?? 0,
			builtin_antenna: true,
			is_11ac: r.radio != 'ng',
			has_dfs: r.radio == 'na'
		});
	}

	return { radio_table, vap_table };
};

// ---- Commands ----

function each_ap(profile, fn) {
	let status = ubus('network.wireless', 'status') ?? {};

	for (let r in profile.radios)
		for (let ifc in status[r.device]?.interfaces ?? [])
			if (ifc.ifname && ifc.config?.mode == 'ap')
				fn(ifc.ifname);
}

function deauth(profile, mac, ban_ms) {
	each_ap(profile, (dev) => ubus(`hostapd.${dev}`, 'del_client',
		{ addr: mac, reason: 5, deauth: true, ban_time: ban_ms }));
}

// Blocked clients get an hour-long ban, renewed every round, so it never
// lapses while the agent is busy; an unblock lifts it at once (a hostapd
// ban_time of 0 removes an existing ban).
export function enforce_blocked(profile, macs) {
	if (!length(profile.radios))
		return;

	for (let mac in macs ?? [])
		deauth(profile, mac, 3600000);
};

// blocked_sta from setparam: comma-separated MACs.
export function parse_blocked(list) {
	return filter(map(split(list ?? '', ','), (m) => lc(trim(m))),
		(m) => match(m, /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/));
};

// Client commands. st.blocked holds the blocked clients.
export function command(profile, msg, st) {
	if (!length(profile.radios) || !msg.mac)
		return false;

	let mac = lc(msg.mac);

	if (msg.cmd == 'kick-sta') {
		deauth(profile, mac, 0);
		return true;
	}

	if (msg.cmd == 'block-sta') {
		st.blocked = uniq([ ...(st.blocked ?? []), mac ]);
		enforce_blocked(profile, [ mac ]);
		return true;
	}

	if (msg.cmd == 'unblock-sta') {
		st.blocked = filter(st.blocked ?? [], (m) => m != mac);
		each_ap(profile, (dev) => ubus(`hostapd.${dev}`, 'del_client',
			{ addr: mac, deauth: false, ban_time: 0 }));
		return true;
	}

	return false;
};
