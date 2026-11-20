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

t.done();
