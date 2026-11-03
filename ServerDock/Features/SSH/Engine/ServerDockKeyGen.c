// In-process SSH key generation/import via OpenSSL EVP and handwritten OpenSSH private formats, replacing spawned ssh-keygen.
// ed25519 uses OpenSSH format, required by libssh2's fromfile path; RSA uses OpenSSL PKCS#8 PEM.
// Construct public lines/fingerprints from key material. Encrypted ed25519 uses bcrypt; see ServerDockKeyGen_bcrypt.c.
#include "ServerDockSSHCore.h"

#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/sha.h>
#include <openssl/rand.h>
#include <openssl/bn.h>
#include <openssl/core_names.h>

// Forward declarations.
static int kb64_decode_seg(const char *src, size_t srclen, unsigned char *out, size_t out_cap);
static int parse_openssh_pub(const unsigned char *p, size_t len, char *out_pub, int pub_cap,
                             int *out_type, int *out_encrypted);

// Standard base64 with '=' padding.
static const char KB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static char *kb64_encode(const unsigned char *src, size_t len) {  // Caller must free.
    size_t out = ((len + 2) / 3) * 4;
    char *dst = malloc(out + 1);
    if (!dst) return NULL;
    size_t i = 0, o = 0;
    while (i + 3 <= len) {
        unsigned v = (src[i] << 16) | (src[i+1] << 8) | src[i+2];
        dst[o++] = KB64[(v>>18)&63]; dst[o++] = KB64[(v>>12)&63];
        dst[o++] = KB64[(v>>6)&63];  dst[o++] = KB64[v&63];
        i += 3;
    }
    size_t rem = len - i;
    if (rem == 1) {
        unsigned v = src[i] << 16;
        dst[o++] = KB64[(v>>18)&63]; dst[o++] = KB64[(v>>12)&63];
        dst[o++] = '='; dst[o++] = '=';
    } else if (rem == 2) {
        unsigned v = (src[i] << 16) | (src[i+1] << 8);
        dst[o++] = KB64[(v>>18)&63]; dst[o++] = KB64[(v>>12)&63];
        dst[o++] = KB64[(v>>6)&63];  dst[o++] = '=';
    }
    dst[o] = '\0';
    return dst;
}
// Big-endian SSH wire buffer.
typedef struct { unsigned char *d; size_t len, cap; } wbuf;
static int wb_need(wbuf *b, size_t n) {
    if (b->len + n <= b->cap) return 0;
    size_t nc = b->cap ? b->cap : 256;
    while (nc < b->len + n) nc *= 2;
    unsigned char *nd = realloc(b->d, nc);
    if (!nd) return -1;
    b->d = nd; b->cap = nc; return 0;
}
static void wb_free(wbuf *b) { free(b->d); b->d = NULL; b->len = b->cap = 0; }
static int wb_u32(wbuf *b, unsigned v) {
    if (wb_need(b, 4)) return -1;
    b->d[b->len++] = (v>>24)&0xFF; b->d[b->len++] = (v>>16)&0xFF;
    b->d[b->len++] = (v>>8)&0xFF;  b->d[b->len++] = v&0xFF; return 0;
}
static int wb_bytes(wbuf *b, const unsigned char *p, size_t n) {
    if (wb_need(b, n)) return -1; memcpy(b->d + b->len, p, n); b->len += n; return 0;
}
static int wb_str(wbuf *b, const unsigned char *p, size_t n) {  // u32 length followed by data.
    if (wb_u32(b, (unsigned)n)) return -1; return wb_bytes(b, p, n);
}
static int wb_cstr(wbuf *b, const char *s) { return wb_str(b, (const unsigned char *)s, strlen(s)); }
// mpint is a positive big-endian integer; prepend 0x00 if the high bit is set.
static int wb_mpint(wbuf *b, const BIGNUM *bn) {
    int n = BN_num_bytes(bn);
    unsigned char *tmp = malloc(n ? n : 1);
    if (!tmp) return -1;
    BN_bn2bin(bn, tmp);
    int pad = (n > 0 && (tmp[0] & 0x80)) ? 1 : 0;
    if (wb_u32(b, (unsigned)(n + pad))) { free(tmp); return -1; }
    if (pad) { unsigned char z = 0; if (wb_bytes(b, &z, 1)) { free(tmp); return -1; } }
    int rc = wb_bytes(b, tmp, n);
    free(tmp);
    return rc;
}

