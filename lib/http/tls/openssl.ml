(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type ctx
type ssl

type handshake_result =
  | Handshake_ok
  | Handshake_error of int

external create_ctx : unit -> ctx = "eta_openssl_ctx_create"
external ctx_load_ca : ctx -> string -> unit = "eta_openssl_ctx_load_ca"
external create_server_ctx_raw : string -> string -> string list -> ctx
  = "eta_openssl_server_ctx_create"
external create_server_ssl : ctx -> ssl = "eta_openssl_server_ssl_create"
external create_ssl_raw : ctx -> string option -> string option -> string list -> ssl
  = "eta_openssl_ssl_create"
external handshake_raw : ssl -> int = "eta_openssl_ssl_handshake"
external read_raw : ssl -> Cstruct.buffer -> int -> int -> int = "eta_openssl_ssl_read"
external write_raw : ssl -> Cstruct.buffer -> int -> int -> int = "eta_openssl_ssl_write"
external shutdown_raw : ssl -> int = "eta_openssl_ssl_shutdown"
external bio_read_raw : ssl -> Cstruct.buffer -> int -> int -> int = "eta_openssl_bio_read"
external bio_write_raw : ssl -> Cstruct.buffer -> int -> int -> int = "eta_openssl_bio_write"
external bio_write_pending_raw : ssl -> int = "eta_openssl_bio_write_pending"
external ssl_pending_raw : ssl -> int = "eta_openssl_ssl_pending"
external get_alpn_selected_raw : ssl -> string option = "eta_openssl_ssl_get_alpn_selected"
external get_verify_result_raw : ssl -> int = "eta_openssl_ssl_get_verify_result"
external err_peek_error_raw : unit -> string option = "eta_openssl_err_peek_error"
external err_clear_error_raw : unit -> unit = "eta_openssl_err_clear_error"
external random_bytes_into : bytes -> int -> int -> unit = "eta_openssl_random_bytes"
external sha1 : string -> string = "eta_openssl_sha1"

let random_bytes len =
  if len < 0 then invalid_arg "OpenSSL.random_bytes: negative length";
  let bytes = Bytes.create len in
  random_bytes_into bytes 0 len;
  bytes

let create_ssl ctx ~hostname ~ip ~alpn_protocols =
  create_ssl_raw ctx hostname ip alpn_protocols

let create_server_ctx ~certificate_chain_file ~private_key_file ~alpn_protocols =
  create_server_ctx_raw certificate_chain_file private_key_file alpn_protocols

let handshake ssl =
  match handshake_raw ssl with
  | 0 -> Handshake_ok
  | code -> Handshake_error code

let read ssl buf off len = read_raw ssl buf off len
let write ssl buf off len = write_raw ssl buf off len
let shutdown ssl = shutdown_raw ssl
let bio_read ssl buf off len = bio_read_raw ssl buf off len
let bio_write ssl buf off len = bio_write_raw ssl buf off len
let bio_write_pending ssl = bio_write_pending_raw ssl
let ssl_pending ssl = ssl_pending_raw ssl
let get_alpn_selected ssl = get_alpn_selected_raw ssl
let get_verify_result ssl = get_verify_result_raw ssl
let err_peek_error () = err_peek_error_raw ()
let err_clear_error () = err_clear_error_raw ()
