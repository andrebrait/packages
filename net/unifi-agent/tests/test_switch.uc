// switch.* keys from a captured controller config, applied to a copy of
// the LG510S network config.
import * as t from 'assert';
import * as sw from 'unifi.switch';
import * as util from 'unifi.util';
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

t.done();