// Public-key blob / line / fingerprint.
// Construct an SSH public wire blob; set *out and *out_len on success. Caller must free.
static int pub_blob(EVP_PKEY *pk, int is_ed, unsigned char **out, size_t *out_len) {
    wbuf b = {0};
    if (is_ed) {
        unsigned char pub[32]; size_t pl = sizeof(pub);
        if (EVP_PKEY_get_raw_public_key(pk, pub, &pl) != 1 || pl != 32) { wb_free(&b); return -1; }
        if (wb_cstr(&b, "ssh-ed25519") || wb_str(&b, pub, 32)) { wb_free(&b); return -1; }
    } else {
        BIGNUM *n = NULL, *e = NULL;
        if (EVP_PKEY_get_bn_param(pk, OSSL_PKEY_PARAM_RSA_N, &n) != 1 ||
            EVP_PKEY_get_bn_param(pk, OSSL_PKEY_PARAM_RSA_E, &e) != 1) {
            BN_free(n); BN_free(e); wb_free(&b); return -1;
        }
        int rc = wb_cstr(&b, "ssh-rsa") || wb_mpint(&b, e) || wb_mpint(&b, n);
        BN_free(n); BN_free(e);
        if (rc) { wb_free(&b); return -1; }
    }
    *out = b.d; *out_len = b.len;   // Transfer ownership.
    return 0;
}
// Write SHA256:base64 without trailing '=' into out.
static void fp_from_blob(const unsigned char *blob, size_t len, char *out, int cap) {
    unsigned char h[32]; SHA256(blob, len, h);
    char *b64 = kb64_encode(h, 32);
    if (!b64) { if (cap) out[0] = '\0'; return; }
    size_t n = strlen(b64); while (n > 0 && b64[n-1] == '=') b64[--n] = '\0';
    snprintf(out, (size_t)cap, "SHA256:%s", b64);
    free(b64);
}
// Write "ssh-xxx base64blob[ comment]" into out.
static void publine_from_blob(const unsigned char *blob, size_t len, const char *type,
                              const char *comment, char *out, int cap) {
    char *b64 = kb64_encode(blob, len);
    if (!b64) { if (cap) out[0] = '\0'; return; }
    if (comment && *comment) snprintf(out, (size_t)cap, "%s %s %s", type, b64, comment);
    else snprintf(out, (size_t)cap, "%s %s", type, b64);
    free(b64);
}

// OpenSSH private container: base64 with PEM wrapping.
// Base64-encode the openssh-key-v1 binary, wrap at 70 columns, and add BEGIN/END markers. Caller frees out.
static char *openssh_pem_wrap(const unsigned char *bin, size_t len) {
    char *b64 = kb64_encode(bin, len);
    if (!b64) return NULL;
    size_t bl = strlen(b64);
    size_t lines = (bl + 69) / 70;
    size_t cap = 64 + bl + lines + 64;
    char *out = malloc(cap);
    if (!out) { free(b64); return NULL; }
    size_t o = 0;
    o += (size_t)snprintf(out + o, cap - o, "-----BEGIN OPENSSH PRIVATE KEY-----\n");
    for (size_t i = 0; i < bl; i += 70) {
        size_t n = bl - i < 70 ? bl - i : 70;
        memcpy(out + o, b64 + i, n); o += n; out[o++] = '\n';
    }
    o += (size_t)snprintf(out + o, cap - o, "-----END OPENSSH PRIVATE KEY-----\n");
    out[o] = '\0';
    free(b64);
    return out;
}

// bcrypt module derives 48-byte key||iv from passphrase/salt over rounds iterations; return 0 on success.
int serverdock_bcrypt_pbkdf(const char *pass, size_t passlen, const unsigned char *salt, size_t saltlen,
                       unsigned char *out, size_t outlen, unsigned int rounds);

