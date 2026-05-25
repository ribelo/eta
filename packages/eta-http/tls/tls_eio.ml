(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type config = Config.t

type epoch = { alpn_protocol : string option }

type flow =
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty | `Eta_tls ] Eio.Resource.t

type 'a t_rec = {
  ssl : Openssl.ssl;
  flow : 'a;
  ssl_mutex : Eio.Mutex.t;
  read_mutex : Eio.Mutex.t;
  write_mutex : Eio.Mutex.t;
  mutable handshake_done : bool;
  mutable closed : bool;
}

type t = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t t_rec

type tls_state = St : t -> tls_state

type (_, _, _) Eio.Resource.pi += Tls_state : ('a, 'a -> tls_state, [> `Eta_tls ]) Eio.Resource.pi

let with_ssl t f = Eio.Mutex.use_rw ~protect:false t.ssl_mutex f

let debug_io direction storage ~storage_off ~display_off ~len =
  match Sys.getenv_opt "ETA_TLS_DEBUG" with
  | None -> ()
  | Some _ ->
      let dump_n = min len 32 in
      let hex = Buffer.create (dump_n * 3) in
      for i = 0 to dump_n - 1 do
        Buffer.add_string hex
          (Printf.sprintf "%02x "
             (Char.code (Bigarray.Array1.get storage (storage_off + i))))
      done;
      Printf.eprintf "[tls] %s rc=%d off=%d head: %s\n%!" direction len
        display_off (Buffer.contents hex)

