// SPDX-License-Identifier: GPL-2.0-only
// Applies a system_cfg: translate to UCI, commit, reload, and roll back if
// the controller can no longer be reached afterwards.

import { cursor } from 'uci';
import { readfile, unlink, lsdir, stat } from 'fs';
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

	if ('switchdev' in pkgs && sw.has_switchdev())
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
	// libuci always loads the shared delta directory (/tmp/.uci) too, so
	// changes a user staged with the uci CLI would be committed with the
	// controller's. Wait until they are committed or reverted.
	let user = cursor(opts.uci_dir, opts.user_save_dir);

	for (let pkg in PACKAGES) {
		if (length(user.changes(pkg)?.[pkg] ?? [])) {
			log(`uncommitted uci changes to ${pkg}; commit or revert them, the controller's settings wait until then`);
			return { changed: false, applied: false, rolled_back: false, deferred: true, notes: [], plan: [], unhandled: unhandled(cfg) };
		}
	}

	// The agent's own deltas, apart from the CLI's and from a concurrent
	// `unifi-agent plan`.
	let save_dir = opts.save_dir ?? (opts.dry_run ? '/tmp/unifi-agent/uci-plan' : '/tmp/unifi-agent/uci');

	util.mkdir_p(save_dir, 0o700);

	for (let f in lsdir(save_dir) ?? [])
		unlink(`${save_dir}/${f}`);

	let c = cursor(opts.uci_dir, save_dir);
	let notes = [];

	// Switch keys come for switches and for APs with a built-in switch; an
	// AP without them keeps its bridge as it is.
	if (length(filter(keys(cfg), (k) => match(k, /^switch\.(vlan|port)\./))))
		notes = [ ...notes, ...sw.plan(cfg, profile, c) ];

	if (length(profile.radios))
		notes = [ ...notes, ...wifi.plan(cfg, profile, c) ];

	let changes = {}, touched = [];

	for (let pkg in PACKAGES) {
		let ch = c.changes(pkg)?.[pkg];

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

	// Back up, commit, reload, check, and undo on failure. A package file
	// that did not exist is removed again on rollback.
	util.mkdir_p(BACKUP, 0o700);

	let confdir = opts.uci_dir ?? '/etc/config';
	let backup = {}, modes = {};

	for (let pkg in touched) {
		backup[pkg] = readfile(`${confdir}/${pkg}`);
		modes[pkg] = (stat(`${confdir}/${pkg}`)?.mode ?? 0o644) & 0o777;

		if (backup[pkg] != null && !util.write_file(`${BACKUP}/${pkg}`, backup[pkg], 0o600)) {
			log(`cannot back up ${pkg}; nothing applied`);

			for (let p in touched)
				c.revert(p);

			return res;
		}
	}

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

		for (let pkg in touched) {
			if (backup[pkg] == null)
				unlink(`${confdir}/${pkg}`);
			else
				util.write_file(`${confdir}/${pkg}`, backup[pkg], modes[pkg]);
		}

		reload(touched);
		res.rolled_back = true;
	}

	return res;
};