// Build an ed25519 OpenSSH private key, encrypting with aes256-ctr/bcrypt for a nonempty passphrase. Caller frees out.
static char *build_openssh_ed25519(const unsigned char *pubblob, size_t publen,
                                   const unsigned char *seed32, const unsigned char *pub32,
                                   const char *comment, const char *passphrase, char *err, int errlen) {
    int encrypt = (passphrase && *passphrase) ? 1 : 0;
    unsigned char salt[16]; unsigned int rounds = 16;
    unsigned char keyiv[48];   // 32 key + 16 iv
    if (encrypt) {
        if (RAND_bytes(salt, sizeof(salt)) != 1) { snprintf(err, errlen, "Random number generation failed"); return NULL; }
        if (serverdock_bcrypt_pbkdf(passphrase, strlen(passphrase), salt, sizeof(salt),
                               keyiv, sizeof(keyiv), rounds) != 0) {
            snprintf(err, errlen, "bcrypt key derivation failed"); return NULL;
        }
    }
    int block = encrypt ? 16 : 8;

    // Private section before encryption.
    wbuf priv = {0};
    unsigned int checkint;
    if (RAND_bytes((unsigned char *)&checkint, 4) != 1) { snprintf(err, errlen, "Random number generation failed"); wb_free(&priv); return NULL; }
    unsigned char priv64[64]; memcpy(priv64, seed32, 32); memcpy(priv64 + 32, pub32, 32);
    if (wb_u32(&priv, checkint) || wb_u32(&priv, checkint) ||
        wb_cstr(&priv, "ssh-ed25519") || wb_str(&priv, pub32, 32) || wb_str(&priv, priv64, 64) ||
        wb_cstr(&priv, comment ? comment : "")) { wb_free(&priv); snprintf(err, errlen, "Failed to assemble key"); return NULL; }
    // Pad with 1,2,3,... to the block boundary.
    unsigned char padv = 1;
    while (priv.len % (size_t)block != 0) { if (wb_bytes(&priv, &padv, 1)) { wb_free(&priv); return NULL; } padv++; }

    if (encrypt) {   // Encrypt the private section with AES-256-CTR.
        EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
        int ol = 0;
        if (!c || EVP_EncryptInit_ex(c, EVP_aes_256_ctr(), NULL, keyiv, keyiv + 32) != 1 ||
            EVP_EncryptUpdate(c, priv.d, &ol, priv.d, (int)priv.len) != 1) {
            if (c) EVP_CIPHER_CTX_free(c); wb_free(&priv); snprintf(err, errlen, "Encryption failed"); return NULL;
        }
        EVP_CIPHER_CTX_free(c);
    }

    // Top-level container.
    wbuf top = {0};
    static const char magic[] = "openssh-key-v1";   // 15 bytes including trailing NUL.
    if (wb_bytes(&top, (const unsigned char *)magic, sizeof(magic)) ||
        wb_cstr(&top, encrypt ? "aes256-ctr" : "none") ||
        wb_cstr(&top, encrypt ? "bcrypt" : "none")) { wb_free(&top); wb_free(&priv); return NULL; }
    if (encrypt) {
        wbuf kdf = {0};
        if (wb_str(&kdf, salt, sizeof(salt)) || wb_u32(&kdf, rounds) ||
            wb_str(&top, kdf.d, kdf.len)) { wb_free(&kdf); wb_free(&top); wb_free(&priv); return NULL; }
        wb_free(&kdf);
    } else {
        if (wb_cstr(&top, "")) { wb_free(&top); wb_free(&priv); return NULL; }
    }
    if (wb_u32(&top, 1) || wb_str(&top, pubblob, publen) || wb_str(&top, priv.d, priv.len)) {
        wb_free(&top); wb_free(&priv); return NULL;
    }
    wb_free(&priv);
    char *pem = openssh_pem_wrap(top.d, top.len);
    wb_free(&top);
    if (!pem) snprintf(err, errlen, "Failed to encode key");
    return pem;
}

