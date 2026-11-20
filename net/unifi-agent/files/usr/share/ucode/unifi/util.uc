// SPDX-License-Identifier: GPL-2.0-only
// Small helpers shared by the agent's modules.

import { readfile, writefile, popen, rename, mkdir, stat } from 'fs';

// UniFi's flat "a.b.c=value" text (mgmt_cfg, system_cfg) as an object.
export function parse_kv(text) {
	let cfg = {};

	for (let line in split(text ?? '', '\n')) {
		let eq = index(line, '=');

		if (eq > 0 && substr(line, 0, 1) != '#')
			cfg[trim(substr(line, 0, eq))] = substr(line, eq + 1);
	}

	return cfg;
};

export function read(path) {
	let s = readfile(path);
	return (s != null) ? trim(s) : null;
};

export function read_json(path) {
	let s = readfile(path);

	if (s == null)
		return null;

	try {
		return json(s);
	}
	catch (e) {
		return null;
	}
};

// Atomic write; mode applies to the new file.
export function write_file(path, data, mode) {
	let tmp = `${path}.tmp`;

	if (writefile(tmp, data) == null)
		return false;

	if (mode != null)
		system(['chmod', sprintf('%o', mode), tmp]);

	return rename(tmp, path);
};

export function mkdir_p(path) {
	let p = '';

	for (let part in split(path, '/')) {
		if (part == '')
			continue;

		p += '/' + part;

		if (!stat(p))
			mkdir(p, 0o700);
	}
};

// Runs argv (an array, never through a shell) and returns stdout or null.
export function run(argv) {
	let cmd = join(' ', map(argv, (a) => "'" + replace(a, "'", "'\\''") + "'"));
	let p = popen(cmd + ' 2>/dev/null', 'r');

	if (!p)
		return null;

	let out = p.read('all');
	let rc = p.close();

	return (rc == 0) ? out : null;
};

export function run_json(argv) {
	let out = run(argv);

	if (out == null)
		return null;

	try {
		return json(out);
	}
	catch (e) {
		return null;
	}
};

// Natural order: lan2 before lan10.
export function natcmp(a, b) {
	let ma = match(a, /^(.*?)([0-9]+)$/), mb = match(b, /^(.*?)([0-9]+)$/);

	if (ma && mb && ma[1] == mb[1])
		return +ma[2] - +mb[2];

	return (a < b) ? -1 : (a > b) ? 1 : 0;
};
