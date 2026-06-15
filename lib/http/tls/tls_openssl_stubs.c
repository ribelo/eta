/* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT */

#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/x509v3.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/custom.h>
#include <caml/bigarray.h>

/* Cipher policy: TLS 1.2 ECDHE RSA/ECDSA AEAD only, no FFDHE. */
#define ETA_CIPHER_LIST \
  "ECDHE-RSA-AES128-GCM-SHA256:" \
  "ECDHE-RSA-AES256-GCM-SHA384:" \
  "ECDHE-RSA-CHACHA20-POLY1305:" \
  "ECDHE-ECDSA-AES128-GCM-SHA256:" \
  "ECDHE-ECDSA-AES256-GCM-SHA384:" \
  "ECDHE-ECDSA-CHACHA20-POLY1305"

#define ETA_TLS13_CIPHER_LIST \
  "TLS_AES_128_GCM_SHA256:" \
  "TLS_AES_256_GCM_SHA384:" \
  "TLS_CHACHA20_POLY1305_SHA256"

static const unsigned char ETA_SESSION_ID_CONTEXT[] = "eta-http";

/* ------------------------------------------------------------------ */
/* SSL_CTX — custom block; finalizer frees the context.                */

typedef struct {
  unsigned char *wire;
  unsigned int len;
} eta_alpn_config;

typedef struct {
  char *name;
  SSL_CTX *ctx;
} eta_sni_entry;

typedef struct {
  eta_sni_entry *entries;
  size_t count;
  int require_match;
} eta_sni_config;

typedef struct {
  SSL_CTX *ctx;
} eta_ssl_ctx_box;

static int eta_alpn_ex_index = -1;
static int eta_sni_ex_index = -1;

static void eta_alpn_ex_free(void *parent, void *ptr, CRYPTO_EX_DATA *ad,
                             int idx, long argl, void *argp)
{
  (void)parent;
  (void)ad;
  (void)idx;
  (void)argl;
  (void)argp;
  eta_alpn_config *alpn = (eta_alpn_config *)ptr;
  if (alpn != NULL) {
    free(alpn->wire);
    free(alpn);
  }
}

static void eta_sni_ex_free(void *parent, void *ptr, CRYPTO_EX_DATA *ad,
                            int idx, long argl, void *argp)
{
  (void)parent;
  (void)ad;
  (void)idx;
  (void)argl;
  (void)argp;
  eta_sni_config *sni = (eta_sni_config *)ptr;
  if (sni != NULL) {
    for (size_t i = 0; i < sni->count; i++) {
      free(sni->entries[i].name);
      if (sni->entries[i].ctx != NULL) {
        SSL_CTX_free(sni->entries[i].ctx);
      }
    }
    free(sni->entries);
    free(sni);
  }
}

static int eta_alpn_ex_index_get(void)
{
  if (eta_alpn_ex_index < 0) {
    eta_alpn_ex_index =
        SSL_CTX_get_ex_new_index(0, NULL, NULL, NULL, eta_alpn_ex_free);
  }
  return eta_alpn_ex_index;
}

static int eta_sni_ex_index_get(void)
{
  if (eta_sni_ex_index < 0) {
    eta_sni_ex_index =
        SSL_CTX_get_ex_new_index(0, NULL, NULL, NULL, eta_sni_ex_free);
  }
  return eta_sni_ex_index;
}

static int eta_ssl_ctx_cmp(value v1, value v2)
{
  eta_ssl_ctx_box *b1 = *((eta_ssl_ctx_box **)Data_custom_val(v1));
  eta_ssl_ctx_box *b2 = *((eta_ssl_ctx_box **)Data_custom_val(v2));
  return b1 != b2;
}

static intnat eta_ssl_ctx_hash(value v)
{
  eta_ssl_ctx_box *box = *((eta_ssl_ctx_box **)Data_custom_val(v));
  return (intnat)box;
}

static void eta_ssl_ctx_finalize(value v)
{
  eta_ssl_ctx_box *box = *((eta_ssl_ctx_box **)Data_custom_val(v));
  if (box != NULL) {
    if (box->ctx != NULL) {
      SSL_CTX_free(box->ctx);
    }
    free(box);
  }
}