// Public generation API.
int serverdock_key_generate(int type, const char *comment, const char *passphrase,
                       char *out_priv, int priv_cap,
                       char *out_pub, int pub_cap,
                       char *out_fp, int fp_cap,
                       char *err, int errlen) {
    int is_ed = (type == 0);
    EVP_PKEY *pk = is_ed ? EVP_PKEY_Q_keygen(NULL, NULL, "ED25519")
                         : EVP_PKEY_Q_keygen(NULL, NULL, "RSA", (size_t)4096);
    if (!pk) { snprintf(err, (size_t)errlen, "Key generation failed"); return -1; }

    unsigned char *blob = NULL; size_t bloblen = 0;
    if (pub_blob(pk, is_ed, &blob, &bloblen) != 0) { snprintf(err, (size_t)errlen, "Failed to export public key"); EVP_PKEY_free(pk); return -1; }
    publine_from_blob(blob, bloblen, is_ed ? "ssh-ed25519" : "ssh-rsa", comment, out_pub, pub_cap);
    fp_from_blob(blob, bloblen, out_fp, fp_cap);

    int rc = 0;
    if (is_ed) {
        unsigned char seed[32], pub[32]; size_t sl = sizeof(seed), pl = sizeof(pub);
        if (EVP_PKEY_get_raw_private_key(pk, seed, &sl) != 1 || sl != 32 ||
            EVP_PKEY_get_raw_public_key(pk, pub, &pl) != 1 || pl != 32) {
            snprintf(err, (size_t)errlen, "Failed to export private key"); rc = -1;
        } else {
            char *pem = build_openssh_ed25519(blob, bloblen, seed, pub, comment ? comment : "", passphrase, err, errlen);
            if (!pem) rc = -1;
            else { snprintf(out_priv, (size_t)priv_cap, "%s", pem); free(pem); }
        }
    } else {
        BIO *bio = BIO_new(BIO_s_mem());
        const EVP_CIPHER *cipher = (passphrase && *passphrase) ? EVP_aes_256_cbc() : NULL;
        int ok = bio && PEM_write_bio_PKCS8PrivateKey(bio, pk, cipher,
                        NULL, 0, NULL, (void *)(passphrase ? passphrase : ""));
        if (!ok) { snprintf(err, (size_t)errlen, "Failed to export private key"); rc = -1; }
        else {
            char *data = NULL; long n = BIO_get_mem_data(bio, &data);
            if (n <= 0 || n >= priv_cap) { snprintf(err, (size_t)errlen, "Private key buffer too small"); rc = -1; }
            else { memcpy(out_priv, data, (size_t)n); out_priv[n] = '\0'; }
        }
        if (bio) BIO_free(bio);
    }
    free(blob);
    EVP_PKEY_free(pk);
    return rc;
}

