(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Low-level OpenSSL 3.x binding. No I/O — pure state-machine driver. *)

type ctx
(** Opaque SSL_CTX wrapper. *)

type ssl
(** Opaque SSL wrapper with memory BIO pair. *)

val create_ctx : unit -> ctx
(** Create a client SSL_CTX with TLS 1.2-only policy ciphers, default
    system trust store, and peer verification enabled. *)

val ctx_load_ca : ctx -> string -> unit
(** [ctx_load_ca ctx path] adds [path] (a PEM CA file) to the trust
    store of [ctx]. The default system trust store remains in eff.
    Raises [Failure] if the file cannot be loaded. *)

val create_ssl :
  ctx ->
  hostname:string option ->
  ip:string option ->
  alpn_protocols:string list ->
  ssl
(** Create an SSL connection with memory BIOs. [hostname] sets SNI and,
    when [ip] is absent, DNS peer certificate identity verification. [ip]
    sets IP peer certificate identity verification. [alpn_protocols] are sent
    in wire order. *)

type handshake_result =
  | Handshake_ok
  | Handshake_error of int

val handshake : ssl -> handshake_result
(** Drive one step of the TLS handshake. Returns [Handshake_ok] on
    completion, or [Handshake_error code] where [code] is the raw
    [SSL_get_error] value. *)

val read : ssl -> Cstruct.buffer -> int -> int -> int
(** [read ssl buf off len] attempts to read up to [len] decrypted bytes
    into [buf] at offset [off]. Returns bytes read on success, or a
    negated [SSL_get_error] code on failure. *)

val write : ssl -> Cstruct.buffer -> int -> int -> int
(** [write ssl buf off len] attempts to write [len] decrypted bytes
    from [buf] at offset [off]. Returns bytes written on success, or a
    negated [SSL_get_error] code on failure. *)

val shutdown : ssl -> int
(** Initiate SSL shutdown. Returns [SSL_shutdown] result. *)

val bio_read : ssl -> Cstruct.buffer -> int -> int -> int
(** Read encrypted bytes from OpenSSL's write BIO (data to send over
    the wire). *)

val bio_write : ssl -> Cstruct.buffer -> int -> int -> int
(** Write encrypted bytes into OpenSSL's read BIO (data received from
    the wire). *)

val bio_write_pending : ssl -> int
(** Number of encrypted bytes pending in the write BIO. *)

val ssl_pending : ssl -> int
(** Number of decrypted bytes readable from SSL without touching the
    network. *)

val get_alpn_selected : ssl -> string option
(** The ALPN protocol selected by the server, if any. *)

val get_verify_result : ssl -> int
(** [X509_V_OK] (0) on success, or an [X509_V_ERR_*] code. *)

val err_peek_error : unit -> string option
(** Peek at the top OpenSSL error string, if any. *)

val err_clear_error : unit -> unit
(** Clear the OpenSSL error stack. *)

val random_bytes : int -> bytes
(** [random_bytes len] returns [len] bytes from OpenSSL [RAND_bytes].
    Raises [Failure] if OpenSSL cannot provide random bytes. *)

val sha1 : string -> string
(** [sha1 input] returns the 20-byte SHA-1 digest from OpenSSL EVP. Eta uses
    this for protocol-mandated WebSocket accept keys, not as a security
    primitive exposed to applications. *)
