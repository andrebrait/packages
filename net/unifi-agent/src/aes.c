// SPDX-License-Identifier: GPL-2.0-only
/*
 * ucode module "unifi.aes": the AES-128 modes the UniFi inform protocol
 * uses, on top of mbedTLS. Everything else in the agent is plain ucode.
 *
 *   cbc_encrypt(key, iv, data)      -> ciphertext (PKCS#7 padded)
 *   cbc_decrypt(key, iv, data)      -> plaintext, or null
 *   gcm_encrypt(key, iv, aad, data) -> ciphertext || 16-byte tag
 *   gcm_decrypt(key, iv, aad, data) -> plaintext, or null
 *
 * Keys are 16 raw bytes, IVs 16 raw bytes (the inform header's IV is also
 * the GCM nonce, so GCM runs with a 16-byte nonce).
 */

#include <stdlib.h>
#include <string.h>

#include <mbedtls/aes.h>
#include <mbedtls/gcm.h>

#include <ucode/module.h>

#define BLK 16
#define TAG 16

static int
get_bytes(uc_vm_t *vm, size_t nargs, size_t i, const char **p, size_t *len)
{
	uc_value_t *v = uc_fn_arg(i);

	if (ucv_type(v) != UC_STRING)
		return -1;

	*p = ucv_string_get(v);
	*len = ucv_string_length(v);

	return 0;
}

static int
get_key_iv(uc_vm_t *vm, size_t nargs, const char **key, const char **iv)
{
	size_t klen, ivlen;

	if (get_bytes(vm, nargs, 0, key, &klen) || klen != 16 ||
	    get_bytes(vm, nargs, 1, iv, &ivlen) || ivlen != BLK)
		return -1;

	return 0;
}

static uc_value_t *
uc_cbc(uc_vm_t *vm, size_t nargs, int encrypt)
{
	const char *key, *iv, *in;
	unsigned char ivbuf[BLK], *buf;
	mbedtls_aes_context ctx;
	uc_value_t *rv = NULL;
	size_t len, outlen;
	int err;

	if (get_key_iv(vm, nargs, &key, &iv) ||
	    get_bytes(vm, nargs, 2, &in, &len))
		return NULL;

	if (encrypt)
		outlen = (len / BLK + 1) * BLK;
	else if (len == 0 || len % BLK)
		return NULL;
	else
		outlen = len;

	buf = malloc(outlen);
	if (!buf)
		return NULL;

	memcpy(buf, in, len);
	if (encrypt)
		memset(buf + len, outlen - len, outlen - len);

	memcpy(ivbuf, iv, BLK);
	mbedtls_aes_init(&ctx);

	if (encrypt)
		err = mbedtls_aes_setkey_enc(&ctx, (const unsigned char *)key, 128);
	else
		err = mbedtls_aes_setkey_dec(&ctx, (const unsigned char *)key, 128);

	if (!err)
		err = mbedtls_aes_crypt_cbc(&ctx,
			encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT,
			outlen, ivbuf, buf, buf);

	mbedtls_aes_free(&ctx);

	if (!err && !encrypt) {
		size_t pad = buf[outlen - 1], i;

		if (pad == 0 || pad > BLK)
			err = -1;

		for (i = 1; !err && i <= pad; i++)
			if (buf[outlen - i] != pad)
				err = -1;

		if (!err)
			outlen -= pad;
	}

	if (!err)
		rv = ucv_string_new_length((const char *)buf, outlen);

	free(buf);

	return rv;
}

static uc_value_t *
uc_cbc_encrypt(uc_vm_t *vm, size_t nargs)
{
	return uc_cbc(vm, nargs, 1);
}

static uc_value_t *
uc_cbc_decrypt(uc_vm_t *vm, size_t nargs)
{
	return uc_cbc(vm, nargs, 0);
}

static uc_value_t *
uc_gcm(uc_vm_t *vm, size_t nargs, int encrypt)
{
	const char *key, *iv, *aad, *in;
	size_t aadlen, len, outlen;
	mbedtls_gcm_context ctx;
	unsigned char *buf;
	uc_value_t *rv = NULL;
	int err;

	if (get_key_iv(vm, nargs, &key, &iv) ||
	    get_bytes(vm, nargs, 2, &aad, &aadlen) ||
	    get_bytes(vm, nargs, 3, &in, &len))
		return NULL;

	if (!encrypt && len < TAG)
		return NULL;

	outlen = encrypt ? len + TAG : len - TAG;
	buf = malloc(outlen ? outlen : 1);
	if (!buf)
		return NULL;

	mbedtls_gcm_init(&ctx);
	err = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES,
				 (const unsigned char *)key, 128);

	if (!err && encrypt)
		err = mbedtls_gcm_crypt_and_tag(&ctx, MBEDTLS_GCM_ENCRYPT, len,
			(const unsigned char *)iv, BLK,
			(const unsigned char *)aad, aadlen,
			(const unsigned char *)in, buf,
			TAG, buf + len);
	else if (!err)
		err = mbedtls_gcm_auth_decrypt(&ctx, outlen,
			(const unsigned char *)iv, BLK,
			(const unsigned char *)aad, aadlen,
			(const unsigned char *)in + outlen, TAG,
			(const unsigned char *)in, buf);

	mbedtls_gcm_free(&ctx);

	if (!err)
		rv = ucv_string_new_length((const char *)buf, outlen);

	free(buf);

	return rv;
}

static uc_value_t *
uc_gcm_encrypt(uc_vm_t *vm, size_t nargs)
{
	return uc_gcm(vm, nargs, 1);
}

static uc_value_t *
uc_gcm_decrypt(uc_vm_t *vm, size_t nargs)
{
	return uc_gcm(vm, nargs, 0);
}

static const uc_function_list_t aes_fns[] = {
	{ "cbc_encrypt", uc_cbc_encrypt },
	{ "cbc_decrypt", uc_cbc_decrypt },
	{ "gcm_encrypt", uc_gcm_encrypt },
	{ "gcm_decrypt", uc_gcm_decrypt },
};

void uc_module_init(uc_vm_t *vm, uc_value_t *scope)
{
	uc_function_list_register(scope, aes_fns);
}
