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
import { CATEGORIES } from 'unifi.profile';

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
	let staged = () => {
		let user = cursor(opts.uci_dir, opts.user_save_dir);

		for (let pkg in PACKAGES)
			if (length(user.changes(pkg)?.[pkg] ?? []))
				return pkg;

		return null;
	};
	let deferred = (pkg) => {
		log(`uncommitted uci changes to ${pkg}; commit or revert them, the controller's settings wait until then`);
		return { changed: false, applied: false, rolled_back: false, deferred: true, notes: [], plan: [], unhandled: unhandled(cfg) };
	};
	let pending = staged();

	if (pending)
		return deferred(pending);

	// The agent's own deltas, apart from the CLI's and from a concurrent
	// `unifi-agent plan`.
	let save_dir = opts.save_dir ?? (opts.dry_run ? '/tmp/unifi-agent/uci-plan' : '/tmp/unifi-agent/uci');

	util.mkdir_p(save_dir, 0o700);

	for (let f in lsdir(save_dir) ?? [])
		unlink(`${save_dir}/${f}`);

	// Switch keys come for switches and for APs with a built-in switch; an
	// AP without them keeps its bridge as it is.
	let switch_keys = length(filter(keys(cfg), (k) => match(k, /^switch\.(vlan|port)\./))) > 0;

	// Plans into cursor c; cats null means every category.
	let plan_into = (c, cats) => {
		let n = [];

		if (switch_keys)
			n = [ ...n, ...sw.plan(cfg, profile, c, cats) ];

		// The switch side owns WLAN VLAN membership only when it applies VLANs.
		if (length(profile.radios) && (!cats || cats.wifi))
			n = [ ...n, ...wifi.plan(cfg, profile, c, switch_keys && (!cats || cats.vlans)) ];

		return n;
	};
	let changes_of = (c) => {
		let out = {};

		for (let pkg in PACKAGES) {
			let ch = c.changes(pkg)?.[pkg];

			if (type(ch) == 'array' && length(ch))
				out[pkg] = ch;
		}

		return out;
	};

	// Log only plans everything; otherwise (a dry run included) only the
	// chosen categories.
	let logging = opts.dry_run || !profile.apply;
	let cats = profile.apply ? profile.apply_cats : null;
	let c = cursor(opts.uci_dir, save_dir);
	let notes = plan_into(c, cats);
	let changes = changes_of(c), touched = keys(changes);
	let withheld = [];

	// What the categories left out is still logged, as not applied.
	if (cats && length(cats) < length(CATEGORIES)) {
		let full_dir = `${save_dir}-full`;

		util.mkdir_p(full_dir, 0o700);

		for (let f in lsdir(full_dir) ?? [])
			unlink(`${full_dir}/${f}`);

		let full = cursor(opts.uci_dir, full_dir);
		plan_into(full, null);

		// By option, not by line: a value the chosen categories changed
		// differently was applied, just not as the full plan has it.
		let key = (l) => split(l, ' ')[1];
		let applied = map(describe(changes), key);
		withheld = filter(describe(changes_of(full)), (l) => !(key(l) in applied));

		for (let pkg in PACKAGES)
			full.revert(pkg);
	}

	let res = {
		changed: length(touched) > 0,
		applied: false,
		rolled_back: false,
		notes,
		plan: describe(changes),
		withheld,
		unhandled: unhandled(cfg)
	};

	for (let n in notes)
		log(`note: ${n}`);

	for (let l in withheld)
		log(`not applied: ${l}`);

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
			log(`cannot back up ${pkg}; nothing applied, will retry`);

			for (let p in touched)
				c.revert(p);

			res.failed = true;
			return res;
		}
	}

	// The CLI may have staged something while this was planned.
	pending = staged();

	if (pending) {
		for (let p in touched)
			c.revert(p);

		return deferred(pending);
	}

	for (let pkg in touched)
		c.commit(pkg);

	if (!opts.no_reload)
		reload(touched);

	res.applied = true;

	// One minute by the clock, however long each connection attempt takes
	// (the init script gives a stop 90 s, to leave time for the restore).
	let url = opts.inform_url;
	let deadline = time() + 60;
	let ok = !url;

	while (!ok && time() < deadline) {
		sleep(5000);
		ok = reachable(url);
	}

	if (!ok) {
		log('controller unreachable after applying; rolling back');

		let restore = (pkg) => (backup[pkg] == null)
			? (unlink(`${confdir}/${pkg}`) || !stat(`${confdir}/${pkg}`))
			: util.write_file(`${confdir}/${pkg}`, backup[pkg], modes[pkg]);
		let failed = [];

		for (let pkg in touched)
			if (!restore(pkg) && !restore(pkg))
				push(failed, pkg);

		reload(touched);

		if (length(failed)) {
			// The backups stay in /tmp/unifi-agent/rollback for a manual restore.
			log(`ROLLBACK FAILED for ${join(', ', failed)}; copies are in ${BACKUP}`);
			res.failed = true;
		}
		else {
			res.rolled_back = true;
		}
	}

	return res;
};