// Public import API: derive a public key from a private key.
// Return 0 with uncommented out_pub, *out_type 0/1, and *out_encrypted 0/1; 1 if encryption prevents derivation; -1 on error.
// OpenSSH containers store public material in plaintext, so encrypted keys can return rc=0 and *out_encrypted=1.
int serverdock_key_pubkey_from_private(const char *priv_path, const char *passphrase,
                                  char *out_pub, int pub_cap, int *out_type, int *out_encrypted) {
    if (out_encrypted) *out_encrypted = 0;
    FILE *fp = fopen(priv_path, "rb");
    if (!fp) return -1;
    // Read the entire file to detect OpenSSH format.
    fseek(fp, 0, SEEK_END); long fsz = ftell(fp); fseek(fp, 0, SEEK_SET);
    if (fsz <= 0 || fsz > 1024 * 1024) { fclose(fp); return -1; }
    char *txt = malloc((size_t)fsz + 1);
    if (!txt) { fclose(fp); return -1; }
    size_t rd = fread(txt, 1, (size_t)fsz, fp); txt[rd] = '\0';

    int result = -1;
    if (strstr(txt, "BEGIN OPENSSH PRIVATE KEY")) {
        // The container's public key is plaintext and requires no decryption.
        const char *b = strstr(txt, "-----BEGIN OPENSSH PRIVATE KEY-----");
        const char *e = strstr(txt, "-----END OPENSSH PRIVATE KEY-----");
        if (b && e) {
            b += strlen("-----BEGIN OPENSSH PRIVATE KEY-----");
            size_t blen = (size_t)(e - b);
            unsigned char *bin = malloc(blen);
            if (bin) {
                int n = kb64_decode_seg(b, blen, bin, blen);
                if (n > 0) {
                    // Parse the publickey blob even when the private container is encrypted.
                    result = parse_openssh_pub(bin, (size_t)n, out_pub, pub_cap, out_type, out_encrypted);
                }
                free(bin);
            }
        }
    } else {
        // For RSA/EC PEM, use OpenSSL to read private material and derive the public key.
        BIO *bio = BIO_new_mem_buf(txt, (int)rd);
        EVP_PKEY *pk = bio ? PEM_read_bio_PrivateKey(bio, NULL, NULL,
                              (void *)(passphrase ? passphrase : "")) : NULL;
        if (bio) BIO_free(bio);
        if (pk) {
            int is_ed = EVP_PKEY_id(pk) == EVP_PKEY_ED25519;
            unsigned char *blob = NULL; size_t bloblen = 0;
            if (pub_blob(pk, is_ed, &blob, &bloblen) == 0) {
                publine_from_blob(blob, bloblen, is_ed ? "ssh-ed25519" : "ssh-rsa", NULL, out_pub, pub_cap);
                if (out_type) *out_type = is_ed ? 0 : 1;
                free(blob);
                result = 0;
            }
            EVP_PKEY_free(pk);
        } else {
            // Read failure usually means encrypted content with missing/incorrect passphrase; report encrypted.
            if (strstr(txt, "ENCRYPTED")) result = 1;
        }
    }
    free(txt);
    fclose(fp);
    return result;
}

// Parse the first public blob from openssh-key-v1 into its public line/type/encryption flag; return 0/-1.
static int parse_openssh_pub(const unsigned char *p, size_t len, char *out_pub, int pub_cap,
                             int *out_type, int *out_encrypted) {
    size_t o = 0;
    #define RD_U32(v) do { if (o + 4 > len) return -1; (v) = ((unsigned)p[o]<<24)|((unsigned)p[o+1]<<16)|((unsigned)p[o+2]<<8)|p[o+3]; o += 4; } while(0)
    #define SKIP_STR() do { unsigned _l; RD_U32(_l); if (o + _l > len) return -1; o += _l; } while(0)
    static const char magic[] = "openssh-key-v1";
    if (len < sizeof(magic) || memcmp(p, magic, sizeof(magic)) != 0) return -1;
    o = sizeof(magic);             // Skip magic and trailing NUL.
    unsigned cl; RD_U32(cl);       // ciphername
    if (o + cl > len) return -1;
    if (out_encrypted) *out_encrypted = !(cl == 4 && memcmp(p + o, "none", 4) == 0);
    o += cl;
    SKIP_STR();                    // kdfname
    SKIP_STR();                    // kdfoptions
    unsigned nkeys; RD_U32(nkeys);
    if (nkeys < 1) return -1;
    unsigned bloblen; RD_U32(bloblen);
    if (o + bloblen > len) return -1;
    const unsigned char *blob = p + o;
    // The blob's first field is the type name.
    if (bloblen < 4) return -1;
    unsigned tl = ((unsigned)blob[0]<<24)|((unsigned)blob[1]<<16)|((unsigned)blob[2]<<8)|blob[3];
    const char *type = "ssh-ed25519"; int t = 0;
    if (tl == 7 && bloblen >= 11 && memcmp(blob+4, "ssh-rsa", 7) == 0) { type = "ssh-rsa"; t = 1; }
    publine_from_blob(blob, bloblen, type, NULL, out_pub, pub_cap);
    if (out_type) *out_type = t;
    return 0;
    #undef RD_U32
    #undef SKIP_STR
}

