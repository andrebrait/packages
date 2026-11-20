// AP keys (unifi-openwrt's test config, extended) applied to a dual-band AP.
import * as t from 'assert';
import * as wifi from 'unifi.wifi';
import * as apply from 'unifi.apply';
import * as util from 'unifi.util';
import { cursor } from 'uci';
import { readfile } from 'fs';

const DIR = sourcepath(0, true) + '/fixtures/ap';
system(`rm -rf /tmp/uci-w && mkdir -p /tmp/uci-w/save && cp '${DIR}'/wireless '${DIR}'/network /tmp/uci-w/`);
system('mkdir -p /usr/share/unifi-agent && cp ' + sourcepath(0, true) + '/../files/usr/share/unifi-agent/countries.json /usr/share/unifi-agent/');

wifi.set_features({ r: false, k: true, v: true });

let profile = {
	bridge: 'br-lan', mgmt_interface: 'lan', ports: [], model_ports: [],
	radios: [ { name: 'wifi0', radio: 'ng', device: 'radio0' }, { name: 'wifi1', radio: 'na', device: 'radio1' } ]
};
let cfg = util.parse_kv(readfile(DIR + '/system_cfg.txt'));
let c = cursor('/tmp/uci-w', '/tmp/uci-w/save');
let notes = wifi.plan(cfg, profile, c);
let ch = c.changes('wireless');
let flat = sprintf('%J', ch);

// The matching WLAN on radio0 stays as it is.
t.ok(index(flat, '"ap0", "encryption"') < 0 && index(flat, '"ap0", "key"') < 0, 'ap0 security untouched');
t.eq(c.get('wireless', 'radio0', 'channel'), '6', 'radio0 channel');
t.eq(c.get('wireless', 'radio1', 'channel'), '44', 'radio1 channel changed');
t.eq(c.get('wireless', 'radio1', 'htmode'), 'HE80', 'HE family kept');
t.eq(c.get('wireless', 'unifi_radio0_2', 'hidden'), '1', 'element-adopt WLAN hidden');
t.eq(c.get('wireless', 'unifi_radio0_2', 'encryption'), 'psk2+ccmp', 'WPA2 WLAN');
t.eq(c.get('wireless', 'unifi_radio1_4', 'network'), 'unifi_v30', 'VLAN 30 WLAN network');
t.eq(c.get('wireless', 'unifi_radio1_4', 'macfilter'), 'deny', 'mac acl');
t.eq(c.get('wireless', 'unifi_radio1_4', 'maclist'), [ 'aa:bb:cc:dd:ee:ff' ], 'mac list');
t.eq(c.get('wireless', 'old', 'disabled'), '1', 'unlisted WLAN disabled, not deleted');
t.eq(c.get('network', 'unifi_brv30', 'ports'), [ 'lan.30' ], 'vlan bridge over uplink');
t.ok(length(filter(notes, (n) => index(n, 'mesh') >= 0)) == 1, 'mesh VAP noted');

// Secrets never appear in the logged plan.
let plan = apply.apply(readfile(DIR + '/system_cfg.txt'), { ...profile, apply: true, type: 'uap' },
	{ dry_run: true, uci_dir: '/tmp/uci-w', save_dir: '/tmp/uci-w/save2', log: () => null });
t.ok(index(join('\n', plan.plan), 'elem-pass') < 0 && index(join('\n', plan.plan), 'iot-pass') < 0, 'no secrets in plan');
t.ok(length(plan.plan) > 0, 'plan not empty');

t.eq(wifi.htmode('11naht40', 'HE80'), 'HE40', 'htmode HE40');
t.eq(wifi.htmode('11nght20', ''), 'HT20', 'htmode HT20');
t.eq(wifi.encryption({ 'a.wpa': '2', 'a.wpa.key.1.mgmt': 'WPA-EAP' }, 'a.')[0], null, 'enterprise refused');
t.eq(wifi.sta_row({ mac: 'AA:BB:CC:00:00:01', signal: -60, rx: { rate: 866700, mhz: 80 }, tx: { rate: 650000 } }, { 'aa:bb:cc:00:00:01': '10.0.0.5' }).chwidth, 2, 'sta chwidth');

t.done();
