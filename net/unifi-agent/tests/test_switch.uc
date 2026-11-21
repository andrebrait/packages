// switch.* keys from a captured controller config, applied to a copy of
// the LG510S network config.
import * as t from 'assert';
import * as sw from 'unifi.switch';
import * as util from 'unifi.util';
import * as apply from 'unifi.apply';
import * as profile_mod from 'unifi.profile';
import { cursor } from 'uci';
import { readfile } from 'fs';

const DIR = sourcepath(0, true) + '/fixtures';
system(`rm -rf /tmp/uci-t && mkdir -p /tmp/uci-t/save && cp '${DIR}'/config/* /tmp/uci-t/`);

let profile = {
	bridge: 'br-lan', mgmt_interface: 'lan',
	model_ports: map([1,2,3,4,5,6], (i) => ({ idx: i })),
	ports: map([1,2,3,4,5,6], (i) => ({ idx: i, dev: `lan${i}`, speeds: [ 1000, 10000 ] }))
};

let cfg = util.parse_kv(readfile(DIR + '/system_cfg-vlans.txt'));
let s = sw.parse(cfg);
let m = sw.membership(s, 6);

t.eq(m[1], { '1': 'u*', '3': 'u*', '4': 'u*', '5': 'u*' }, 'vlan 1: port 2 excluded, port 6 mirror');
t.eq(m[10], { '1': 't', '2': 'u*', '3': 't', '4': 't', '5': 't' }, 'vlan 10: port 2 native');
t.eq(m[20], { '1': 't', '3': 't', '4': 't', '5': 't' }, 'vlan 20');

let c = cursor('/tmp/uci-t', '/tmp/uci-t/save');
let notes = sw.plan(cfg, profile, c);

t.eq(c.get('network', 'unifi_lag1', 'ports'), [ 'lan3', 'lan4' ], 'lag members');
t.eq(c.get('network', 'unifi_lag1', 'policy'), '802.3ad', 'lacp');
t.eq(c.get('network', 'unifi_vlan10', 'ports'), [ 'lag1:t', 'lan1:t', 'lan2:u*', 'lan5:t' ], 'bridge-vlan 10');
t.eq(c.get('network', 'unifi_vlan1', 'ports'), [ 'lag1:u*', 'lan1:u*', 'lan5:u*' ], 'bridge-vlan 1');
t.eq(c.get('network', 'cfg030f15', 'ports') ?? c.get_all('network', c.get_first('network', 'device'))?.ports,
	[ 'lan1', 'lan2', 'lan5', 'lan6', 'lag1' ], 'bridge ports');
t.eq(c.get('network', 'unifi_lan2', 'isolate'), '1', 'isolation');
t.eq(c.get('network', 'lan', 'device'), 'br-lan.1', 'mgmt on vlan 1');

let br = c.get_all('network', c.get_first('network', 'device'));
t.eq([ br.stp, br.stp_proto, br.priority, br.vlan_filtering ], [ '1', 'rstp', '4096', '1' ], 'stp');
t.ok(length(notes) > 0, 'notes about switchdev-config (not installed here)');

// Applying the same config twice leaves no further change.
c.commit('network');
let c2 = cursor('/tmp/uci-t', '/tmp/uci-t/save');
sw.plan(cfg, profile, c2);
t.eq(c2.changes('network'), {}, 'idempotent');

// Unhandled-key filter.
t.ok(sw.handled('switch.vlan.2.port.3.mode'), 'handled matrix');
t.ok(!sw.handled('switch.port.1.stp.edge'), 'stp edge unhandled');

// The same bridge through the switch translation: every member stays.
system(`rm -rf /tmp/uci-v && mkdir -p /tmp/uci-v/save && cp '${DIR}'/lg510s-vlanonly/* /tmp/uci-v/`);
let cv = cursor('/tmp/uci-v', '/tmp/uci-v/save');
sw.plan(util.parse_kv('switch.vlan.1.id=1\nswitch.vlan.1.mode=untagged\nswitch.vlan.1.status=enabled\n'),
	{ ...profile, bridge: 'switch' }, cv);
t.eq(cv.get('network', 'switch', 'ports'), [ 'lan1', 'lan2', 'lan3', 'lan4', 'lan5', 'lan6' ], 'bridge-vlan members kept in the bridge');
t.eq(cv.get('network', 'unifi_vlan1', 'ports'), [ 'lan1:u*', 'lan2:u*', 'lan3:u*', 'lan4:u*', 'lan5:u*', 'lan6:u*' ], 'vlan 1 on every member');

