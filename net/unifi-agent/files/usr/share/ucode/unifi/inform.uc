// SPDX-License-Identifier: GPL-2.0-only
// UniFi inform packet codec: 40-byte TNBU header, zlib, AES-128-CBC or -GCM.

import * as aes from 'unifi.aes';
import * as zlib from 'zlib';
import * as struct from 'struct';
import { open } from 'fs';

const MAGIC = 0x544E4255;	// "TNBU"
const HDR = '>II6sH16sII';
const HDR_LEN = 40;

export const FLAG_ENCRYPTED = 0x01;
export const FLAG_ZLIB = 0x02;
export const FLAG_SNAPPY = 0x04;
export const FLAG_GCM = 0x08;

// MD5("ubnt"): the key every UniFi device uses until adoption.
export const DEFAULT_KEY = 'ba86f2bbe107c7c57eb5f2690775c712';

export function random_bytes(n) {
	let f = open('/dev/urandom');
	let b = f.read(n);
	f.close();
	return b;
};

function header(mac, flags, iv, len) {
	return struct.pack(HDR, MAGIC, 0, hexdec(replace(mac, /:/g, '')), flags, iv, 1, len);
}

// Returns the packet to POST, or null if the key is not 32 hex digits.
export function encode(mac, keyhex, gcm, plain, iv) {
	let key = hexdec(keyhex ?? '');

	if (length(key) != 16)
		return null;

	iv ??= random_bytes(16);

	let comp = zlib.deflate(plain);
	let flags = FLAG_ENCRYPTED | FLAG_ZLIB | (gcm ? FLAG_GCM : 0);

	if (gcm) {
		// The AAD is the header as sent, so its length must include the tag.
		let hdr = header(mac, flags, iv, length(comp) + 16);
		return hdr + aes.gcm_encrypt(key, iv, hdr, comp);
	}

	let ct = aes.cbc_encrypt(key, iv, comp);
	return header(mac, flags, iv, length(ct)) + ct;
};

// Returns { flags, mac, data } with data the decrypted, inflated payload
// string, or { error }. Unencrypted packets are refused, and so are CBC
// packets when require_gcm is set.
export function decode(body, keyhex, require_gcm) {
	if (length(body) < HDR_LEN)
		return { error: 'short packet' };

	let h = struct.unpack(HDR, body);

	if (h[0] != MAGIC)
		return { error: 'bad magic' };

	if (h[5] != 1)
		return { error: `data version ${h[5]}` };

	let flags = h[3], iv = h[4], len = h[6];

	if (len > length(body) - HDR_LEN)
		return { error: 'truncated payload' };

	if (!(flags & (FLAG_ENCRYPTED | FLAG_GCM)))
		return { error: 'unencrypted packet' };

	if (require_gcm && !(flags & FLAG_GCM))
		return { error: 'not AES-GCM' };

	let data = substr(body, HDR_LEN, len);
	let key = hexdec(keyhex ?? '');

	if (flags & FLAG_GCM)
		data = (length(key) == 16) ? aes.gcm_decrypt(key, iv, substr(body, 0, HDR_LEN), data) : null;
	else if (flags & FLAG_ENCRYPTED)
		data = (length(key) == 16) ? aes.cbc_decrypt(key, iv, data) : null;

	if (data == null)
		return { error: 'decrypt failed' };

	if (flags & FLAG_SNAPPY)
		return { error: 'snappy payload not supported' };

	if (flags & FLAG_ZLIB) {
		try {
			data = zlib.inflate(data);
		}
		catch (e) {
			data = null;
		}
	}

	if (data == null)
		return { error: 'inflate failed' };

	let hx = hexenc(h[2]), mac = [];

	for (let i = 0; i < 12; i += 2)
		push(mac, substr(hx, i, 2));

	return { flags, mac: join(':', mac), data };
};