// Decode length-delimited base64, not NUL-terminated.
static int kb64_decode_seg(const char *src, size_t srclen, unsigned char *out, size_t out_cap) {
    int tbl[256]; for (int i = 0; i < 256; i++) tbl[i] = -1;
    for (int i = 0; i < 64; i++) tbl[(unsigned char)KB64[i]] = i;
    unsigned acc = 0; int bits = 0; size_t o = 0;
    for (size_t i = 0; i < srclen; i++) {
        char ch = src[i];
        if (ch == '=' || ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t') continue;
        int v = tbl[(unsigned char)ch];
        if (v < 0) continue;
        acc = (acc << 6) | (unsigned)v; bits += 6;
        if (bits >= 8) { bits -= 8; if (o >= out_cap) return -1; out[o++] = (unsigned char)((acc >> bits) & 0xFF); }
    }
    return (int)o;
}

// Public API: change an existing private-key passphrase.
// Read SSH wire primitives without copying; *out points inside p. Return -1 on bounds violations.
static int rd_u32_at(const unsigned char *p, size_t len, size_t *off, unsigned *v) {
    if (*off + 4 > len) return -1;
    *v = ((unsigned)p[*off]<<24)|((unsigned)p[*off+1]<<16)|((unsigned)p[*off+2]<<8)|p[*off+3];
    *off += 4; return 0;
}
static int rd_str_at(const unsigned char *p, size_t len, size_t *off, const unsigned char **out, size_t *outlen) {
    unsigned l;
    if (rd_u32_at(p, len, off, &l)) return -1;
    if (*off + l > len) return -1;
    *out = p + *off; *outlen = l; *off += l;
    return 0;
}

// Decrypt openssh-key-v1 private data into priv_copy and compare checkints to validate the password.
// On success *seed32/*pub32 point to 32-byte regions inside priv_copy and are freed with it;
// *comment_out is separately allocated and NUL-terminated; the caller must free it independently.
static int decrypt_openssh_ed25519(unsigned char *bin, size_t bin_len,
                                    const char *old_passphrase,
                                    const unsigned char **pubblob, size_t *pubblob_len,
                                    unsigned char **priv_copy_out,
                                    const unsigned char **seed32, const unsigned char **pub32,
                                    const char **comment_out,
                                    char *err, int errlen) {
    size_t o = 0;
    static const char magic[] = "openssh-key-v1";
    if (bin_len < sizeof(magic) || memcmp(bin, magic, sizeof(magic)) != 0) {
        snprintf(err, errlen, "Not an OpenSSH private key container"); return -1;
    }
    o = sizeof(magic);
    const unsigned char *cipher, *kdfname, *kdfopts, *pblob, *psec;
    size_t cipherlen, kdfnamelen, kdfoptslen, pbloblen, pseclen;
    unsigned nkeys;
    if (rd_str_at(bin, bin_len, &o, &cipher, &cipherlen) ||
        rd_str_at(bin, bin_len, &o, &kdfname, &kdfnamelen) ||
        rd_str_at(bin, bin_len, &o, &kdfopts, &kdfoptslen) ||
        rd_u32_at(bin, bin_len, &o, &nkeys) || nkeys < 1 ||
        rd_str_at(bin, bin_len, &o, &pblob, &pbloblen) ||
        rd_str_at(bin, bin_len, &o, &psec, &pseclen)) {
        snprintf(err, errlen, "Malformed OpenSSH private key"); return -1;
    }

    unsigned char *priv_copy = malloc(pseclen ? pseclen : 1);
    if (!priv_copy) { snprintf(err, errlen, "Out of memory"); return -1; }
    memcpy(priv_copy, psec, pseclen);

    int encrypted = !(cipherlen == 4 && memcmp(cipher, "none", 4) == 0);
    if (encrypted) {
        if (!(cipherlen == 10 && memcmp(cipher, "aes256-ctr", 10) == 0) ||
            !(kdfnamelen == 6 && memcmp(kdfname, "bcrypt", 6) == 0)) {
            free(priv_copy);
            snprintf(err, errlen, "Unsupported private key cipher"); return -1;
        }
        size_t ko = 0;
        const unsigned char *salt; size_t saltlen; unsigned rounds;
        if (rd_str_at(kdfopts, kdfoptslen, &ko, &salt, &saltlen) ||
            rd_u32_at(kdfopts, kdfoptslen, &ko, &rounds)) {
            free(priv_copy);
            snprintf(err, errlen, "Malformed key derivation options"); return -1;
        }
        unsigned char keyiv[48];
        if (serverdock_bcrypt_pbkdf(old_passphrase ? old_passphrase : "",
                               strlen(old_passphrase ? old_passphrase : ""),
                               salt, saltlen, keyiv, sizeof(keyiv), rounds) != 0) {
            free(priv_copy);
            snprintf(err, errlen, "Passphrase key derivation failed"); return -1;
        }
        EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
        int ol = 0;
        int ok = c && EVP_DecryptInit_ex(c, EVP_aes_256_ctr(), NULL, keyiv, keyiv + 32) == 1 &&
                  EVP_DecryptUpdate(c, priv_copy, &ol, priv_copy, (int)pseclen) == 1;
        if (c) EVP_CIPHER_CTX_free(c);
        if (!ok) {
            free(priv_copy);
            snprintf(err, errlen, "Decryption failed"); return -1;
        }
    }

    size_t po = 0;
    unsigned check1, check2;
    if (rd_u32_at(priv_copy, pseclen, &po, &check1) ||
        rd_u32_at(priv_copy, pseclen, &po, &check2) || check1 != check2) {
        free(priv_copy);
        snprintf(err, errlen, "Incorrect passphrase"); return -1;
    }
    const unsigned char *keytype, *pub32seg, *priv64;
    size_t keytypelen, pub32len, priv64len;
    if (rd_str_at(priv_copy, pseclen, &po, &keytype, &keytypelen) ||
        !(keytypelen == 11 && memcmp(keytype, "ssh-ed25519", 11) == 0) ||
        rd_str_at(priv_copy, pseclen, &po, &pub32seg, &pub32len) || pub32len != 32 ||
        rd_str_at(priv_copy, pseclen, &po, &priv64, &priv64len) || priv64len != 64) {
        free(priv_copy);
        snprintf(err, errlen, "Unsupported or malformed key contents"); return -1;
    }
    const unsigned char *commentseg; size_t commentlen;
    if (rd_str_at(priv_copy, pseclen, &po, &commentseg, &commentlen)) {
        free(priv_copy);
        snprintf(err, errlen, "Malformed key contents"); return -1;
    }
    // The original comment inside priv_copy lacks a NUL; allocate a separate terminated copy rather than overwriting beyond bounds.
    char *comment_copy = malloc(commentlen + 1);
    if (!comment_copy) {
        free(priv_copy);
        snprintf(err, errlen, "Out of memory"); return -1;
    }
    memcpy(comment_copy, commentseg, commentlen);
    comment_copy[commentlen] = 0;

    *pubblob = pblob; *pubblob_len = pbloblen;
    *priv_copy_out = priv_copy;
    *seed32 = priv64;           // priv64 = seed32(32) || pub32(32)
    *pub32 = priv64 + 32;
    *comment_out = comment_copy;   // Caller must free.
    return 0;
}

int serverdock_key_change_passphrase(const char *priv_path,
                                const char *old_passphrase, const char *new_passphrase,
                                char *out_priv, int priv_cap, char *err, int errlen) {
    FILE *fp = fopen(priv_path, "rb");
    if (!fp) { snprintf(err, errlen, "Unable to open private key file"); return -1; }
    fseek(fp, 0, SEEK_END); long fsz = ftell(fp); fseek(fp, 0, SEEK_SET);
    if (fsz <= 0 || fsz > 1024 * 1024) { fclose(fp); snprintf(err, errlen, "Private key file is invalid"); return -1; }
    char *txt = malloc((size_t)fsz + 1);
    if (!txt) { fclose(fp); snprintf(err, errlen, "Out of memory"); return -1; }
    size_t rd = fread(txt, 1, (size_t)fsz, fp);
    txt[rd] = '\0';
    fclose(fp);

    int rc = -1;
    if (strstr(txt, "BEGIN OPENSSH PRIVATE KEY")) {
        const char *b = strstr(txt, "-----BEGIN OPENSSH PRIVATE KEY-----");
        const char *e = strstr(txt, "-----END OPENSSH PRIVATE KEY-----");
        if (b && e && e > b) {
            b += strlen("-----BEGIN OPENSSH PRIVATE KEY-----");
            size_t blen = (size_t)(e - b);
            unsigned char *bin = malloc(blen ? blen : 1);
            if (bin) {
                int n = kb64_decode_seg(b, blen, bin, blen);
                if (n > 0) {
                    const unsigned char *pubblob, *seed32, *pub32; size_t pubbloblen;
                    unsigned char *priv_copy = NULL;
                    const char *comment = NULL;
                    if (decrypt_openssh_ed25519(bin, (size_t)n, old_passphrase,
                                                &pubblob, &pubbloblen, &priv_copy,
                                                &seed32, &pub32, &comment, err, errlen) == 0) {
                        char *pem = build_openssh_ed25519(pubblob, pubbloblen, seed32, pub32,
                                                          comment, new_passphrase, err, errlen);
                        if (pem) {
                            snprintf(out_priv, (size_t)priv_cap, "%s", pem);
                            free(pem);
                            rc = 0;
                        }
                        free(priv_copy);
                        free((void *)comment);
                    }
                } else {
                    snprintf(err, errlen, "Malformed OpenSSH private key");
                }
                free(bin);
            } else {
                snprintf(err, errlen, "Out of memory");
            }
        } else {
            snprintf(err, errlen, "Malformed OpenSSH private key");
        }
    } else {
        BIO *bio = BIO_new_mem_buf(txt, (int)rd);
        EVP_PKEY *pk = bio ? PEM_read_bio_PrivateKey(bio, NULL, NULL,
                              (void *)(old_passphrase ? old_passphrase : "")) : NULL;
        if (bio) BIO_free(bio);
        if (!pk) {
            snprintf(err, errlen, "Incorrect passphrase or unsupported key");
        } else {
            BIO *outbio = BIO_new(BIO_s_mem());
            const EVP_CIPHER *outcipher = (new_passphrase && *new_passphrase) ? EVP_aes_256_cbc() : NULL;
            int ok = outbio && PEM_write_bio_PKCS8PrivateKey(outbio, pk, outcipher,
                            NULL, 0, NULL, (void *)(new_passphrase ? new_passphrase : ""));
            if (!ok) {
                snprintf(err, errlen, "Failed to write private key");
            } else {
                char *data = NULL; long n = BIO_get_mem_data(outbio, &data);
                if (n <= 0 || n >= priv_cap) {
                    snprintf(err, errlen, "Private key buffer too small");
                } else {
                    memcpy(out_priv, data, (size_t)n); out_priv[n] = '\0';
                    rc = 0;
                }
            }
            if (outbio) BIO_free(outbio);
            EVP_PKEY_free(pk);
        }
    }
    free(txt);
    return rc;
}

// Compute SHA256 fingerprint from a public-key line; return 0/-1.
int serverdock_key_fingerprint(const char *pub_line, char *out_fp, int fp_cap) {
    // Take the second field, the base64 blob.
    const char *s = pub_line;
    while (*s == ' ') s++;
    const char *sp = strchr(s, ' ');
    if (!sp) return -1;
    const char *b = sp + 1;
    const char *be = strchr(b, ' ');
    size_t blen = be ? (size_t)(be - b) : strlen(b);
    unsigned char *bin = malloc(blen);
    if (!bin) return -1;
    int n = kb64_decode_seg(b, blen, bin, blen);
    if (n <= 0) { free(bin); return -1; }
    fp_from_blob(bin, (size_t)n, out_fp, fp_cap);
    free(bin);
    return 0;
}
