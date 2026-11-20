// Regressions from the first review round of the package PR.
import * as t from 'assert';
import * as inform from 'unifi.inform';
import * as sw from 'unifi.switch';
import * as wifi from 'unifi.wifi';
import * as ssh from 'unifi.sshadopt';
import * as session from 'unifi.session';
import * as util from 'unifi.util';
import * as apply from 'unifi.apply';
import * as struct from 'struct';
import * as zlib from 'zlib';
import { cursor } from 'uci';
import { readfile, stat } from 'fs';

const DIR = sourcepath(0, true) + '/fixtures';
const K = inform.DEFAULT_KEY;
const MSG = '{"_type":"setparam","mgmt_cfg":"authkey=ffffffffffffffffffffffffffffffff"}';

// An unencrypted reply (flags 0 or zlib only) must not be accepted.
for (let flags in [ 0, 2 ]) {
	let body = (flags & 2) ? zlib.deflate(MSG) : MSG;
	let pkt = struct.pack('>II6sH16sII', 0x544E4255, 0, hexdec('002722e00054'), flags,
		hexdec('000102030405060708090a0b0c0d0e0f'), 1, length(body)) + body;
	t.eq(inform.decode(pkt, K).error, 'unencrypted packet', `flags ${flags} refused`);
}

// Once GCM is negotiated, a CBC reply is refused.
let cbc = inform.encode('00:27:22:e0:00:54', K, false, MSG);
t.eq(inform.decode(cbc, K, true).error, 'not AES-GCM', 'CBC refused after GCM');
t.eq(inform.decode(cbc, K, false).data, MSG, 'CBC accepted before GCM');

// A controller set-adopt with a malformed key or URL changes nothing.
let st = {};
session.handle(st, { interval: 10, radios: [] }, { _type: 'cmd', cmd: 'set-adopt', key: 'abc', uri: 'http://x/<img>' });
t.eq(st, {}, 'bad set-adopt ignored');
session.handle(st, { interval: 10, radios: [] }, { _type: 'cmd', cmd: 'set-adopt', uri: 'http://10.0.0.2:8080/inform' });
t.eq(st.inform_url, 'http://10.0.0.2:8080/inform', 'good URL taken');

// UCI booleans read like config_get_bool.
t.eq([ util.bool('false', true), util.bool('off', true), util.bool('yes', false), util.bool(null, true) ], [ false, false, true, true ], 'bool');

// htmode keeps HE/EHT on 2.4 GHz too.
t.eq(wifi.htmode('11nght20', 'HE20'), 'HE20', '2.4 GHz HE kept');
t.eq(wifi.htmode('11nght40', 'EHT20'), 'EHT40', '2.4 GHz EHT kept');

// Unblock removes the client from the renewed block list.
let ap = { radios: [ { name: 'wifi0', device: 'radio0' } ] };
let s2 = { blocked: [ 'aa:bb:cc:dd:ee:ff' ] };
t.ok(wifi.command(ap, { cmd: 'unblock-sta', mac: 'AA:BB:CC:DD:EE:FF' }, s2), 'unblock handled');
t.eq(s2.blocked, [], 'unblock clears the ban list');
t.eq(wifi.parse_blocked('aa:bb:cc:dd:ee:01, junk ,AA:BB:CC:DD:EE:02'), [ 'aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02' ], 'blocked_sta parsed');

