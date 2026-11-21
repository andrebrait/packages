// SFP module data, from real `ethtool -m` output (a 10G passive DAC on an LG510S).
import * as t from 'assert';
import * as collect from 'unifi.collect';
import { readfile } from 'fs';

const DIR = sourcepath(0, true) + '/fixtures';
let s = collect.parse_sfp(readfile(DIR + '/ethtool-m-dac.txt'));

t.eq([ s.sfp_found, s.sfp_vendor, s.sfp_part, s.sfp_serial, s.sfp_rev, s.sfp_compliance ],
	[ true, 'OEM', 'SFP-10G-CU0.5M', '2409070005', 'B', 'Passive Cable' ], 'DAC fields');
t.eq(collect.parse_sfp('').sfp_found, false, 'no module');

// An optic with diagnostics (format from ethtool's sfpdiag.c), no light in.
let sr = collect.parse_sfp(readfile(DIR + '/ethtool-m-sr.txt'));
t.eq([ sr.sfp_compliance, sr.sfp_temperature, sr.sfp_voltage, sr.sfp_current, sr.sfp_txpower, sr.sfp_rxpower ],
	[ '10G Base-SR', '35.00', '3.3054', '6.026', '-2.31', '-40.00' ], 'optic with DOM');

// No type the patterns know: the first type as printed, not all of them.
let fx = collect.parse_sfp('\tTransceiver type : Ethernet: 100BASE-FX\n\tTransceiver type : FC: intermediate distance (I)\n');
t.eq(fx.sfp_compliance, 'Ethernet: 100BASE-FX', 'fallback is the first type');

// QSFP lane faults, and false survives as a value.
let q = collect.parse_sfp('\tTx fault : [ No, No, No, No ]\n\tRx loss of signal : [ Yes, No, No, No ]\n');
t.eq([ q.sfp_txfault, q.sfp_rxfault ], [ false, true ], 'QSFP faults');

// The uplink is the port where the gateway's MAC was learned: not the
// hardware's "self" copy nor a permanent entry, on the gateway's VLAN, and
// every member of a bond.
let ports = [ { idx: 1, dev: 'lan1' }, { idx: 2, dev: 'lan2' }, { idx: 5, dev: 'lan5' }, { idx: 6, dev: 'lan6' } ];
let fdb = [
	{ mac: 'aa:bb:cc:00:00:01', ifname: 'lan1', flags: [ 'self' ] },
	{ mac: 'aa:bb:cc:00:00:01', ifname: 'lan6', master: 'switch', state: 'permanent' },
	{ mac: 'aa:bb:cc:00:00:01', ifname: 'lan5', master: 'switch', vlan: 30 },
	{ mac: 'aa:bb:cc:00:00:01', ifname: 'lan2', master: 'switch', vlan: 1 },
	{ mac: 'aa:bb:cc:00:00:02', ifname: 'unifi_lag1', master: 'switch' }
];
let member = (d) => (d == 'lan5' || d == 'lan6') ? 'unifi_lag1' : d;
let idx = (l) => map(l, (p) => p.idx);
t.eq(idx(collect.uplink_ports(fdb, ports, 'aa:bb:cc:00:00:01', 1, member)), [ 2 ], 'learned port on the gateway VLAN');
t.eq(idx(collect.uplink_ports(fdb, ports, 'aa:bb:cc:00:00:01', null, member)), [ 5 ], 'any VLAN without one');
t.eq(idx(collect.uplink_ports(fdb, ports, 'aa:bb:cc:00:00:02', null, member)), [ 5, 6 ], 'all bond members');
t.eq([ collect.uplink_ports(fdb, ports, 'aa:bb:cc:00:00:03', null, member), collect.uplink_ports(fdb, ports, null, null, member) ], [ [], [] ], 'unknown or no gateway');
t.eq(collect.mac_tables(fdb, ports).lan2, [ { mac: 'aa:bb:cc:00:00:01', age: 0, uptime: 0, static: false, vlan: 1 } ], 'mac table skips self and permanent entries');

// The uplink report: every member flagged, the member with a neighbour (else
// with carrier) named, and the gateway standing in for a missing neighbour.
let rows = () => [ { port_idx: 1, up: true }, { port_idx: 5, up: false }, { port_idx: 6, up: true } ];
let bond = [ ports[2], ports[3] ];
let m = { port_table: rows(), lldp_table: [] };
collect.report_uplink(m, bond, 'aa:bb:cc:00:00:09');
t.eq([ map(m.port_table, (r) => r.is_uplink), m.uplink, m.lldp_table ],
	[ [ false, true, true ], 'Port 6', [ { local_port_idx: 6, local_port_name: 'Port 6', chassis_id: 'aa:bb:cc:00:00:09', is_wired: true } ] ], 'carrier member, gateway stands in');
m = { port_table: rows(), lldp_table: [ { local_port_idx: 5, local_port_name: 'Port 5', chassis_id: 'x', is_wired: true } ] };
collect.report_uplink(m, bond, 'aa:bb:cc:00:00:09');
t.eq([ m.uplink, length(m.lldp_table) ], [ 'Port 5', 1 ], 'member with a neighbour, none added');
m = { port_table: rows(), lldp_table: [] };
collect.report_uplink(m, [], null);
t.eq([ map(m.port_table, (r) => r.is_uplink), m.uplink, m.lldp_table ], [ [ false, false, false ], null, [] ], 'no uplink');

// The last uplink is kept while the gateway is unresolved and it has carrier.
let last = { devs: [ 'lan5', 'lan6' ], mac: 'aa:bb:cc:00:00:09' };
let carrier = (d) => d != 'lan6';
t.eq(collect.settle_uplink([ ports[1] ], 'aa:bb:cc:00:00:01', ports, last, carrier),
	[ [ ports[1] ], 'aa:bb:cc:00:00:01', { devs: [ 'lan2' ], mac: 'aa:bb:cc:00:00:01' } ], 'found');
t.eq(collect.settle_uplink([], 'aa:bb:cc:00:00:01', ports, last, carrier), [ [], 'aa:bb:cc:00:00:01', { devs: [], mac: 'aa:bb:cc:00:00:01' } ], 'gateway known but off the bridge: none');
t.eq(collect.settle_uplink([], null, ports, last, carrier), [ [ ports[2] ], 'aa:bb:cc:00:00:09', last ], 'unresolved keeps the members with carrier');
t.eq(collect.settle_uplink([], null, ports, last, () => false), [ [], null, last ], 'no carrier, no uplink');
t.eq(idx(collect.uplink_ports(fdb, ports, 'AA:BB:CC:00:00:01', 1, member)), [ 2 ], 'MAC case does not matter');

t.done();