static struct custom_operations eta_ssl_ctx_ops = {
  "eta.openssl.ctx",
  eta_ssl_ctx_finalize,
  eta_ssl_ctx_cmp,
  eta_ssl_ctx_hash,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static SSL_CTX *eta_ssl_ctx_val(value v)
{
  eta_ssl_ctx_box *box = *((eta_ssl_ctx_box **)Data_custom_val(v));
  return box->ctx;
}

static value eta_alloc_ssl_ctx(SSL_CTX *ctx)
{
  eta_ssl_ctx_box *box = malloc(sizeof(*box));
  if (box == NULL) {
    SSL_CTX_free(ctx);
    caml_failwith("malloc failed");
  }
  box->ctx = ctx;
  value v = caml_alloc_custom(&eta_ssl_ctx_ops, sizeof(void *), 0, 1);
  *((void **)Data_custom_val(v)) = box;
  return v;
}

CAMLprim value eta_openssl_random_bytes(value v_bytes, value v_off, value v_len)
{
  CAMLparam3(v_bytes, v_off, v_len);
  int off = Int_val(v_off);
  int len = Int_val(v_len);
  mlsize_t bytes_len = caml_string_length(v_bytes);
  if (off < 0 || len < 0 || (mlsize_t)off > bytes_len ||
      (mlsize_t)len > bytes_len - (mlsize_t)off) {
    caml_invalid_argument("OpenSSL RAND_bytes bounds");
  }
  if (RAND_bytes((unsigned char *)Bytes_val(v_bytes) + off, len) != 1) {
    caml_failwith("OpenSSL RAND_bytes failed");
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_openssl_sha1(value v_input)
{
  CAMLparam1(v_input);
  unsigned char digest[20];
  unsigned int digest_len = 0;
  const EVP_MD *sha1 = EVP_sha1();
  if (sha1 == NULL ||
      EVP_Digest(String_val(v_input), caml_string_length(v_input), digest,
                 &digest_len, sha1, NULL) != 1 ||
      digest_len != sizeof(digest)) {
    caml_failwith("OpenSSL EVP SHA1 failed");
  }
  CAMLreturn(caml_alloc_initialized_string(sizeof(digest), (const char *)digest));
}

/* ------------------------------------------------------------------ */
/* SSL — custom block holds SSL*.  The SSL object holds an internal
   reference to its SSL_CTX (via SSL_new -> SSL_CTX_up_ref), so
   SSL_free decrements the ctx refcount automatically.                */

static void eta_ssl_finalize(value v)
{
  void **data = (void **)Data_custom_val(v);
  SSL *ssl = (SSL *)data[0];
  if (ssl != NULL) {
    SSL_free(ssl);
  }
}

static int eta_ssl_cmp(value v1, value v2)
{
  return *((void **)Data_custom_val(v1)) != *((void **)Data_custom_val(v2));
}

static intnat eta_ssl_hash(value v)
{
  return (intnat)*((void **)Data_custom_val(v));
}

static struct custom_operations eta_ssl_ops = {
  "eta.openssl.ssl",
  eta_ssl_finalize,
  eta_ssl_cmp,
  eta_ssl_hash,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static value eta_alloc_ssl(SSL *ssl)
{
  value v = caml_alloc_custom(&eta_ssl_ops, sizeof(void *), 0, 1);
  void **data = (void **)Data_custom_val(v);
  data[0] = ssl;
  return v;
}

static SSL *eta_ssl_val(value v)
{
  return ((SSL **)Data_custom_val(v))[0];
}

/* SSL_SESSION — custom block owns one SSL_SESSION reference. */

static void eta_ssl_session_finalize(value v)
{
  SSL_SESSION *session = *((SSL_SESSION **)Data_custom_val(v));
  if (session != NULL) {
    SSL_SESSION_free(session);
  }
}

static int eta_ssl_session_cmp(value v1, value v2)
{
  return *((void **)Data_custom_val(v1)) != *((void **)Data_custom_val(v2));
}

static intnat eta_ssl_session_hash(value v)
{
  return (intnat)*((void **)Data_custom_val(v));
}

static struct custom_operations eta_ssl_session_ops = {
  "eta.openssl.session",
  eta_ssl_session_finalize,
  eta_ssl_session_cmp,
  eta_ssl_session_hash,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default,
  custom_fixed_length_default
};

static value eta_alloc_ssl_session(SSL_SESSION *session)
{
  value v = caml_alloc_custom(&eta_ssl_session_ops, sizeof(void *), 0, 1);
  *((void **)Data_custom_val(v)) = session;
  return v;
}

static SSL_SESSION *eta_ssl_session_val(value v)
{
  return ((SSL_SESSION **)Data_custom_val(v))[0];
}

/* Build ALPN protocol list in wire format.  Returns a freshly
   allocated buffer (or NULL on failure).  *out_len receives the
   total wire length. */
static unsigned char *eta_build_alpn(const char *const *protos, size_t count,
                                      size_t *out_len)
{
  size_t i, len = 0;
  for (i = 0; i < count; i++) {
    size_t plen = strlen(protos[i]);
    if (plen > 255) {
      return NULL;
    }
    len += 1 + plen;
  }
  unsigned char *buf = malloc(len);
  if (buf == NULL) {
    return NULL;
  }
  size_t off = 0;
  for (i = 0; i < count; i++) {
    size_t plen = strlen(protos[i]);
    buf[off++] = (unsigned char)plen;
    memcpy(buf + off, protos[i], plen);
    off += plen;
  }
  *out_len = len;
  return buf;
}

static unsigned char *eta_build_alpn_ocaml(value v_alpn, size_t *out_len)
{
  CAMLparam1(v_alpn);
  CAMLlocal1(v_item);
  size_t count = 0;
  value v_tail = v_alpn;
  while (Is_block(v_tail)) {
    count++;
    v_tail = Field(v_tail, 1);
  }
  if (count == 0) {
    *out_len = 0;
    CAMLreturnT(unsigned char *, NULL);
  }
  const char **protos = calloc(count, sizeof(char *));
  if (protos == NULL) {
    caml_failwith("calloc failed");
  }
  size_t i = 0;
  v_tail = v_alpn;
  while (Is_block(v_tail)) {
    v_item = Field(v_tail, 0);
    protos[i++] = String_val(v_item);
    v_tail = Field(v_tail, 1);
  }
  unsigned char *alpn_buf = eta_build_alpn(protos, count, out_len);
  free(protos);
  if (alpn_buf == NULL) {
    caml_failwith("ALPN encode failed");
  }
  CAMLreturnT(unsigned char *, alpn_buf);
}

static int eta_alpn_select_cb(SSL *ssl, const unsigned char **out,
                              unsigned char *outlen,
                              const unsigned char *in, unsigned int inlen,
                              void *arg)
{
  (void)ssl;
  eta_alpn_config *config = (eta_alpn_config *)arg;
  if (config == NULL || config->wire == NULL || config->len == 0) {
    return SSL_TLSEXT_ERR_NOACK;
  }
  int rc = SSL_select_next_proto((unsigned char **)out, outlen,
                                 config->wire, config->len, in, inlen);
  if (rc == OPENSSL_NPN_NEGOTIATED) {
    return SSL_TLSEXT_ERR_OK;
  }
  return SSL_TLSEXT_ERR_NOACK;
}

static int eta_install_alpn(SSL_CTX *ctx, const unsigned char *wire, size_t len)
{
  if (len == 0) {
    return 1;
  }
  eta_alpn_config *alpn = malloc(sizeof(*alpn));
  if (alpn == NULL) {
    return 0;
  }
  alpn->wire = malloc(len);
  if (alpn->wire == NULL) {
    free(alpn);
    return 0;
  }
  memcpy(alpn->wire, wire, len);
  alpn->len = (unsigned int)len;
  int idx = eta_alpn_ex_index_get();
  if (idx < 0 || SSL_CTX_set_ex_data(ctx, idx, alpn) != 1) {
    free(alpn->wire);
    free(alpn);
    return 0;
  }
  SSL_CTX_set_alpn_select_cb(ctx, eta_alpn_select_cb, alpn);
  return 1;
}

static SSL_CTX *eta_new_server_ctx(const char *cert, const char *key,
                                   const unsigned char *alpn_wire,
                                   size_t alpn_len)
{
  const SSL_METHOD *method = TLS_server_method();
  if (method == NULL) {
    caml_failwith("TLS_server_method failed");
  }
  SSL_CTX *ctx = SSL_CTX_new(method);
  if (ctx == NULL) {
    caml_failwith("SSL_CTX_new failed");
  }

  if (!SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) ||
      !SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION)) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_proto_version failed");
  }

  if (SSL_CTX_set_cipher_list(ctx, ETA_CIPHER_LIST) != 1) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_cipher_list failed");
  }
  if (SSL_CTX_set_ciphersuites(ctx, ETA_TLS13_CIPHER_LIST) != 1) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_ciphersuites failed");
  }

  /* Disable the internal server session cache (SSL_SESS_CACHE_SERVER). It takes
     a global ctx->lock write-lock on every full handshake to store the new
     session, which serializes handshakes across Eio domains. TLS 1.3 (and 1.2)
     resumption uses stateless session tickets, which do not depend on this
     in-process cache, so disabling it preserves resumption for real clients
     while removing the cross-domain contention point. */
  SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_OFF);
  if (SSL_CTX_set_session_id_context(
          ctx, ETA_SESSION_ID_CONTEXT,
          (unsigned int)(sizeof(ETA_SESSION_ID_CONTEXT) - 1)) != 1) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_session_id_context failed");
  }

  if (SSL_CTX_use_certificate_chain_file(ctx, cert) != 1) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_use_certificate_chain_file failed");
  }

  if (SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) != 1) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_use_PrivateKey_file failed");
  }

  if (SSL_CTX_check_private_key(ctx) != 1) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_check_private_key failed");
  }

  if (!eta_install_alpn(ctx, alpn_wire, alpn_len)) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_ex_data failed");
  }

  return ctx;
}

