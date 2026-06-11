(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type shutdown = Server_types.shutdown =
  | Graceful of Eta.Duration.t
  | Immediate

type domain_policy = Server_types.domain_policy =
  | Single_domain
  | Recommended
  | Additional of int

type runtime_factory = Server_types.runtime_factory

module Connection_info = Server_types.Connection_info
module Config = Server_types.Config
module Stats = Server_types.Stats

type t = {
  stop : unit Eio.Promise.t;
  stop_resolver : unit Eio.Promise.u;
  mutex : Eio.Mutex.t;
  mutable connections : H2_server_connection.t list;
  mutable opened_connections : int;
  mutable closed_connections : int;
}

let default_runtime_factory ~clock ~sw ~connection:_ () =
  Eta_eio.Runtime.create ~sw ~clock ()

let additional_domains domain_policy domain_manager =
  match (domain_policy, domain_manager) with
  | Single_domain, _ | _, None -> None
  | Recommended, Some dm ->
      Some (dm, max 0 (Domain.recommended_domain_count () - 1))
  | Additional n, Some dm -> Some (dm, max 0 n)

let create () =
  let stop, stop_resolver = Eio.Promise.create () in
  {
    stop;
    stop_resolver;
    mutex = Eio.Mutex.create ();
    connections = [];
    opened_connections = 0;
    closed_connections = 0;
  }

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let register_connection t connection =
  with_lock t (fun () ->
      t.opened_connections <- t.opened_connections + 1;
      t.connections <- connection :: t.connections)

let unregister_connection t connection =
  with_lock t (fun () ->
      let before = List.length t.connections in
      t.connections <-
        List.filter (fun current -> not (current == connection)) t.connections;
      if List.length t.connections <> before then
        t.closed_connections <- t.closed_connections + 1)

let connections t = with_lock t (fun () -> t.connections)

let stats t =
  with_lock t (fun () ->
      {
        Stats.active_connections = List.length t.connections;
        opened_connections = t.opened_connections;
        closed_connections = t.closed_connections;
      })

let shutdown t policy =
  List.iter
    (fun connection -> H2_server_connection.shutdown connection policy)
    (connections t);
  ignore (Eio.Promise.try_resolve t.stop_resolver ())

let run_h2c_on_socket_impl ~(sw : Eio.Switch.t) ~clock ?stop
    ?(config = Config.default) ?runtime_factory ?on_connection_start
    ?on_connection_close ~(socket : _ Eio.Net.listening_socket) handler =
  ignore sw;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop
    ~max_connections:config.max_connections
    ~on_error:(fun _exn -> ())
    (fun flow peer ->
      Eio.Switch.run @@ fun conn_sw ->
      let connection = ref None in
      let on_start current =
        connection := Some current;
        Option.iter (fun on_connection_start -> on_connection_start current)
          on_connection_start
      in
      let on_close stats =
        match !connection with
        | None -> ()
        | Some current ->
            Option.iter
              (fun on_connection_close -> on_connection_close current stats)
              on_connection_close
      in
      H2_server_connection.run_h2c ~sw:conn_sw ~clock
        ~flow:(flow :> H2_server_connection.flow)
        ~peer ~config ~runtime_factory ~on_start ~on_close handler)
  in
  ()

let run_h2c_on_socket ~(sw : Eio.Switch.t) ~clock ?stop
    ?(config = Config.default) ?runtime_factory ?on_connection_close
    ~(socket : _ Eio.Net.listening_socket) handler =
  let on_connection_close =
    Option.map (fun on_connection_close _connection stats ->
        on_connection_close stats)
      on_connection_close
  in
  run_h2c_on_socket_impl ~sw ~clock ?stop ~config ?runtime_factory
    ?on_connection_close ~socket handler

let run_h2c_impl ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_connection_start ?on_connection_close ~addr handler =
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:config.backlog net addr
  in
  let additional_domains = additional_domains domain_policy domain_manager in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop ?additional_domains
      ~max_connections:config.max_connections
    ~on_error:(fun _exn -> ())
    (fun flow peer ->
      Eio.Switch.run @@ fun conn_sw ->
      let connection = ref None in
      let on_start current =
        connection := Some current;
        Option.iter (fun on_connection_start -> on_connection_start current)
          on_connection_start
      in
      let on_close stats =
        match !connection with
        | None -> ()
        | Some current ->
            Option.iter
              (fun on_connection_close -> on_connection_close current stats)
              on_connection_close
      in
      H2_server_connection.run_h2c ~sw:conn_sw ~clock
        ~flow:(flow :> H2_server_connection.flow)
        ~peer ~config ~runtime_factory ~on_start ~on_close handler)
  in
  ()

let run_h2c ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_connection_close ~addr handler =
  let on_connection_close =
    Option.map (fun on_connection_close _connection stats ->
        on_connection_close stats)
      on_connection_close
  in
  run_h2c_impl ~sw ~net ~clock ?domain_manager ~domain_policy ?stop ~config
    ?runtime_factory ?on_connection_close ~addr handler

let tracked_on_close t on_connection_close connection stats =
  unregister_connection t connection;
  Option.iter (fun on_connection_close -> on_connection_close stats)
    on_connection_close

let start_h2c_on_socket ~sw ~clock ?(config = Config.default) ?runtime_factory
    ?on_connection_close ~socket handler =
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_h2c_on_socket_impl ~sw ~clock ~stop:t.stop ~config ?runtime_factory
        ~on_connection_start:(register_connection t)
        ~on_connection_close:(tracked_on_close t on_connection_close)
        ~socket handler);
  t

let start_h2c ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?(config = Config.default) ?runtime_factory
    ?on_connection_close ~addr handler =
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_h2c_impl ~sw ~net ~clock ?domain_manager ~domain_policy ~stop:t.stop
        ~config ?runtime_factory ~on_connection_start:(register_connection t)
        ~on_connection_close:(tracked_on_close t on_connection_close)
        ~addr handler);
  t
