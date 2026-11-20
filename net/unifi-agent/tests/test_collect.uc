// SFP module data, from real `ethtool -m` output (a 10G passive DAC on an LG510S).
import * as t from 'assert';
import * as collect from 'unifi.collect';
import { readfile } from 'fs';

const DIR = sourcepath(0, true) + '/fixtures';
let s = collect.parse_sfp(readfile(DIR + '/ethtool-m-dac.txt'));

t.eq([ s.sfp_found, s.sfp_vendor, s.sfp_part, s.sfp_serial, s.sfp_rev, s.sfp_compliance ],
	[ true, 'OEM', 'SFP-10G-CU0.5M', '2409070005', 'B', 'Passive Cable' ], 'DAC fields');
t.eq(collect.parse_sfp('').sfp_found, false, 'no module');

t.done();
