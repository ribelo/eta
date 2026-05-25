(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type ctx
type ssl

type handshake_result =
  | Handshake_ok
  | Handshake_error of int

external create_ctx : unit -> ctx = "eta_openssl_ctx_create"
external create_ssl_raw : ctx -> string option -> string list -> ssl = "eta_openssl_ssl_create"
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

let create_ssl ctx ~hostname ~alpn_protocols =
  create_ssl_raw ctx hostname alpn_protocols

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