// Switch: a management VLAN missing from the VLAN list leaves VLANs alone;
// a stale bond is removed; fast leave reaches the port.
system(`rm -rf /tmp/uci-r && mkdir -p /tmp/uci-r/save && cp ${DIR}/lg510s/* /tmp/uci-r/`);
let profile = {
	bridge: 'switch', mgmt_interface: 'lan',
	model_ports: map([1,2,3,4,5,6], (i) => ({ idx: i })),
	ports: map([1,2,3,4,5,6], (i) => ({ idx: i, dev: `lan${i}`, speeds: [ 1000, 10000 ] }))
};
let c = cursor('/tmp/uci-r', '/tmp/uci-r/save');
let notes = sw.plan(util.parse_kv('switch.managementvlan=10\nswitch.vlan.1.id=1\nswitch.vlan.1.mode=untagged\nswitch.vlan.1.status=enabled\n'), profile, c);
t.eq(c.get('network', 'lan', 'device'), 'switch.1', 'mgmt interface untouched');
t.ok(length(filter(c.changes('network')?.network ?? [], (ch) => ch[0] == 'remove' && index(ch[1], 'cfg') == 0)) == 0, 'existing bridge-vlan kept');
t.ok(length(filter(notes, (n) => index(n, 'management VLAN 10') >= 0)) == 1, 'noted');

c = cursor('/tmp/uci-r', '/tmp/uci-r/save2');
let lagcfg = 'switch.vlan.1.id=1\nswitch.vlan.1.mode=untagged\nswitch.vlan.1.status=enabled\nswitch.vlan.1.igmp_snooping=true\nswitch.vlan.1.igmp_fastleave=true\nswitch.port.3.opmode=aggregate\nswitch.port.3.lag=1\nswitch.port.4.opmode=aggregate\nswitch.port.4.lag=1\n';
sw.plan(util.parse_kv(lagcfg), profile, c);
t.eq(c.get('network', 'unifi_lan1', 'multicast_fast_leave'), '1', 'fast leave on member port');
c.commit('network');
c = cursor('/tmp/uci-r', '/tmp/uci-r/save3');
sw.plan(util.parse_kv('switch.vlan.1.id=1\nswitch.vlan.1.mode=untagged\nswitch.vlan.1.status=enabled\n'), profile, c);
t.eq(c.get('network', 'unifi_lag1'), null, 'stale bond removed');
t.ok('lan3' in c.get('network', c.get_first('network', 'device'), 'ports'), 'former member back in the bridge');

// Apply never reads or reverts deltas a user staged in the default save dir.
let user = cursor('/tmp/uci-r', '/tmp/uci-r/user');
user.set('network', 'lan', 'ipaddr', '10.9.9.9');
user.save('network');
apply.apply('switch.vlan.1.id=1\nswitch.vlan.1.mode=untagged\nswitch.vlan.1.status=enabled\nswitch.port.1.isolation=enabled\n',
	{ ...profile, apply: true }, { dry_run: true, uci_dir: '/tmp/uci-r', save_dir: '/tmp/uci-r/agent', log: () => null });
t.eq(cursor('/tmp/uci-r', '/tmp/uci-r/user').changes('network')?.network, [ [ 'set', 'lan', 'ipaddr', '10.9.9.9' ] ], 'user delta untouched');

// SSH adoption: a ubnt account the agent did not create is left alone,
// and the spool's parent is traversable.
system('rm -rf /tmp/ssh-r && mkdir -p /tmp/ssh-r/etc && printf "ubnt:x:1000:1000::/home/ubnt:/bin/ash\\n" > /tmp/ssh-r/etc/passwd && : > /tmp/ssh-r/etc/shadow && : > /tmp/ssh-r/etc/shells');
t.ok(!ssh.account(true, '/tmp/ssh-r'), 'foreign ubnt not replaced');
t.ok(!ssh.account(false, '/tmp/ssh-r'), 'foreign ubnt not removed');
system('printf "root:x:0:0::/root:/bin/ash\\n" > /tmp/ssh-r/etc/passwd && mkdir -p /tmp/ssh-r/tmp/unifi-agent && chmod 700 /tmp/ssh-r/tmp/unifi-agent');
ssh.account(true, '/tmp/ssh-r');
t.eq(sprintf('%o', stat('/tmp/ssh-r/tmp/unifi-agent').mode & 0o7777), '755', 'spool parent opened up');
t.eq(sprintf('%o', stat('/tmp/ssh-r/tmp/unifi-agent/ssh').mode & 0o7777), '1733', 'spool mode');

t.done();
