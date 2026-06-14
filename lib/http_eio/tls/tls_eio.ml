(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type config = Config.t
type server_config = Config.server
type server_context = { ctx : Openssl.ctx }

type epoch = {
  alpn_protocol : string option;
  sni : string option;
  peer_certificate_verified : bool;
}

type flow =
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty | `Eta_tls ] Eio.Resource.t

module type EIO_FLOW = Eta_eio.Host.FLOW

module Default_eio_flow : EIO_FLOW = Eio.Flow

type 'a t_rec = {
  ssl : Openssl.ssl;
  flow : 'a;
  eio_flow : (module EIO_FLOW);
  ssl_mutex : Eio.Mutex.t;
  handshake_mutex : Eio.Mutex.t;
  read_mutex : Eio.Mutex.t;
  write_mutex : Eio.Mutex.t;
  progress_mutex : Eio.Mutex.t;
  progress_condition : Eio.Condition.t;
  sni : string option;
  mutable peer_certificate_verified : bool;
  mutable handshake_done : bool;
  mutable closed : bool;
  mutable progress_epoch : int;
  (* Reused per-connection scratch buffers for the OpenSSL BIO pump. feed_buf
     is serialized by read_mutex, drain_buf by write_mutex, so reuse is safe and
     avoids a fresh bigarray malloc on every feed_bio/drain_bio call (several
     per handshake, which under multi-domain load contends in the allocator). *)
  mutable feed_buf : Cstruct.t;
  mutable drain_buf : Cstruct.t;
}

type t = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t t_rec

type tls_state = St : t -> tls_state

type (_, _, _) Eio.Resource.pi += Tls_state : ('a, 'a -> tls_state, [> `Eta_tls ]) Eio.Resource.pi

let with_ssl t f = Eio.Mutex.use_rw ~protect:false t.ssl_mutex f
let with_flow_read t f = Eio.Mutex.use_ro t.read_mutex f
let with_flow_write t f = Eio.Mutex.use_ro t.write_mutex f

(* Post-handshake TLS ownership invariants:
   - ciphertext reads from the raw flow are serialized by [read_mutex];
   - [single_write] may feed rbio when SSL_write wants input, so it never
     depends on an external reader fiber to make TLS progress;
   - [single_read] drains pending plaintext before blocking on raw input;
   - read-side OpenSSL progress wakes writers that are retrying WANT_READ. *)

let notify_tls_progress t =
  Eio.Mutex.use_rw ~protect:false t.progress_mutex (fun () ->
      t.progress_epoch <- t.progress_epoch + 1;
      Eio.Condition.broadcast t.progress_condition)

let tls_progress_epoch t =
  Eio.Mutex.use_ro t.progress_mutex (fun () -> t.progress_epoch)

let wait_for_tls_progress t epoch =
  Eio.Mutex.use_rw ~protect:false t.progress_mutex (fun () ->
      while (not t.closed) && t.progress_epoch = epoch do
        Eio.Condition.await t.progress_condition t.progress_mutex
      done)

let debug_io direction storage ~storage_off ~display_off ~len =
  match Sys.getenv_opt "ETA_TLS_DEBUG" with
  | None -> ()
  | Some _ ->
      let dump_n = min len 32 in
      let hex = Buffer.create (dump_n * 3) in
      for i = 0 to dump_n - 1 do
        let value = Char.code (Bigarray.Array1.get storage (storage_off + i)) in
        Buffer.add_char hex (Eta.String_helpers.lower_hex_digit (value lsr 4));
        Buffer.add_char hex (Eta.String_helpers.lower_hex_digit (value land 0xf));
        Buffer.add_char hex ' '
      done;
      Printf.eprintf "[tls] %s rc=%d off=%d head: %s\n%!" direction len
        display_off (Buffer.contents hex)

let feed_bio_unlocked t =
  let module Flow = (val t.eio_flow : EIO_FLOW) in
  let buf = t.feed_buf in
  let n = Flow.single_read t.flow buf in
  if n = 0 then (
    t.closed <- true;
    notify_tls_progress t;
    raise End_of_file);
  let rec write_all off len =
    if len > 0 then (
      let written =
        with_ssl t (fun () ->
            Openssl.bio_write t.ssl (Cstruct.to_bigarray buf) off len)
      in
      if written <= 0 then failwith "TLS BIO write failed";
      write_all (off + written) (len - written))
  in
  write_all 0 n;
  notify_tls_progress t

