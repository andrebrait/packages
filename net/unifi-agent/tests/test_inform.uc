// Inform codec against vectors made with Go's crypto/aes and compress/zlib.
import * as t from 'assert';
import * as inform from 'unifi.inform';

const K = inform.DEFAULT_KEY;
const GCM = hexdec('544e425500000000002722e00054000b000102030405060708090a0b0c0d0e0f000000010000003ad18bea908c4e735e682b32f90133e16f022d08b47bdf808d116f9c1e851bc74726b2eaee0ec9ebe4ea6180574bf86ab168790d42715eeb45468e');
const CBC = hexdec('544e425500000000002722e000540003000102030405060708090a0b0c0d0e0f00000001000000307bfff740830d45e7efe5da3bf8209483a3b931d8aed9270838594f63bef277572e1e47aa8cb6910fe4021c933d0f6bce');
const MSG = '{"_type":"noop","interval":10}';

for (let v in [ [ 'gcm', GCM, 0x0b ], [ 'cbc', CBC, 0x03 ] ]) {
	let r = inform.decode(v[1], K);
	t.eq(r.data, MSG, `${v[0]} decode`);
	t.eq(r.flags, v[2], `${v[0]} flags`);
	t.eq(r.mac, '00:27:22:e0:00:54', `${v[0]} mac`);
}

// Round trip, and the same IV must give a packet the vector decoder accepts.
let iv = hexdec('000102030405060708090a0b0c0d0e0f');
for (let gcm in [ true, false ]) {
	let p = inform.encode('00:27:22:e0:00:54', K, gcm, MSG, iv);
	t.eq(inform.decode(p, K).data, MSG, `round trip gcm=${gcm}`);
	t.eq(inform.decode(p, 'ffffffffffffffffffffffffffffffff').error, 'decrypt failed', `wrong key gcm=${gcm}`);
}

// A flipped byte in the header (the GCM AAD) must fail authentication.
let bad = substr(GCM, 0, 8) + chr(1) + substr(GCM, 9);
t.eq(inform.decode(bad, K).error, 'decrypt failed', 'gcm aad tamper');
t.eq(inform.decode('xx', K).error, 'short packet', 'short');
t.eq(inform.encode('00:27:22:e0:00:54', 'abc', true, MSG), null, 'bad key');

t.done();
