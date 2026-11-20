// Model choice and port mapping, with the hardware probe stubbed.
import * as t from 'assert';
import * as profile from 'unifi.profile';

const DIR = sourcepath(0, true) + '/fixtures';
const models = profile.load_models(DIR + '/../../files/usr/share/unifi-agent/models.json');

// LG510S: lan1-4 10GBASE-T, lan5-6 SFP+.
function lg510s(dev) {
	let n = +substr(dev, 3);
	return (n <= 4)
		? { media: 'GE', speed_caps: 1049064, speeds: [ 100, 1000, 2500, 5000, 10000 ], max_speed: 10000 }
		: { media: 'SFP+', speed_caps: 288, speeds: [ 1000, 10000 ], max_speed: 10000 };
}

let p = profile.load({ uci_dir: DIR + '/config', models, probe: lg510s });
t.eq(p.model, 'US6XG150', 'auto model for 4 copper + 2 SFP+');
t.eq(map(p.ports, (x) => [ x.idx, x.dev, x.model_media ]),
	[ [1, 'lan1', 'GE'], [2, 'lan2', 'GE'], [3, 'lan3', 'GE'], [4, 'lan4', 'GE'],
	  [5, 'lan5', 'SFP+'], [6, 'lan6', 'SFP+'] ], 'port map');
t.eq(p.type, 'usw', 'type');

// An 8-copper switch maps onto the smallest model with room, PoE-free first.
let eight = map([1,2,3,4,5,6,7,8], (i) => ({ dev: `lan${i}`, media: 'GE' }));
let s = profile.suggest(models, eight, []);
t.ok(length(s) > 0, 'some model for 8 copper');
t.eq(length(filter(profile.model_ports(models[s[0]]), (x) => !profile.is_fiber(x.media))), 8, '8-copper pick has 8 copper ports');

// Explicit index wins, the rest fill in by media.
let m = profile.map_ports(profile.model_ports(models.US6XG150), [
	{ dev: 'a', media: 'GE', unifi: 4 }, { dev: 'b', media: 'GE' }, { dev: 'c', media: 'SFP+' } ]);
t.eq(map(m, (x) => [ x.idx, x.dev ]), [ [1, 'b'], [4, 'a'], [5, 'c'] ], 'explicit mapping');

// AP: dual band picks the measured U7PG2.
t.eq(profile.suggest(models, [ { media: 'GE' } ], [ { radio: 'ng' }, { radio: 'na' } ])[0], 'U7PG2', 'dual-band AP');

let et = profile.parse_ethtool(`Settings for lan1:
	Supported ports: [ TP ]
	Supported link modes:   100baseT/Full
	                        1000baseT/Full
	                        2500baseT/Full
	                        5000baseT/Full
	                        10000baseT/Full
	Supported pause frame use: Symmetric Receive-only
	Supports auto-negotiation: Yes
	Speed: 10000Mb/s
`);
t.eq(et.speed_caps, 1049064, 'speed_caps from ethtool matches the lab value');
t.eq(et.speeds, [ 100, 1000, 2500, 5000, 10000 ], 'speeds');

t.done();
