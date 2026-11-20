// SPDX-License-Identifier: GPL-2.0-only
// Applies a system_cfg: translate to UCI, commit, reload, and roll back if
// the controller can no longer be reached afterwards.

import { cursor } from 'uci';
import { readfile, writefile, stat } from 'fs';
import * as socket from 'socket';
import * as util from 'unifi.util';
import * as http from 'unifi.http';
import * as sw from 'unifi.switch';
import * as wifi from 'unifi.wifi';

const PACKAGES = [ 'network', 'switchdev', 'wireless' ];
const BACKUP = '/tmp/unifi-agent/rollback';

// Keys under switch.*, wireless.*, aaa.*, radio.* that nothing applies.
export function unhandled(cfg) {
	let out = [];

	for (let k in sort(keys(cfg))) {
		if (match(k, /^switch\./) && !sw.handled(k))
			push(out, k);
		else if (match(k, /^(wireless|aaa|radio)\./) && !wifi.handled(k))
			push(out, k);
	}

	return out;
};

function reachable(url) {
	let u = http.parse_url(url);

	if (!u)
		return true;

	let s = socket.connect(u.host, u.port, null, 3000);

	if (s) {
		s.close();
		return true;
	}

	return false;
}

function reload(pkgs) {
	if ('network' in pkgs || 'wireless' in pkgs)
		system('ubus call network reload');

	if ('wireless' in pkgs)
		system('wifi reload');

	if ('switchdev' in pkgs && stat('/etc/init.d/switchdev'))
		system('/etc/init.d/switchdev restart');
}

// Describes a uci delta without secrets.
function describe(changes) {
	let out = [];

	for (let pkg, list in changes) {
		for (let ch in list) {
			let v = ch[3];

			if (match(ch[2] ?? '', /^(key|password|auth_secret|acct_secret|sae_password)$/))
				v = '<secret>';

			push(out, join(' ', filter([ ch[0], `${pkg}.${ch[1]}${ch[2] ? '.' + ch[2] : ''}`, (v != null) ? sprintf('%J', v) : null ], (x) => x != null)));
		}
	}

	return out;
}

// Returns { changed, applied, rolled_back, notes, plan, unhandled }.
// opts: { dry_run, uci_dir, save_dir, inform_url, log }
export function apply(text, profile, opts) {
	opts ??= {};

	let log = opts.log ?? warn;
	let cfg = util.parse_kv(text);
	let c = cursor(opts.uci_dir, opts.save_dir);
	let notes = [];

	// Switch keys come for switches and for APs with a built-in switch; an
	// AP without them keeps its bridge as it is.
	if (length(filter(keys(cfg), (k) => match(k, /^switch\.(vlan|port)\./))))
		notes = [ ...notes, ...sw.plan(cfg, profile, c) ];

	if (length(profile.radios))
		notes = [ ...notes, ...wifi.plan(cfg, profile, c) ];

	let changes = {}, touched = [];

	for (let pkg in PACKAGES) {
		let ch = c.changes(pkg)?.[pkg] ?? c.changes(pkg);

		if (type(ch) == 'array' && length(ch)) {
			changes[pkg] = ch;
			push(touched, pkg);
		}
	}

	let res = {
		changed: length(touched) > 0,
		applied: false,
		rolled_back: false,
		notes,
		plan: describe(changes),
		unhandled: unhandled(cfg)
	};

	for (let n in notes)
		log(`note: ${n}`);

	if (!res.changed)
		return res;

	for (let l in res.plan)
		log(`plan: ${l}`);

	if (opts.dry_run || !profile.apply) {
		for (let pkg in touched)
			c.revert(pkg);

		return res;
	}

	// Back up, commit, reload, check, and undo on failure.
	util.mkdir_p(BACKUP);

	let confdir = opts.uci_dir ?? '/etc/config';

	for (let pkg in touched)
		writefile(`${BACKUP}/${pkg}`, readfile(`${confdir}/${pkg}`) ?? '');

	for (let pkg in touched)
		c.commit(pkg);

	reload(touched);
	res.applied = true;

	let url = opts.inform_url;
	let ok = false;

	for (let i = 0; i < 12 && !ok; i++) {
		sleep(5000);
		ok = !url || reachable(url);
	}

	if (!ok) {
		log('controller unreachable after applying; rolling back');

		for (let pkg in touched)
			util.write_file(`${confdir}/${pkg}`, readfile(`${BACKUP}/${pkg}`) ?? '');

		reload(touched);
		res.rolled_back = true;
	}

	return res;
};
