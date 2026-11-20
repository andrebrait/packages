// SPDX-License-Identifier: GPL-2.0-only
// SSH adoption: while the device is pending, a "ubnt" account (password
// ubnt, as on a factory-default UniFi device) whose only shell is
// /usr/libexec/unifi-agent/ssh-adopt. Requests it records are checked here.

import { readfile, lsdir, unlink, stat } from 'fs';
import * as util from 'unifi.util';

const SPOOL = '/tmp/unifi-agent/ssh';
const SHELL = '/usr/libexec/unifi-agent/ssh-adopt';
const USER = 'ubnt';
const UID = 1100;
// md5-crypt of "ubnt", the factory password a controller tries.
const HASH = '$1$unifiagt$HYXHUB9mIPnTdH0YahgMJ1';

function edit(path, line, present) {
	let text = readfile(path);

	if (text == null)
		return false;

	let lines = filter(split(text, '\n'), (l) => l != '' && substr(l, 0, length(USER) + 1) != `${USER}:`);

	if (present)
		push(lines, line);

	let out = join('\n', lines) + '\n';

	if (out == text)
		return false;

	return util.write_file(path, out, (path == '/etc/shadow') ? 0o600 : 0o644);
}

// Adds or removes the account. Returns true when something changed.
export function account(present, root) {
	root ??= '';

	let changed = edit(`${root}/etc/passwd`, `${USER}:x:${UID}:${UID}:UniFi adoption:/var/empty:${SHELL}`, present);
	changed = edit(`${root}/etc/shadow`, `${USER}:${HASH}:0:0:99999:7:::`, present) || changed;

	if (present) {
		let shells = readfile(`${root}/etc/shells`) ?? '';

		if (index(shells, SHELL) < 0)
			util.write_file(`${root}/etc/shells`, shells + SHELL + '\n', 0o644);

		if (!stat(SPOOL)) {
			util.mkdir_p(SPOOL);
			system([ 'chmod', '1733', SPOOL ]);
		}
	}

	return changed;
};

// Parses one recorded command: { url, key } (key may be null).
export function parse(cmd) {
	let m = match(cmd, /set-adopt\s+(\S+)\s+([0-9a-fA-F]{32})(\s|$)/);
	let url, key = null;

	if (m) {
		url = m[1];
		key = lc(m[2]);
	}
	else if ((m = match(cmd, /set-inform\s+(\S+)/))) {
		url = m[1];
	}
	else {
		return null;
	}

	// The controller always sends an IP-literal inform URL.
	if (!match(url, /^http:\/\/[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?\/inform$/))
		return null;

	return { url, key };
};

// Takes the queued requests (oldest first) and removes them.
export function take() {
	let out = [];

	for (let f in sort(lsdir(SPOOL) ?? [])) {
		if (substr(f, 0, 4) != 'req.' || substr(f, -4) == '.tmp')
			continue;

		let r = parse(trim(readfile(`${SPOOL}/${f}`) ?? ''));

		unlink(`${SPOOL}/${f}`);

		if (r)
			push(out, r);
	}

	return out;
};