static int eta_sni_select_cb(SSL *ssl, int *ad, void *arg)
{
  eta_sni_config *config = (eta_sni_config *)arg;
  const char *name = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
  if (config == NULL || name == NULL || name[0] == '\0') {
    if (config != NULL && config->require_match) {
      *ad = SSL_AD_UNRECOGNIZED_NAME;
      return SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    return SSL_TLSEXT_ERR_NOACK;
  }

  for (size_t i = 0; i < config->count; i++) {
    if (strcasecmp(config->entries[i].name, name) == 0) {
      SSL_set_SSL_CTX(ssl, config->entries[i].ctx);
      return SSL_TLSEXT_ERR_OK;
    }
  }

  if (config->require_match) {
    *ad = SSL_AD_UNRECOGNIZED_NAME;
    return SSL_TLSEXT_ERR_ALERT_FATAL;
  }
  return SSL_TLSEXT_ERR_NOACK;
}

/* ------------------------------------------------------------------ */
/* OCaml externals                                                    */

CAMLprim value eta_openssl_ctx_create(value v_unit)
{
  CAMLparam1(v_unit);
  const SSL_METHOD *method = TLS_client_method();
  if (method == NULL) {
    caml_failwith("TLS_client_method failed");
  }
  SSL_CTX *ctx = SSL_CTX_new(method);
  if (ctx == NULL) {
    caml_failwith("SSL_CTX_new failed");
  }

  /* TLS 1.2 minimum; TLS 1.3 preferred when the peer supports it. */
  if (!SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) ||
      !SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION)) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_proto_version failed");
  }

  /* Cipher policy. */
  if (SSL_CTX_set_cipher_list(ctx, ETA_CIPHER_LIST) != 1) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_cipher_list failed");
  }
  if (SSL_CTX_set_ciphersuites(ctx, ETA_TLS13_CIPHER_LIST) != 1) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_ciphersuites failed");
  }

  SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_CLIENT);

  /* Default system trust store. */
  SSL_CTX_set_default_verify_paths(ctx);
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);

  CAMLreturn(eta_alloc_ssl_ctx(ctx));
}

