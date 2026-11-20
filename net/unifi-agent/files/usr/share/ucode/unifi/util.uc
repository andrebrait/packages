// SPDX-License-Identifier: GPL-2.0-only
// Small helpers shared by the agent's modules.

import { readfile, writefile, popen, rename, mkdir, stat, chmod, unlink } from 'fs';

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

// Atomic write. With a mode, the file gets it before any data is in it.
// The temporary name is unique, so two writers never share it.
export function write_file(path, data, mode) {
	let now = clock();
	let tmp = `${path}.${now[0]}${now[1]}.tmp`;

	if ((mode != null && (writefile(tmp, '') == null || !chmod(tmp, mode))) ||
	    writefile(tmp, data) == null || !rename(tmp, path)) {
		unlink(tmp);
		return false;
	}

	return true;
};

export function mkdir_p(path, mode) {
	let p = '';

	for (let part in split(path, '/')) {
		if (part == '')
			continue;

		p += '/' + part;

		if (!stat(p))
			mkdir(p, mode ?? 0o755);
	}
};

// An inform URL as the controller sends it: http://<IPv4>[:port]/inform.
// Octets with leading zeros are refused: the resolver reads them as octal.
export function inform_url_ok(url) {
	let m = match(url ?? '', /^http:\/\/(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})(:([1-9][0-9]{0,4}))?\/inform$/);

	if (!m)
		return false;

	for (let i = 1; i <= 4; i++)
		if (+m[i] > 255)
			return false;

	return m[6] == null || +m[6] <= 65535;
};

// A UCI boolean, read the way config_get_bool does.
export function bool(v, dflt) {
	if (v in [ '1', 'on', 'true', 'yes', 'enabled' ])
		return true;

	if (v in [ '0', 'off', 'false', 'no', 'disabled' ])
		return false;

	return !!dflt;
};

export function matches_any(list, s) {
	for (let re in list)
		if (match(s, re))
			return true;

	return false;
};

// Sets (or, for null, deletes) one option only when it differs, so an
// unchanged config leaves no uci delta behind. Numbers and booleans are
// stored as UCI strings.
export function setopt(c, pkg, sec, opt, val) {
	let cur = c.get(pkg, sec, opt);

	if (type(val) == 'bool')
		val = val ? '1' : '0';
	else if (type(val) == 'int' || type(val) == 'double')
		val = `${val}`;

	if (val == null) {
		if (cur != null)
			c.delete(pkg, sec, opt);
	}
	else if (sprintf('%J', cur) != sprintf('%J', val)) {
		c.set(pkg, sec, opt, val);
	}
};

// Runs argv (each argument single-quoted for the shell) and returns
// stdout, or null on failure.
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
