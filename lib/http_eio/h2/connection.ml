(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Error = Error
module Multiplexer = Multiplexer
module Writer = Writer

module H2 = Eta_http_h2

(* Connection owns socket lifetime, writes, and failure fan-out. Multiplexer
   owns H2 stream admission and body-reader bookkeeping. The core H2 state
   machine owns frame parsing and serialization; this module only moves bytes
   between that state machine and the Eio flow. *)

type flow = Connect.tcp_flow

type failure_waiter = {
  mutable active : bool;
  notify : (Error.kind -> unit);
}

type t = {
  sw : Eio.Switch.t;
  mux : Multiplexer.t;
  client : H2.Connection.t;
  reader : Multiplexer.client_reader;
  flow : flow;
  mutex : Eio.Mutex.t;
  mutable closed : bool;
  mutable failure : Error.kind option;
  mutable failure_waiters : failure_waiter list;
  mutable wake_writer : (unit -> unit) option;
  on_close : (unit -> unit);
}

let close_kind = Error.Connection_closed { during = Error.Http_response }

let pp_client_error (error : H2.Connection.error) =
  Format.asprintf "protocol_error:%a:%s" H2.Error_code.pp_hum error.error_code
    error.message

let with_lock t (f) =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let notify_close_once t =
  let should_notify =
    with_lock t (fun () ->
        if t.closed then false
        else (
          t.closed <- true;
          true))
  in
  if should_notify then t.on_close ()

let set_failure t kind =
  let waiters =
    with_lock t (fun () ->
        let first = Option.is_none t.failure in
        if first then t.failure <- Some kind;
        let waiters = t.failure_waiters in
        t.failure_waiters <- [];
        if first then waiters else [])
  in
  List.iter
    (fun waiter ->
      if waiter.active then try waiter.notify kind with _ -> ())
    waiters

let shutdown t =
  notify_close_once t;
  set_failure t close_kind;
  (match with_lock t (fun () -> t.wake_writer) with
  | Some wake -> wake ()
  | None -> ());
  Multiplexer.shutdown t.mux;
  (try Eio.Flow.shutdown t.flow `All with _ -> ());
  (try Eio.Flow.close t.flow with _ -> ())

let fail_connection t kind =
  set_failure t kind;
  shutdown t

let write_iovecs flow iovecs =
  Writer.write_iovecs ~flow iovecs

let transport_closed t =
  with_lock t (fun () -> t.closed || H2.Connection.is_closed t.client)

let rec writer_loop t =
  try
    if not (transport_closed t) then
      match H2.Connection.next_write_operation t.client with
      | Write iovecs ->
          let written = write_iovecs t.flow iovecs in
          H2.Connection.report_write_result t.client (`Ok written);
          writer_loop t
      | Yield ->
          let promise, resolver = Eio.Promise.create () in
          with_lock t (fun () ->
              t.wake_writer <-
                Some (fun () -> ignore (Eio.Promise.try_resolve resolver ())));
          H2.Connection.yield_writer t.client (fun () ->
              ignore (Eio.Promise.try_resolve resolver ()));
          Eio.Promise.await promise;
          with_lock t (fun () -> t.wake_writer <- None);
          writer_loop t
      | Close _ ->
          H2.Connection.report_write_result t.client `Closed;
          shutdown t
  with exn ->
    shutdown t

and reader_loop ~security_error_handler t =
  if not (transport_closed t) then
    match Multiplexer.read_client_once ~flow:t.flow t.reader with
    | Read _ -> reader_loop ~security_error_handler t
    | Security_error kind ->
        security_error_handler kind;
        fail_connection t kind
    | Eof _ | Close -> shutdown t

and is_closed t =
  with_lock t (fun () -> t.closed || not (H2.Connection.accepts_new_streams t.client))

let run_owner_loop ?(on_error = fun _ -> ()) loop t =
  try loop t
  with
  | End_of_file -> shutdown t
  | Eio.Cancel.Cancelled _ -> shutdown t
  | exn ->
      let kind =
        Error.Connection_protocol_violation
          { kind = "h2_owner_loop"; message = Printexc.to_string exn }
      in
      on_error kind;
      fail_connection t kind

let create ~sw ~flow ~now_ms ?max_concurrent ?config
    ?(error_handler = fun _ -> ())
    ?(security_error_handler = fun _ -> ()) ?(on_close = fun () -> ())
    ?(reader_buffer_size = 64 * 1024) () =
  let holder = ref None in
  let security = Security.create () in
  let mux =
    Multiplexer.create ?max_concurrent ?config
      ~security ~error_handler:(fun error ->
        error_handler error;
        match !holder with
        | None -> ()
        | Some t ->
            fail_connection t
              (Error.Connection_protocol_violation
                 {
                   kind = "h2_connection";
                   message = pp_client_error error;
                 }))
      ()
  in
  let client = Multiplexer.client_connection mux in
  let t =
    {
      sw;
      mux;
      client;
      reader =
        Multiplexer.create_reader ~now_ms ~buffer_size:reader_buffer_size mux;
      flow;
      mutex = Eio.Mutex.create ();
      closed = false;
      failure = None;
      failure_waiters = [];
      wake_writer = None;
      on_close;
    }
  in
  holder := Some t;
  Eio.Fiber.fork_daemon ~sw (fun () ->
      run_owner_loop writer_loop t;
      `Stop_daemon);
  Eio.Fiber.fork_daemon ~sw (fun () ->
      run_owner_loop ~on_error:security_error_handler
        (reader_loop ~security_error_handler)
        t;
      `Stop_daemon);
  t

let request t ~tag ?trailers_handler request ~error_handler ~response_handler =
  match with_lock t (fun () -> (t.closed, t.failure)) with
  | true, _ | _, Some _ -> Error Multiplexer.Connection_closed
  | false, None ->
      Multiplexer.request t.mux ~tag ?trailers_handler request ~error_handler
        ~response_handler

let register_failure_handler t notify =
  let waiter = { active = true; notify } in
  let immediate =
    with_lock t (fun () ->
        match t.failure with
        | Some kind -> Some kind
        | None ->
            t.failure_waiters <- waiter :: t.failure_waiters;
            None)
  in
  (match immediate with Some kind -> notify kind | None -> ());
  fun () -> waiter.active <- false

let mux t = t.mux
let client t = t.client
let stats t = Multiplexer.stats t.mux

let fork_daemon t f =
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      f ();
      `Stop_daemon)
