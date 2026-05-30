/* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT */

#include <string.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/bio.h>

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

/* ------------------------------------------------------------------ */
/* SSL_CTX — custom block; finalizer frees the context.                */

static int eta_ssl_ctx_cmp(value v1, value v2)
{
  return *((void **)Data_custom_val(v1)) != *((void **)Data_custom_val(v2));
}

static intnat eta_ssl_ctx_hash(value v)
{
  return (intnat)*((void **)Data_custom_val(v));
}

static void eta_ssl_ctx_finalize(value v)
{
  SSL_CTX *ctx = *((SSL_CTX **)Data_custom_val(v));
  if (ctx != NULL) {
    SSL_CTX_free(ctx);
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
  return *((SSL_CTX **)Data_custom_val(v));
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

  /* TLS 1.2 only. */
  if (!SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) ||
      !SSL_CTX_set_max_proto_version(ctx, TLS1_2_VERSION)) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_proto_version failed");
  }

  /* Cipher policy. */
  if (SSL_CTX_set_cipher_list(ctx, ETA_CIPHER_LIST) != 1) {
    SSL_CTX_free(ctx);
    caml_failwith("SSL_CTX_set_cipher_list failed");
  }

  /* Default system trust store. */
  SSL_CTX_set_default_verify_paths(ctx);
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);

  value v = caml_alloc_custom(&eta_ssl_ctx_ops, sizeof(void *), 0, 1);
  *((void **)Data_custom_val(v)) = ctx;
  CAMLreturn(v);
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

CAMLprim value eta_openssl_ssl_create(value v_ctx, value v_hostname,
                                      value v_alpn)
{
  CAMLparam3(v_ctx, v_hostname, v_alpn);
  CAMLlocal2(v_item, v_result);

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
  int rc = SSL_do_handshake(ssl);
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

CAMLprim value eta_openssl_ssl_get_verify_result(value v_ssl)
{
  CAMLparam1(v_ssl);
  SSL *ssl = eta_ssl_val(v_ssl);
  long rc = SSL_get_verify_result(ssl);
  CAMLreturn(Val_long(rc));
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
