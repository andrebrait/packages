// SPDX-License-Identifier: GPL-2.0-only
// The one HTTP request the agent makes: POST a binary body, read the reply.

import * as socket from 'socket';

export function parse_url(url) {
	let m = match(url ?? '', /^http:\/\/(\[[^\]]+\]|[^\/:]+)(:([0-9]+))?(\/.*)?$/);

	if (!m)
		return null;

	return { host: trim(m[1], '[]'), port: +(m[3] ?? 80), path: m[4] ?? '/' };
};

function dechunk(body) {
	let out = '';

	while (length(body)) {
		let nl = index(body, '\r\n');
		let n = hex(split(substr(body, 0, nl), ';')[0]);

		if (nl < 0 || n != n || n == 0)
			break;

		out += substr(body, nl + 2, n);
		body = substr(body, nl + 2 + n + 2);
	}

	return out;
}

// Returns { status, body } or { error }. timeout in milliseconds.
export function post(url, body, timeout) {
	let u = parse_url(url);

	if (!u)
		return { error: `unsupported URL ${url}` };

	timeout ??= 15000;

	let s = socket.connect(u.host, u.port, null, timeout);

	if (!s)
		return { error: `connect ${u.host}:${u.port}: ${socket.error()}` };

	let tv = { sec: int(timeout / 1000), usec: (timeout % 1000) * 1000 };

	if (!s.setopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, tv) ||
	    !s.setopt(socket.SOL_SOCKET, socket.SO_SNDTIMEO, tv)) {
		s.close();
		return { error: `socket timeout: ${socket.error()}` };
	}

	let req = `POST ${u.path} HTTP/1.1\r\n` +
		`Host: ${u.host}:${u.port}\r\n` +
		'User-Agent: AirControl Agent v1.0\r\n' +
		'Content-Type: application/x-binary\r\n' +
		`Content-Length: ${length(body)}\r\n` +
		'Connection: close\r\n\r\n' + body;

	for (let off = 0; off < length(req); ) {
		let n = s.send(substr(req, off));

		if (n == null || n <= 0) {
			s.close();
			return { error: `send: ${socket.error()}` };
		}

		off += n;
	}

	let resp = '', deadline = time() + 2 * timeout / 1000;

	while (true) {
		if (time() > deadline) {
			s.close();
			return { error: 'reply took too long' };
		}

		let chunk = s.recv(65536);

		if (chunk == null) {
			s.close();
			return { error: `recv: ${socket.error()}` };
		}

		if (!length(chunk))
			break;

		resp += chunk;

		// An inform reply is a few KB; never buffer an unbounded answer.
		if (length(resp) > 1048576) {
			s.close();
			return { error: 'reply larger than 1 MiB' };
		}
	}

	s.close();

	let end = index(resp, '\r\n\r\n');
	let st = match(resp, /^HTTP\/1\.[01] ([0-9]{3})/);

	if (end < 0 || !st)
		return { error: 'malformed HTTP response' };

	let head = lc(substr(resp, 0, end));
	let data = substr(resp, end + 4);
	let cl = match(head, /\ncontent-length: *([0-9]+)/);

	if (match(head, /\ntransfer-encoding: *chunked/))
		data = dechunk(data);
	else if (cl)
		data = substr(data, 0, +cl[1]);

	return { status: +st[1], body: data };
};