(* Helper: read encrypted data from underlying flow into OpenSSL's read BIO. *)
let feed_bio t =
  let buf = Cstruct.create 4096 in
  Eio.Mutex.use_rw ~protect:false t.read_mutex (fun () ->
      let n = Eio.Flow.single_read t.flow buf in
      let rec write_all off len =
        if len > 0 then (
          let written =
            with_ssl t (fun () ->
                Openssl.bio_write t.ssl (Cstruct.to_bigarray buf) off len)
          in
          if written <= 0 then failwith "TLS BIO write failed";
          write_all (off + written) (len - written))
      in
      write_all 0 n)

(* Helper: drain OpenSSL's write BIO to the underlying flow. *)
let drain_bio t =
  Eio.Mutex.use_rw ~protect:false t.write_mutex (fun () ->
      let rec loop () =
        let pending = with_ssl t (fun () -> Openssl.bio_write_pending t.ssl) in
        if pending > 0 then (
          let buf = Cstruct.create pending in
          let n =
            with_ssl t (fun () ->
                Openssl.bio_read t.ssl (Cstruct.to_bigarray buf) 0 pending)
          in
          if n > 0 then (
            Eio.Flow.write t.flow [ Cstruct.sub buf 0 n ];
            loop ()))
      in
      loop ())

(* Drive the TLS handshake to completion. *)
let rec do_handshake t =
  let rc = Openssl.handshake t.ssl in
  match rc with
  | Openssl.Handshake_ok ->
      drain_bio t;
      t.handshake_done <- true
  | Openssl.Handshake_error code -> (
      drain_bio t;
      if code = 2 (* SSL_ERROR_WANT_READ *) then (
        feed_bio t;
        do_handshake t
      ) else if code = 3 (* SSL_ERROR_WANT_WRITE *) then (
        drain_bio t;
        do_handshake t
      ) else (
        match Openssl.err_peek_error () with
        | Some msg -> Openssl.err_clear_error (); failwith ("TLS handshake: " ^ msg)
        | None -> failwith ("TLS handshake failed (code " ^ string_of_int code ^ ")")
      )
    )

let close t =
  if not t.closed then (
    let _ = with_ssl t (fun () -> Openssl.shutdown t.ssl) in
    drain_bio t;
    t.closed <- true
  )

module Flow_impl = struct
  type nonrec t = t

  let read_methods = []

  let single_read t buf =
    if t.closed then raise End_of_file;
    if not t.handshake_done then do_handshake t;
    let { Cstruct.off; Cstruct.len } = buf in
    let storage = Cstruct.to_bigarray buf in
    let rec loop () =
      let rc = with_ssl t (fun () -> Openssl.read t.ssl storage 0 len) in
      if rc > 0 then (
        debug_io "read" storage ~storage_off:0 ~display_off:off ~len:rc;
        rc)
      else if rc = 0 then raise End_of_file
      else (
        let code = -rc in
        drain_bio t;
        if code = 2 (* SSL_ERROR_WANT_READ *) then (
          feed_bio t;
          loop ())
        else if code = 3 (* SSL_ERROR_WANT_WRITE *) then (
          drain_bio t;
          loop ())
        else if code = 6 (* SSL_ERROR_ZERO_RETURN *) then raise End_of_file
        else (
          match Openssl.err_peek_error () with
          | Some msg -> Openssl.err_clear_error (); failwith ("TLS read: " ^ msg)
          | None ->
              failwith ("TLS read failed (code " ^ string_of_int code ^ ")")))
    in
    loop ()

  let single_write t bufs =
    if t.closed then 0
    else (
      if not t.handshake_done then do_handshake t;
      let total = ref 0 in
      List.iter
        (fun buf ->
          let { Cstruct.off; Cstruct.len } = buf in
          let storage = Cstruct.to_bigarray buf in
          let rec write_buf offset length =
            if length > 0 then (
              let rc =
                with_ssl t (fun () -> Openssl.write t.ssl storage offset length)
              in
              if rc > 0 then (
                debug_io "write" storage ~storage_off:offset
                  ~display_off:(off + offset) ~len:rc;
                total := !total + rc;
                drain_bio t;
                if rc < length then write_buf (offset + rc) (length - rc))
              else (
                let code = -rc in
                drain_bio t;
                if code = 2 (* SSL_ERROR_WANT_READ *) then (
                  feed_bio t;
                  write_buf offset length)
                else if code = 3 (* SSL_ERROR_WANT_WRITE *) then (
                  drain_bio t;
                  write_buf offset length)
                else if code = 6 (* SSL_ERROR_ZERO_RETURN *) then raise End_of_file
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
    | `Send -> close t
    | `Receive | `All -> ()
end

let ops =
  Eio.Resource.handler (
    Eio.Resource.H (Tls_state, (fun t -> St t))
    :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Flow_impl))
    @ [ Eio.Resource.H (Eio.Resource.Close, close) ]
  )

let client_of_flow (config : config) ?host (flow : [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t) : flow =
  let hostname =
    match host with
    | Some h -> Some (Domain_name.to_string h)
    | None -> Option.map Domain_name.to_string (Config.peer_name config)
  in
  let ctx = Openssl.create_ctx () in
  (match Config.ca_file config with
   | Some path -> Openssl.ctx_load_ca ctx path
   | None -> ());
  let ssl = Openssl.create_ssl ctx ~hostname ~alpn_protocols:(Config.alpn_protocols config) in
  let t =
    {
      ssl;
      flow;
      ssl_mutex = Eio.Mutex.create ();
      read_mutex = Eio.Mutex.create ();
      write_mutex = Eio.Mutex.create ();
      handshake_done = false;
      closed = false;
    }
  in
  do_handshake t;
  let verify = Openssl.get_verify_result ssl in
  if verify <> 0 then
    failwith ("TLS certificate verification failed (code " ^ string_of_int verify ^ ")");
  (match Sys.getenv_opt "ETA_TLS_DEBUG" with
   | Some _ ->
       Printf.eprintf "[tls_eio] handshake done, alpn=%s\n%!"
         (match Openssl.get_alpn_selected ssl with Some p -> p | None -> "<none>")
   | None -> ());
  (Eio.Resource.T (t, ops) :> flow)

let epoch flow =
  try
    let (Eio.Resource.T (t, handler)) = flow in
    let St t = Eio.Resource.get handler Tls_state t in
    if not t.handshake_done then Error ()
    else Ok { alpn_protocol = Openssl.get_alpn_selected t.ssl }
  with _ -> Error ()

let alpn_protocol flow =
  match epoch flow with
  | Ok e -> e.alpn_protocol
  | Error () -> None