// An unmanaged trunk keeps its tagged VLAN and gets no untagged one.
system(`rm -rf /tmp/uci-x && mkdir -p /tmp/uci-x/save && cp '${DIR}'/lg510s-vlanonly/* /tmp/uci-x/`);
let cx = cursor('/tmp/uci-x');
cx.set('network', 'v10', 'bridge-vlan');
cx.set('network', 'v10', 'device', 'switch');
cx.set('network', 'v10', 'vlan', '10');
cx.set('network', 'v10', 'ports', 'lan1:u* eth9:t');
cx.commit('network');
cx = cursor('/tmp/uci-x', '/tmp/uci-x/save');
sw.plan(util.parse_kv('switch.vlan.1.id=1\nswitch.vlan.1.mode=untagged\nswitch.vlan.1.status=enabled\nswitch.vlan.2.id=10\nswitch.vlan.2.mode=tagged\nswitch.vlan.2.status=enabled\n'),
	{ ...profile, bridge: 'switch' }, cx);
t.ok('eth9:t' in cx.get('network', 'unifi_vlan10', 'ports'), 'unmanaged trunk keeps VLAN 10 tagged');
t.ok(!('eth9:u*' in cx.get('network', 'unifi_vlan1', 'ports')), 'unmanaged trunk not made untagged');

// SFP ports never get flow control or EEE, and an existing pause is removed.
system(`rm -rf /tmp/uci-p && mkdir -p /tmp/uci-p/save && cp '${DIR}'/lg510s-vlanonly/* /tmp/uci-p/`);
let cp0 = cursor('/tmp/uci-p', '/tmp/uci-p/seed');
cp0.set('network', 'old5', 'device');
cp0.set('network', 'old5', 'name', 'lan5');
cp0.set('network', 'old5', 'pause', '1');
cp0.commit('network');
let cp = cursor('/tmp/uci-p', '/tmp/uci-p/save');
let fprofile = { ...profile, bridge: 'switch', ports: map(profile.ports, (x) => ({ ...x, model_media: (x.idx >= 5) ? 'SFP+' : 'GE' })) };
sw.plan(util.parse_kv('switch.vlan.1.id=1\nswitch.vlan.1.mode=untagged\nswitch.vlan.1.status=enabled\nswitch.port.1.flowctrl=enabled\nswitch.port.5.flowctrl=enabled\nswitch.port.6.flowctrl=enabled\nswitch.port.5.eee=enabled\n'), fprofile, cp);
t.eq(cp.get('network', 'old5', 'pause'), null, 'pause removed from an SFP port');
t.eq(cp.get('network', 'unifi_lan6', 'pause'), null, 'no pause set on an SFP port');
t.eq(cp.get('network', 'old5', 'eee'), null, 'no EEE on an SFP port');
t.eq(cp.get('network', 'unifi_lan1', 'pause'), '1', 'copper still gets flow control');

// An SFP cage mapped onto a copper UniFi slot is still treated as SFP.
let cq = cursor('/tmp/uci-p', '/tmp/uci-p/save2');
sw.plan(util.parse_kv('switch.vlan.1.id=1\nswitch.vlan.1.mode=untagged\nswitch.vlan.1.status=enabled\nswitch.port.1.flowctrl=enabled\n'),
	{ ...profile, bridge: 'switch', ports: [ { idx: 1, dev: 'lan5', media: 'SFP+', model_media: 'GE', speeds: [] } ] }, cq);
t.eq(cq.get('network', 'old5', 'pause'), null, 'local media decides');

// Categories: VLANs only leaves ports, STP and flow control alone, and the
// withheld changes are still listed.
t.eq(profile_mod.apply_categories([ 'vlans', 'bogus' ]), { vlans: true }, 'category list');
t.eq(length(profile_mod.apply_categories('1')), length(profile_mod.CATEGORIES), "'1' means all");
t.eq(profile_mod.apply_categories('0'), {}, "'0' means none");

system(`rm -rf /tmp/uci-c && mkdir -p /tmp/uci-c && cp '${DIR}'/lg510s-vlanonly/* /tmp/uci-c/`);
let ccfg = 'switch.vlan.1.id=1\nswitch.vlan.1.mode=untagged\nswitch.vlan.1.status=enabled\nswitch.vlan.2.id=10\nswitch.vlan.2.mode=tagged\nswitch.vlan.2.status=enabled\nswitch.stp.status=enabled\nswitch.port.1.flowctrl=enabled\nswitch.port.1.status=disabled\n';
let cprof = { ...profile, bridge: 'switch', apply: true, apply_cats: { vlans: true } };
let res = apply.apply(ccfg, cprof, { uci_dir: '/tmp/uci-c', save_dir: '/tmp/uci-c/agent', user_save_dir: '/tmp/uci-c/user', log: () => null });
let cc = cursor('/tmp/uci-c', '/tmp/uci-c/none');
t.ok(res.applied, 'vlans applied');
t.eq(cc.get('network', 'unifi_vlan10', 'vlan'), '10', 'VLAN 10 created');
t.eq(cc.get('network', 'switch', 'stp'), null, 'STP not applied');
t.eq(cc.get('network', 'unifi_lan1'), null, 'no port settings applied');
t.ok(length(filter(res.withheld, (l) => index(l, 'stp') >= 0)) > 0, 'STP listed as withheld');
t.ok(length(filter(res.withheld, (l) => index(l, 'enabled') >= 0)) > 0, 'port disable listed as withheld');

t.done();