CAMLprim value eta_openssl_ctx_load_ca(value v_ctx, value v_path)
{
  CAMLparam2(v_ctx, v_path);
  SSL_CTX *ctx = eta_ssl_ctx_val(v_ctx);
  const char *path = String_val(v_path);
  if (SSL_CTX_load_verify_locations(ctx, path, NULL) != 1) {
    char buf[256];
    unsigned long e = ERR_peek_error();
    if (e != 0) {
      ERR_error_string_n(e, buf, sizeof(buf));
      ERR_clear_error();
      caml_failwith(buf);
    } else {
      caml_failwith("SSL_CTX_load_verify_locations failed");
    }
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_openssl_server_ctx_create(value v_cert, value v_key,
                                             value v_sni_certs,
                                             value v_require_sni_match,
                                             value v_alpn)
{
  CAMLparam5(v_cert, v_key, v_sni_certs, v_require_sni_match, v_alpn);
  CAMLlocal2(v_tail, v_entry);
  size_t alpn_len = 0;
  unsigned char *alpn_wire = eta_build_alpn_ocaml(v_alpn, &alpn_len);
  SSL_CTX *ctx =
      eta_new_server_ctx(String_val(v_cert), String_val(v_key), alpn_wire,
                         alpn_len);

  size_t count = 0;
  v_tail = v_sni_certs;
  while (Is_block(v_tail)) {
    count++;
    v_tail = Field(v_tail, 1);
  }

  if (count > 0 || Bool_val(v_require_sni_match)) {
    eta_sni_config *sni = calloc(1, sizeof(*sni));
    if (sni == NULL) {
      free(alpn_wire);
      SSL_CTX_free(ctx);
      caml_failwith("calloc failed");
    }
    sni->count = count;
    sni->require_match = Bool_val(v_require_sni_match);
    if (count > 0) {
      sni->entries = calloc(count, sizeof(*sni->entries));
      if (sni->entries == NULL) {
        free(sni);
        free(alpn_wire);
        SSL_CTX_free(ctx);
        caml_failwith("calloc failed");
      }
    }

    size_t i = 0;
    v_tail = v_sni_certs;
    while (Is_block(v_tail)) {
      v_entry = Field(v_tail, 0);
      const char *name = String_val(Field(v_entry, 0));
      const char *cert = String_val(Field(v_entry, 1));
      const char *key = String_val(Field(v_entry, 2));
      sni->entries[i].name = strdup(name);
      if (sni->entries[i].name == NULL) {
        free(alpn_wire);
        SSL_CTX_free(ctx);
        eta_sni_ex_free(NULL, sni, NULL, 0, 0, NULL);
        caml_failwith("strdup failed");
      }
      sni->entries[i].ctx = eta_new_server_ctx(cert, key, alpn_wire, alpn_len);
      i++;
      v_tail = Field(v_tail, 1);
    }

    int idx = eta_sni_ex_index_get();
    if (idx < 0 || SSL_CTX_set_ex_data(ctx, idx, sni) != 1) {
      free(alpn_wire);
      SSL_CTX_free(ctx);
      eta_sni_ex_free(NULL, sni, NULL, 0, 0, NULL);
      caml_failwith("SSL_CTX_set_ex_data failed");
    }
    SSL_CTX_set_tlsext_servername_callback(ctx, eta_sni_select_cb);
    SSL_CTX_set_tlsext_servername_arg(ctx, sni);
  }

  free(alpn_wire);
  CAMLreturn(eta_alloc_ssl_ctx(ctx));
}

CAMLprim value eta_openssl_server_ssl_create(value v_ctx)
{
  CAMLparam1(v_ctx);

  SSL_CTX *ctx = eta_ssl_ctx_val(v_ctx);
  SSL *ssl = SSL_new(ctx);
  if (ssl == NULL) {
    caml_failwith("SSL_new failed");
  }

  BIO *rbio = BIO_new(BIO_s_mem());
  BIO *wbio = BIO_new(BIO_s_mem());
  if (rbio == NULL || wbio == NULL) {
    if (rbio) BIO_free(rbio);
    if (wbio) BIO_free(wbio);
    SSL_free(ssl);
    caml_failwith("BIO_new failed");
  }
  SSL_set_bio(ssl, rbio, wbio);
  SSL_set_accept_state(ssl);

  CAMLreturn(eta_alloc_ssl(ssl));
}

CAMLprim value eta_openssl_ssl_create(value v_ctx, value v_hostname,
                                      value v_ip, value v_alpn)
{
  CAMLparam4(v_ctx, v_hostname, v_ip, v_alpn);
  CAMLlocal1(v_item);

  SSL_CTX *ctx = eta_ssl_ctx_val(v_ctx);
  SSL *ssl = SSL_new(ctx);
  if (ssl == NULL) {
    caml_failwith("SSL_new failed");
  }

  /* Memory BIO pair.  SSL_set_bio takes ownership. */
  BIO *rbio = BIO_new(BIO_s_mem());
  BIO *wbio = BIO_new(BIO_s_mem());
  if (rbio == NULL || wbio == NULL) {
    if (rbio) BIO_free(rbio);
    if (wbio) BIO_free(wbio);
    SSL_free(ssl);
    caml_failwith("BIO_new failed");
  }
  SSL_set_bio(ssl, rbio, wbio);
  SSL_set_connect_state(ssl);

  /* SNI hostname. */
  if (Is_some(v_hostname)) {
    const char *host = String_val(Some_val(v_hostname));
    if (!SSL_set_tlsext_host_name(ssl, host)) {
      SSL_free(ssl);
      caml_failwith("SSL_set_tlsext_host_name failed");
    }
  }

  /* Peer certificate identity.  SNI stays DNS-only; IP literals use OpenSSL's
     IP SAN matcher instead of falling through to hostname-less verification. */
  {
    X509_VERIFY_PARAM *param = SSL_get0_param(ssl);
    if (param == NULL) {
      SSL_free(ssl);
      caml_failwith("SSL_get0_param failed");
    }
    if (Is_some(v_ip)) {
      const char *ip = String_val(Some_val(v_ip));
      if (X509_VERIFY_PARAM_set1_ip_asc(param, ip) != 1) {
        SSL_free(ssl);
        caml_failwith("X509_VERIFY_PARAM_set1_ip_asc failed");
      }
    } else if (Is_some(v_hostname)) {
      const char *host = String_val(Some_val(v_hostname));
      X509_VERIFY_PARAM_set_hostflags(
          param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
      if (X509_VERIFY_PARAM_set1_host(param, host, 0) != 1) {
        SSL_free(ssl);
        caml_failwith("X509_VERIFY_PARAM_set1_host failed");
      }
    }
  }

  /* ALPN.  v_alpn is an OCaml string list. */
  {
    size_t count = 0;
    value v_tail = v_alpn;
    while (Is_block(v_tail)) {
      count++;
      v_tail = Field(v_tail, 1);
    }
    if (count > 0) {
      const char **protos = calloc(count, sizeof(char *));
      if (protos == NULL) {
        SSL_free(ssl);
        caml_failwith("calloc failed");
      }
      size_t i = 0;
      v_tail = v_alpn;
      while (Is_block(v_tail)) {
        v_item = Field(v_tail, 0);
        protos[i++] = String_val(v_item);
        v_tail = Field(v_tail, 1);
      }
      size_t alpn_len = 0;
      unsigned char *alpn_buf = eta_build_alpn(protos, count, &alpn_len);
      free(protos);
      if (alpn_buf == NULL) {
        SSL_free(ssl);
        caml_failwith("ALPN encode failed");
      }
      int rc = SSL_set_alpn_protos(ssl, alpn_buf, (unsigned int)alpn_len);
      free(alpn_buf);
      if (rc != 0) {
        SSL_free(ssl);
        caml_failwith("SSL_set_alpn_protos failed");
      }
    }
  }

  CAMLreturn(eta_alloc_ssl(ssl));
}

CAMLprim value eta_openssl_ssl_handshake(value v_ssl)
{
  CAMLparam1(v_ssl);
  SSL *ssl = eta_ssl_val(v_ssl);
  /* SSL_do_handshake runs the CPU-heavy crypto (key exchange, server signature)
     entirely in C against in-memory BIOs; the ALPN/SNI callbacks it may invoke
     are pure C (no OCaml access). Release the OCaml runtime around it so other
     domains are not blocked from reaching GC safepoints while this domain
     signs the handshake -- important for multi-domain handshake parallelism on
     OCaml 5. */
  caml_enter_blocking_section();
  int rc = SSL_do_handshake(ssl);
  caml_leave_blocking_section();
  if (rc == 1) {
    CAMLreturn(Val_int(0)); /* Ok */
  }
  int err = SSL_get_error(ssl, rc);
  CAMLreturn(Val_int(err));
}

CAMLprim value eta_openssl_ssl_read(value v_ssl, value v_buf,
                                    value v_off, value v_len)
{
  CAMLparam4(v_ssl, v_buf, v_off, v_len);
  SSL *ssl = eta_ssl_val(v_ssl);
  char *data = Caml_ba_data_val(v_buf) + Int_val(v_off);
  size_t readbytes = 0;
  int rc = SSL_read_ex(ssl, data, Int_val(v_len), &readbytes);
  if (rc > 0) {
    CAMLreturn(Val_long((long)readbytes));
  }
  int err = SSL_get_error(ssl, rc);
  CAMLreturn(Val_long(-err));
}

CAMLprim value eta_openssl_ssl_write(value v_ssl, value v_buf,
                                     value v_off, value v_len)
{
  CAMLparam4(v_ssl, v_buf, v_off, v_len);
  SSL *ssl = eta_ssl_val(v_ssl);
  const char *data = Caml_ba_data_val(v_buf) + Int_val(v_off);
  size_t written = 0;
  int rc = SSL_write_ex(ssl, data, Int_val(v_len), &written);
  if (rc > 0) {
    CAMLreturn(Val_long((long)written));
  }
  int err = SSL_get_error(ssl, rc);
  CAMLreturn(Val_long(-err));
}

CAMLprim value eta_openssl_ssl_shutdown(value v_ssl)
{
  CAMLparam1(v_ssl);
  SSL *ssl = eta_ssl_val(v_ssl);
  int rc = SSL_shutdown(ssl);
  CAMLreturn(Val_int(rc));
}

/* Read encrypted bytes from the write BIO (data OpenSSL wants to send). */
CAMLprim value eta_openssl_bio_read(value v_ssl, value v_buf,
                                    value v_off, value v_len)
{
  CAMLparam4(v_ssl, v_buf, v_off, v_len);
  SSL *ssl = eta_ssl_val(v_ssl);
  BIO *wbio = SSL_get_wbio(ssl);
  if (wbio == NULL) {
    CAMLreturn(Val_long(0));
  }
  char *data = Caml_ba_data_val(v_buf) + Int_val(v_off);
  int n = BIO_read(wbio, data, Int_val(v_len));
  if (n < 0) {
    n = 0;
  }
  CAMLreturn(Val_long(n));
}

/* Write encrypted bytes into the read BIO (data received from network). */
CAMLprim value eta_openssl_bio_write(value v_ssl, value v_buf,
                                     value v_off, value v_len)
{
  CAMLparam4(v_ssl, v_buf, v_off, v_len);
  SSL *ssl = eta_ssl_val(v_ssl);
  BIO *rbio = SSL_get_rbio(ssl);
  if (rbio == NULL) {
    CAMLreturn(Val_long(0));
  }
  const char *data = Caml_ba_data_val(v_buf) + Int_val(v_off);
  int n = BIO_write(rbio, data, Int_val(v_len));
  if (n < 0) {
    n = 0;
  }
  CAMLreturn(Val_long(n));
}

/* Number of bytes pending in the write BIO. */
CAMLprim value eta_openssl_bio_write_pending(value v_ssl)
{
  CAMLparam1(v_ssl);
  SSL *ssl = eta_ssl_val(v_ssl);
  BIO *wbio = SSL_get_wbio(ssl);
  if (wbio == NULL) {
    CAMLreturn(Val_long(0));
  }
  int n = BIO_ctrl_pending(wbio);
  if (n < 0) {
    n = 0;
  }
  CAMLreturn(Val_long(n));
}

/* Number of bytes readable from SSL (decrypted). */
CAMLprim value eta_openssl_ssl_pending(value v_ssl)
{
  CAMLparam1(v_ssl);
  SSL *ssl = eta_ssl_val(v_ssl);
  int n = SSL_pending(ssl);
  if (n < 0) {
    n = 0;
  }
  CAMLreturn(Val_long(n));
}

CAMLprim value eta_openssl_ssl_get_alpn_selected(value v_ssl)
{
  CAMLparam1(v_ssl);
  CAMLlocal1(v_result);
  SSL *ssl = eta_ssl_val(v_ssl);
  const unsigned char *data = NULL;
  unsigned int len = 0;
  SSL_get0_alpn_selected(ssl, &data, &len);
  if (data == NULL || len == 0) {
    CAMLreturn(Val_none);
  }
  v_result = caml_alloc_string(len);
  memcpy((char *)String_val(v_result), data, len);
  CAMLreturn(caml_alloc_some(v_result));
}

CAMLprim value eta_openssl_ssl_get_version(value v_ssl)
{
  CAMLparam1(v_ssl);
  SSL *ssl = eta_ssl_val(v_ssl);
  CAMLreturn(caml_copy_string(SSL_get_version(ssl)));
}

CAMLprim value eta_openssl_ssl_get_servername(value v_ssl)
{
  CAMLparam1(v_ssl);
  SSL *ssl = eta_ssl_val(v_ssl);
  const char *name = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
  if (name == NULL || name[0] == '\0') {
    CAMLreturn(Val_none);
  }
  CAMLreturn(caml_alloc_some(caml_copy_string(name)));
}

CAMLprim value eta_openssl_ssl_get_verify_result(value v_ssl)
{
  CAMLparam1(v_ssl);
  SSL *ssl = eta_ssl_val(v_ssl);
  long rc = SSL_get_verify_result(ssl);
  CAMLreturn(Val_long(rc));
}

CAMLprim value eta_openssl_ssl_get1_session(value v_ssl)
{
  CAMLparam1(v_ssl);
  CAMLlocal1(v_session);
  SSL *ssl = eta_ssl_val(v_ssl);
  SSL_SESSION *session = SSL_get1_session(ssl);
  if (session == NULL) {
    CAMLreturn(Val_none);
  }
  v_session = eta_alloc_ssl_session(session);
  CAMLreturn(caml_alloc_some(v_session));
}

CAMLprim value eta_openssl_ssl_set_session(value v_ssl, value v_session)
{
  CAMLparam2(v_ssl, v_session);
  SSL *ssl = eta_ssl_val(v_ssl);
  SSL_SESSION *session = eta_ssl_session_val(v_session);
  if (SSL_set_session(ssl, session) != 1) {
    caml_failwith("SSL_set_session failed");
  }
  CAMLreturn(Val_unit);
}

CAMLprim value eta_openssl_ssl_session_reused(value v_ssl)
{
  CAMLparam1(v_ssl);
  SSL *ssl = eta_ssl_val(v_ssl);
  CAMLreturn(Val_bool(SSL_session_reused(ssl) == 1));
}

CAMLprim value eta_openssl_err_peek_error(value v_unit)
{
  CAMLparam1(v_unit);
  unsigned long e = ERR_peek_error();
  if (e == 0) {
    CAMLreturn(Val_none);
  }
  char buf[256];
  ERR_error_string_n(e, buf, sizeof(buf));
  CAMLreturn(caml_alloc_some(caml_copy_string(buf)));
}

CAMLprim value eta_openssl_err_clear_error(value v_unit)
{
  CAMLparam1(v_unit);
  ERR_clear_error();
  CAMLreturn(Val_unit);
}