(* Helper: read encrypted data from underlying flow into OpenSSL's read BIO. *)
let feed_bio t = with_flow_read t (fun () -> feed_bio_unlocked t)

let feed_bio_if_needed t epoch =
  with_flow_read t (fun () ->
      if t.progress_epoch = epoch then feed_bio_unlocked t)

let drive_want_read t epoch =
  Eio.Fiber.first
    (fun () -> feed_bio_if_needed t epoch)
    (fun () -> wait_for_tls_progress t epoch);
  if t.closed then raise End_of_file

(* Helper: drain OpenSSL's write BIO to the underlying flow. *)
let drain_bio t =
  let module Flow = (val t.eio_flow : EIO_FLOW) in
  with_flow_write t (fun () ->
      let drained = ref false in
      let rec loop () =
        let pending = with_ssl t (fun () -> Openssl.bio_write_pending t.ssl) in
        if pending > 0 then (
          if pending > Cstruct.length t.drain_buf then
            t.drain_buf <- Cstruct.create pending;
          let buf = t.drain_buf in
          let n =
            with_ssl t (fun () ->
                Openssl.bio_read t.ssl (Cstruct.to_bigarray buf) 0 pending)
          in
          if n > 0 then (
            drained := true;
            Flow.write t.flow [ Cstruct.sub buf 0 n ];
            loop ()))
      in
      loop ();
      !drained)

(* Drive the TLS handshake to completion. *)
let do_handshake t =
  Eio.Mutex.use_rw ~protect:false t.handshake_mutex (fun () ->
      if not t.handshake_done then
        let rec loop () =
          let rc = with_ssl t (fun () -> Openssl.handshake t.ssl) in
          match rc with
          | Openssl.Handshake_ok ->
              ignore (drain_bio t);
              notify_tls_progress t;
              t.handshake_done <- true
          | Openssl.Handshake_error code -> (
              ignore (drain_bio t);
              if code = 2 (* SSL_ERROR_WANT_READ *) then (
                feed_bio t;
                loop ())
              else if code = 3 (* SSL_ERROR_WANT_WRITE *) then (
                if not (drain_bio t) then Eio.Fiber.yield ();
                loop ())
              else (
                match Openssl.err_peek_error () with
                | Some msg ->
                    Openssl.err_clear_error ();
                    failwith ("TLS handshake: " ^ msg)
                | None ->
                    failwith
                      ("TLS handshake failed (code " ^ string_of_int code ^ ")")
                ))
        in
        loop ())

let shutdown_send t =
  if not t.closed then (
    let _ = with_ssl t (fun () -> Openssl.shutdown t.ssl) in
    ignore (drain_bio t);
    t.closed <- true;
    notify_tls_progress t)

let close_underlying t = try Eio.Flow.close t.flow with _ -> ()

let close t =
  t.closed <- true;
  notify_tls_progress t;
  close_underlying t

module Flow_impl = struct
  type nonrec t = t

  let read_methods = []

  let single_read t buf =
    (* No coarse read/write lock here: reads and writes on a TLS flow must be
       able to proceed concurrently for full-duplex protocols like HTTP/2. The
       shared SSL object is serialized by [ssl_mutex] (via [with_ssl]); socket
       reads are serialized by [read_mutex] in [feed_bio] and socket writes by
       [write_mutex] in [drain_bio]. A coarse per-direction lock here would let
       a reader parked in [feed_bio] starve the writer (and vice versa),
       deadlocking large H2 transfers. *)
    if t.closed then raise End_of_file;
    if not t.handshake_done then do_handshake t;
    let { Cstruct.off = display_off; len } = buf in
    let storage = Cstruct.to_bigarray buf in
    let rec loop () =
      let rc = with_ssl t (fun () -> Openssl.read t.ssl storage 0 len) in
      if rc > 0 then (
        debug_io "read" storage ~storage_off:0 ~display_off ~len:rc;
        notify_tls_progress t;
        rc)
      else if rc = 0 then (
        t.closed <- true;
        notify_tls_progress t;
        raise End_of_file)
      else (
        let code = -rc in
        ignore (drain_bio t);
        if code = 2 (* SSL_ERROR_WANT_READ *) then (
          feed_bio t;
          loop ())
        else if code = 3 (* SSL_ERROR_WANT_WRITE *) then (
          if not (drain_bio t) then Eio.Fiber.yield ();
          loop ())
        else if code = 6 (* SSL_ERROR_ZERO_RETURN *) then (
          t.closed <- true;
          notify_tls_progress t;
          raise End_of_file)
        else (
          match Openssl.err_peek_error () with
          | Some msg ->
              Openssl.err_clear_error ();
              failwith ("TLS read: " ^ msg)
          | None ->
              failwith ("TLS read failed (code " ^ string_of_int code ^ ")")))
    in
    loop ()

  let single_write t bufs =
    if t.closed then raise End_of_file
    else (
      if not t.handshake_done then do_handshake t;
      let total = ref 0 in
      List.iter
        (fun buf ->
          let { Cstruct.off = display_off; len } = buf in
          let storage = Cstruct.to_bigarray buf in
          let rec write_buf offset length =
            if t.closed then raise End_of_file;
            if length > 0 then (
              let epoch = tls_progress_epoch t in
              let rc =
                with_ssl t (fun () -> Openssl.write t.ssl storage offset length)
              in
              if rc > 0 then (
                debug_io "write" storage ~storage_off:offset
                  ~display_off:(display_off + offset) ~len:rc;
                total := !total + rc;
                ignore (drain_bio t);
                if rc < length then write_buf (offset + rc) (length - rc))
              else (
                let code = -rc in
                ignore (drain_bio t);
                if code = 2 (* SSL_ERROR_WANT_READ *) then (
                  drive_want_read t epoch;
                  write_buf offset length)
                else if code = 3 (* SSL_ERROR_WANT_WRITE *) then (
                  if not (drain_bio t) then Eio.Fiber.yield ();
                  write_buf offset length)
                else if code = 6 (* SSL_ERROR_ZERO_RETURN *) then
                  raise End_of_file
                else (
                  match Openssl.err_peek_error () with
                  | Some msg ->
                      Openssl.err_clear_error ();
                      failwith ("TLS write: " ^ msg)
                  | None ->
                      failwith
                        ("TLS write failed (code " ^ string_of_int code ^ ")"))))
          in
          write_buf 0 len)
        bufs;
      !total)

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src

  let shutdown t cmd =
    match cmd with
    | `Send -> shutdown_send t
    | `All ->
        Fun.protect ~finally:(fun () -> close_underlying t) (fun () ->
            shutdown_send t)
    | `Receive -> ()
end

let ops =
  Eio.Resource.handler (
    Eio.Resource.H (Tls_state, (fun t -> St t))
    :: Eio.Resource.H (Eio.Resource.Close, close)
    :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Flow_impl))
  )

let flow_module = function
  | None -> (module Default_eio_flow : EIO_FLOW)
  | Some host_eio ->
      let module Flow = (val Eta_eio.Host.flow host_eio : Eta_eio.Host.FLOW) in
      (module Flow : EIO_FLOW)

let make_tls_state ?host_eio ?sni ?(peer_certificate_verified = false) ssl flow =
  {
    ssl;
    flow;
    eio_flow = flow_module host_eio;
    ssl_mutex = Eio.Mutex.create ();
    handshake_mutex = Eio.Mutex.create ();
    read_mutex = Eio.Mutex.create ();
    write_mutex = Eio.Mutex.create ();
    progress_mutex = Eio.Mutex.create ();
    progress_condition = Eio.Condition.create ();
    sni;
    peer_certificate_verified;
    handshake_done = false;
    closed = false;
    progress_epoch = 0;
    feed_buf = Cstruct.create 32768;
    drain_buf = Cstruct.create 16384;
  }

let epoch_of_state t =
  {
    alpn_protocol = Openssl.get_alpn_selected t.ssl;
    sni = t.sni;
    peer_certificate_verified = t.peer_certificate_verified;
  }

let client_of_flow ?host_eio (config : config) ?host
    (flow : [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t) :
    flow =
  let hostname =
    match host with
    | Some h -> Some (Domain_name.to_string h)
    | None -> Option.map Domain_name.to_string (Config.peer_name config)
  in
  let ip = Option.map Ipaddr.to_string (Config.ip config) in
  let ctx = Openssl.create_ctx () in
  (match Config.ca_file config with
   | Some path -> Openssl.ctx_load_ca ctx path
   | None -> ());
  let ssl =
    Openssl.create_ssl ctx ~hostname ~ip
      ~alpn_protocols:(Config.alpn_protocols config)
  in
  let t = make_tls_state ?host_eio ?sni:hostname ssl flow in
  do_handshake t;
  let verify = Openssl.get_verify_result ssl in
  if verify <> 0 then
    failwith ("TLS certificate verification failed (code " ^ string_of_int verify ^ ")");
  t.peer_certificate_verified <- true;
  (match Sys.getenv_opt "ETA_TLS_DEBUG" with
   | Some _ ->
       Printf.eprintf "[tls_eio] handshake done, alpn=%s\n%!"
         (match Openssl.get_alpn_selected ssl with Some p -> p | None -> "<none>")
   | None -> ());
  (Eio.Resource.T (t, ops) :> flow)

let server_context (config : server_config) =
  let certificates =
    Config.server_certificates config
    |> List.map (fun certificate ->
           Openssl.server_certificate
             ~server_name:(Config.server_certificate_name certificate)
             ~certificate_chain_file:
               (Config.server_certificate_chain_file certificate)
             ~private_key_file:
               (Config.server_certificate_private_key_file certificate))
  in
  {
    ctx =
      Openssl.create_server_ctx
        ~certificate_chain_file:(Config.certificate_chain_file config)
        ~private_key_file:(Config.private_key_file config)
        ~certificates
        ~require_sni_match:(Config.require_sni_match config)
        ~alpn_protocols:(Config.server_alpn_protocols config)
        ();
  }

let server_of_flow_with_context ?host_eio context
    (flow : [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t) :
    flow * epoch =
  let ssl = Openssl.create_server_ssl context.ctx in
  let t = make_tls_state ?host_eio ssl flow in
  do_handshake t;
  let t = { t with sni = Openssl.get_servername ssl } in
  let epoch = epoch_of_state t in
  ((Eio.Resource.T (t, ops) :> flow), epoch)

let server_of_flow ?host_eio config flow =
  server_of_flow_with_context ?host_eio (server_context config) flow

let epoch flow =
  try
    let (Eio.Resource.T (t, handler)) = flow in
    let St t = Eio.Resource.get handler Tls_state t in
    if not t.handshake_done then Error ()
    else Ok (epoch_of_state t)
  with _ -> Error ()

let alpn_protocol flow =
  match epoch flow with
  | Ok e -> e.alpn_protocol
  | Error () -> None
