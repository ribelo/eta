module Effect = Eta.Effect
module Syntax = Eta.Syntax

module Http = struct
  module Error = struct
    type kind = Bad_request of { message : string }

    type t = {
      method_ : string;
      target : string;
      kind : kind;
    }

    let make ~method_ ~target kind = { method_; target; kind }
  end

  module Response = struct
    type t = { status : int; body : string }

    let text ?(status = 200) body = { status; body }
  end

  module Body = struct
    type t = unit -> (bytes, Error.t) Effect.t

    let read_all body = body ()
  end

  module Request = struct
    type t = {
      method_ : string;
      target : string;
      path : string;
      body : Body.t;
    }
  end

  type handler = Request.t -> (Response.t, Error.t) Effect.t

  module Handler = struct
    let of_effect handler = handler
    let of_sync handler request = Effect.sync (fun () -> handler request)

    let of_result handler request =
      Effect.sync_result (fun () -> handler request)

    let route_not_found _request =
      Effect.pure (Response.text ~status:404 "not found\n")
  end
end

module Stream = struct
  type ('a, 'err) t = unit -> (unit, 'err) Effect.t

  let map_effect (_f : 'a -> ('b, 'err) Effect.t) (stream : ('a, 'err) t) :
      ('b, 'err) t =
    stream
end

module Domain = struct
  type user = { id : string; name : string }
  type db = { label : string }
  type clock = { now_ms : unit -> int }

  type error =
    [ `Bad_args of string
    | `Decode_failed of string
    | `Db_down
    | `Http of Http.Error.t
    | `Network
    | `Not_found of string ]

  let open_db () = Ok { label = "main" }
  let close_db _db = Ok ()

  let load_user db id =
    if String.equal id "" then Error (`Not_found id)
    else Ok { id; name = db.label ^ ":" ^ id }

  let load_user_at clock db id =
    if String.equal id "" then Error (`Not_found id)
    else Ok { id; name = db.label ^ ":" ^ id ^ "@" ^ string_of_int (clock.now_ms ()) }

  let parse_id raw =
    if String.equal raw "" then Error (`Bad_args "empty id") else Ok raw

  let decode_bytes bytes =
    let value = Bytes.to_string bytes in
    if String.equal value "" then Error (`Decode_failed "empty chunk")
    else Ok value

  let external_call path =
    if String.equal path "/retry" then Error `Network else Ok ("response:" ^ path)

  let render_user user = user.id ^ ":" ^ user.name
end

type shared_stats = {
  shared_processed : int;
  shared_bytes : int;
  shared_max_batch : int;
}

let update_shared_stats current batch =
  {
    shared_processed = current.shared_processed + 1;
    shared_bytes = current.shared_bytes + batch;
    shared_max_batch = max current.shared_max_batch batch;
  }

let effect_of_result_thunk f =
  Effect.sync_result f

let acquire_current =
  effect_of_result_thunk Domain.open_db

let release_current db =
  effect_of_result_thunk (fun () -> Domain.close_db db)

let load_user_current id =
  Effect.with_scope
    (Effect.acquire_release ~acquire:acquire_current ~release:release_current
    |> Effect.bind (fun db ->
           effect_of_result_thunk (fun () -> Domain.load_user db id)))

let load_user_proposed id =
  let open Syntax in
  let@ db =
    Effect.with_resource ~acquire:acquire_current ~release:release_current
  in
  Effect.sync_result (fun () -> Domain.load_user db id)

let scoped_resource_current left right =
  Effect.with_scope
    (Effect.acquire_release ~acquire:acquire_current ~release:release_current
    |> Effect.bind (fun db ->
           Effect.par
             (effect_of_result_thunk (fun () -> Domain.load_user db left))
             (effect_of_result_thunk (fun () -> Domain.load_user db right))))

let scoped_resource_proposed left right =
  let open Syntax in
  Effect.with_scope
    (let* db =
       Effect.acquire_release ~acquire:acquire_current
         ~release:release_current
     in
     let load id =
       Effect.sync_result (fun () -> Domain.load_user db id)
     in
     Effect.par (load left) (load right))

type service_value =
  | Clock of Domain.clock
  | Db of Domain.db

let service_current env id =
  match (List.assoc_opt "clock" env, List.assoc_opt "db" env) with
  | Some (Clock clock), Some (Db db) ->
      effect_of_result_thunk (fun () -> Domain.load_user_at clock db id)
  | Some _, Some _ -> Effect.fail (`Bad_args "service type mismatch")
  | Some _, None | None, Some _ | None, None ->
      Effect.fail (`Bad_args "missing service")

let service_proposed clock db id =
  Effect.sync_result (fun () -> Domain.load_user_at clock db id)

let catch_recovery_current body_as_result fallback =
  body_as_result
  |> Effect.bind (function
       | Ok value -> Effect.pure value
       | Error `Cache_miss -> fallback)

let catch_recovery_proposed body fallback =
  body |> Effect.bind_error (function `Cache_miss -> fallback)

let pure_recovery_current render_error body =
  body |> Effect.bind_error (fun err -> Effect.pure (render_error err))

let pure_recovery_proposed render_error body =
  body |> Effect.fold ~ok:Fun.id ~error:render_error

let best_effort_current cleanup =
  cleanup |> Effect.bind_error (fun _ -> Effect.unit)

let best_effort_proposed cleanup =
  cleanup |> Effect.ignore_errors

let typed_failure_result_current body =
  body
  |> Effect.map (fun value -> Ok value)
  |> Effect.fold ~ok:Fun.id ~error:(fun err -> Error err)

let typed_failure_result_proposed body =
  body |> Effect.to_result

let validation_boundary_current parse raw =
  effect_of_result_thunk (fun () -> parse raw)

let validation_boundary_proposed parse raw =
  Effect.from_result (parse raw)

let sync_defect_current read_config =
  effect_of_result_thunk (fun () ->
      try Ok (read_config ()) with Failure message -> Error (`Bug message))

let sync_defect_proposed read_config =
  Effect.sync read_config

let retrying_call_current path =
  effect_of_result_thunk (fun () -> Domain.external_call path)
  |> Effect.retry ~schedule:(Eta.Schedule.recurs 3) ~while_:(function
       | `Network -> true
       | _ -> false)

let retrying_call_proposed path =
  Effect.sync_result (fun () -> Domain.external_call path)
  |> Effect.retry ~schedule:(Eta.Schedule.recurs 3) ~while_:(function
       | `Network -> true
       | _ -> false)

let timeout_policy_current budget on_timeout body =
  Effect.race [ body; Effect.delay budget (Effect.fail on_timeout) ]

let timeout_policy_proposed budget on_timeout body =
  Effect.timeout_as budget ~on_timeout body

let uninterruptible_commit_current critical fallback =
  Effect.race [ critical; fallback ]

let uninterruptible_commit_proposed critical fallback =
  Effect.race [ Effect.uninterruptible critical; fallback ]

let cooperative_yield_current host_yield =
  Effect.sync host_yield

let cooperative_yield_proposed () =
  Effect.yield

let schedule_retry_current next_delay retryable call =
  let rec loop remaining =
    Effect.sync call
    |> Effect.bind Effect.from_result
    |> Effect.bind_error (fun err ->
           if remaining > 0 && retryable err then
             Effect.delay (next_delay remaining) (loop (remaining - 1))
           else Effect.fail err)
  in
  loop 3

let schedule_retry_proposed policy retryable call =
  Effect.sync_result call
  |> Effect.retry ~schedule:policy ~while_:retryable

let repeat_heartbeat_current policy tick =
  let rec loop driver =
    tick
    |> Effect.bind (fun () ->
           match Eta.Schedule.next ~now_ms:0 ~input:() driver with
           | None -> Effect.unit
           | Some (metadata, driver) -> Effect.delay metadata.delay (loop driver))
  in
  loop (Eta.Schedule.start policy)

let repeat_heartbeat_proposed policy tick =
  Effect.repeat ~schedule:policy tick

let stream_current chunks =
  chunks
  |> Stream.map_effect (fun bytes ->
         effect_of_result_thunk (fun () -> Domain.decode_bytes bytes))

let stream_proposed chunks =
  chunks
  |> Stream.map_effect (fun bytes ->
         Effect.sync_result (fun () -> Domain.decode_bytes bytes))

let http_handler_current (request : Http.Request.t) =
  match request.path with
  | "/" -> Effect.pure (Http.Response.text "ok\n")
  | "/echo" ->
      Http.Body.read_all request.body
      |> Effect.map (fun body -> Http.Response.text (Bytes.to_string body))
  | _ -> Http.Handler.route_not_found request

let http_handler_proposed =
  Http.Handler.of_sync (fun (request : Http.Request.t) ->
      match request.path with
      | "/" -> Http.Response.text "ok\n"
      | _ -> Http.Response.text ~status:404 "not found\n")

let http_handler_result_proposed =
  Http.Handler.of_result (fun (request : Http.Request.t) ->
      match request.path with
      | "/user" -> Ok (Http.Response.text "user\n")
      | _ ->
          Error
            (Http.Error.make ~method_:request.method_ ~target:request.target
               (Http.Error.Bad_request { message = "unsupported path" })))

let test_program_current raw =
  Effect.from_result (Domain.parse_id raw)
  |> Effect.bind (fun id -> load_user_current id)
  |> Effect.map Domain.render_user

let test_program_proposed raw =
  let open Syntax in
  let* id = Effect.from_result (Domain.parse_id raw) in
  let* user = load_user_proposed id in
  Effect.pure (Domain.render_user user)

let cli_current args =
  let raw = match args with id :: _ -> id | [] -> "" in
  Effect.from_result (Domain.parse_id raw)
  |> Effect.bind (fun id ->
         retrying_call_current ("/users/" ^ id)
         |> Effect.map (fun payload -> "ok " ^ payload))

let cli_proposed args =
  let open Syntax in
  let raw = match args with id :: _ -> id | [] -> "" in
  let* id = Effect.from_result (Domain.parse_id raw) in
  let* payload = retrying_call_proposed ("/users/" ^ id) in
  Effect.pure ("ok " ^ payload)

let parallel_business_proposed left right =
  Effect.par
    (Effect.from_result (Domain.parse_id left))
    (Effect.from_result (Domain.parse_id right))

let blocking_current path =
  Eta_blocking.run ~name:"fs.read" (fun () -> Domain.external_call path)
  |> Effect.bind Effect.from_result

let blocking_proposed path =
  Eta_blocking.run_result ~name:"fs.read" (fun () -> Domain.external_call path)

let supervisor_current record_failure failure_count =
  Effect.with_background
    (Effect.fail `Refresh_failed
    |> Effect.bind_error (fun err -> Effect.sync (fun () -> record_failure err)))
    (fun () -> Effect.sync failure_count)

let supervisor_proposed () =
  Eta.Supervisor.scoped
    {
      run =
        (fun sup ->
          let open Eta.Supervisor.Scope in
          let* _child = start sup (fail `Refresh_failed) in
          let* () = yield in
          let* failures = failures sup in
          pure (List.length failures));
    }

let observability_current id =
  Effect.named "request"
    (Effect.log "request.started"
    |> Effect.bind (fun () ->
           Effect.metric_update ~name:"requests"
             ~kind:(Eta.Capabilities.Counter { monotonic = true })
             (Eta.Capabilities.Number (Eta.Capabilities.Int 1))
           |> Effect.bind (fun () ->
                  load_user_proposed id
                  |> Effect.with_result_attrs
                       ~ok_attrs:(fun user ->
                         [ ("result", "ok"); ("user", user.Domain.id) ])
                       ~err_attrs:(function
                         | `Bad_args _ -> [ ("result", "bad-args") ]
                         | `Db_down -> [ ("result", "db-down") ]
                         | `Decode_failed _ -> [ ("result", "decode-failed") ]
                         | `Http _ -> [ ("result", "http") ]
                         | `Network -> [ ("result", "network") ]
                         | `Not_found _ -> [ ("result", "not-found") ]))))

let observability_proposed id =
  let open Syntax in
  Effect.named "request"
    (let* () = Effect.log "request.started" in
     let* () =
       Effect.metric_update ~name:"requests"
         ~kind:(Eta.Capabilities.Counter { monotonic = true })
         (Eta.Capabilities.Number (Eta.Capabilities.Int 1))
     in
     load_user_proposed id
     |> Effect.with_result_attrs
          ~ok_attrs:(fun user ->
            [ ("result", "ok"); ("user", user.Domain.id) ])
          ~err_attrs:(function
            | `Bad_args _ -> [ ("result", "bad-args") ]
            | `Db_down -> [ ("result", "db-down") ]
            | `Decode_failed _ -> [ ("result", "decode-failed") ]
            | `Http _ -> [ ("result", "http") ]
            | `Network -> [ ("result", "network") ]
            | `Not_found _ -> [ ("result", "not-found") ]))

type metric_stats = {
  metric_active : int;
  metric_idle : int;
  metric_waiting : int;
  metric_max_size : int;
}

let metric_updates_of_stats stats =
  [
    Effect.metric ~name:"pool.active" ~unit_:"{connection}"
      ~kind:Eta.Capabilities.Gauge
      (Eta.Capabilities.Number (Eta.Capabilities.Int stats.metric_active));
    Effect.metric ~name:"pool.idle" ~unit_:"{connection}"
      ~kind:Eta.Capabilities.Gauge
      (Eta.Capabilities.Number (Eta.Capabilities.Int stats.metric_idle));
    Effect.metric ~name:"pool.waiting" ~unit_:"{waiter}"
      ~kind:Eta.Capabilities.Gauge
      (Eta.Capabilities.Number (Eta.Capabilities.Int stats.metric_waiting));
    Effect.metric ~name:"pool.max_size" ~unit_:"{connection}"
      ~kind:Eta.Capabilities.Gauge
      (Eta.Capabilities.Number (Eta.Capabilities.Int stats.metric_max_size));
  ]

let metric_batch_current snapshot =
  let open Syntax in
  let* stats = Effect.sync snapshot in
  let* () =
    Effect.metric_update ~name:"pool.active" ~unit_:"{connection}"
      ~kind:Eta.Capabilities.Gauge
      (Eta.Capabilities.Number (Eta.Capabilities.Int stats.metric_active))
  in
  let* () =
    Effect.metric_update ~name:"pool.idle" ~unit_:"{connection}"
      ~kind:Eta.Capabilities.Gauge
      (Eta.Capabilities.Number (Eta.Capabilities.Int stats.metric_idle))
  in
  let* () =
    Effect.metric_update ~name:"pool.waiting" ~unit_:"{waiter}"
      ~kind:Eta.Capabilities.Gauge
      (Eta.Capabilities.Number (Eta.Capabilities.Int stats.metric_waiting))
  in
  Effect.metric_update ~name:"pool.max_size" ~unit_:"{connection}"
    ~kind:Eta.Capabilities.Gauge
    (Eta.Capabilities.Number (Eta.Capabilities.Int stats.metric_max_size))

let metric_batch_proposed snapshot =
  Effect.metric_updates_lazy (fun () ->
      snapshot () |> metric_updates_of_stats)

let observability_controls_current ~tracing_enabled ~expensive_attrs hidden =
  let attrs = if tracing_enabled then expensive_attrs () else [] in
  Effect.named "visible"
    (Effect.annotate_all attrs
       (hidden |> Effect.bind (fun () -> Effect.event "visible.done")))

let observability_controls_proposed expensive_attrs hidden =
  let open Syntax in
  Effect.named "visible"
    (let* tracing = Effect.is_tracing_enabled in
     let* () =
       Effect.annotate_all_lazy expensive_attrs
         (Effect.event "visible.done")
     in
     let* () = Effect.suppress_observability hidden in
     Effect.pure tracing)

let observability_sinks_proposed () =
  let tracer = Eta.Tracer.in_memory () in
  let logger = Eta.Logger.in_memory () in
  let meter = Eta.Meter.in_memory () in
  let _tracer_capability = Eta.Tracer.as_capability tracer in
  let _logger_capability = Eta.Logger.as_capability logger in
  let _meter_capability = Eta.Meter.as_capability meter in
  Eta.Tracer.retain_recent tracer ~max:1;
  (Eta.Tracer.dump tracer, Eta.Logger.dump logger, Eta.Meter.dump meter)

let daemon_drain_proposed rt work =
  ignore (Eta.Runtime.run rt (Effect.daemon work));
  Eta.Runtime.drain rt

let background_current heartbeat wait_started left right =
  Effect.with_background heartbeat (fun () ->
      wait_started
      |> Effect.bind (fun () ->
             Effect.par (load_user_proposed left) (load_user_proposed right)
             |> Effect.map (fun (left, right) ->
                    Domain.render_user left ^ "," ^ Domain.render_user right)))

let background_proposed heartbeat wait_started left right =
  let open Syntax in
  Effect.with_background heartbeat (fun () ->
      let* () = wait_started in
      Effect.par (load_user_proposed left) (load_user_proposed right)
      |> Effect.map (fun (left, right) ->
             Domain.render_user left ^ "," ^ Domain.render_user right))

let batch_current ids =
  let rec loop = function
    | [] -> Effect.pure []
    | id :: rest ->
        load_user_proposed id
        |> Effect.bind (fun user ->
               loop rest |> Effect.map (fun users -> user :: users))
  in
  loop ids

let batch_proposed ids probes =
  let open Syntax in
  let* users = Effect.map_par ~max_concurrent:2 load_user_proposed ids in
  let+ outcomes =
    probes |> List.map load_user_proposed |> Effect.all_settled
  in
  (users, outcomes)

let all_collect_current checks =
  let rec loop = function
    | [] -> Effect.pure []
    | check :: rest ->
        check
        |> Effect.bind (fun value ->
               loop rest |> Effect.map (fun values -> value :: values))
  in
  loop checks

let all_collect_proposed checks =
  Effect.all checks

let mirror_fetch path =
  Effect.sync_result (fun () -> Domain.external_call path)

let first_success outcomes =
  List.find_map
    (function
      | Ok payload -> Some payload
      | Error _ -> None)
    outcomes

let race_current paths =
  paths |> List.map mirror_fetch |> Effect.all_settled
  |> Effect.bind (fun outcomes ->
         match first_success outcomes with
         | Some payload -> Effect.pure payload
         | None -> Effect.fail `Network)

let race_proposed paths =
  paths |> List.map mirror_fetch |> Effect.race

let typed_error_current observe to_boundary raw =
  Effect.from_result (Domain.parse_id raw)
  |> Effect.bind (fun id -> load_user_proposed id)
  |> Effect.bind_error (fun err ->
         observe err;
         Effect.fail (to_boundary err))

let typed_error_proposed observe to_boundary raw =
  let open Syntax in
  (let* id = Effect.from_result (Domain.parse_id raw) in
   load_user_proposed id)
  |> Effect.tap_error (fun err -> Effect.sync (fun () -> observe err))
  |> Effect.map_error to_boundary

let admission_current sem abort body =
  let claimed = Atomic.make false in
  let release_claimed =
    Effect.sync (fun () ->
        if Atomic.compare_and_set claimed true false then
          Eta.Semaphore.release sem 1)
  in
  Effect.race
    [
      Eta.Semaphore.acquire sem 1
      |> Effect.map (fun () ->
             Atomic.set claimed true;
             true);
      abort |> Effect.map (fun _ -> false);
    ]
  |> Effect.bind (fun acquired ->
         if acquired then body () |> Effect.map Option.some else Effect.pure None)
  |> Effect.finally release_claimed

let admission_proposed sem abort body =
  Eta.Semaphore.with_permits_or_abort sem 1 ~abort body

let semaphore_permit_current sem body =
  Eta.Semaphore.acquire sem 1
  |> Effect.bind (fun () ->
         body ()
         |> Effect.finally
              (Effect.sync (fun () -> Eta.Semaphore.release sem 1)))

let semaphore_permit_proposed sem body =
  Eta.Semaphore.with_permits sem 1 body

let pool_current acquire release query =
  let idle = ref None in
  let sem = Eta.Semaphore.make ~permits:1 in
  let take_idle =
    Effect.sync (fun () ->
        match !idle with
        | None -> None
        | Some conn ->
            idle := None;
            Some conn)
  in
  let with_conn body =
    Eta.Semaphore.with_permits sem 1 (fun () ->
        let acquire =
          take_idle
          |> Effect.bind (function
               | Some conn -> Effect.pure conn
               | None -> acquire)
        in
        Effect.with_resource ~acquire
          ~release:(fun conn -> Effect.sync (fun () -> idle := Some conn))
          body)
  in
  let close_idle =
    take_idle
    |> Effect.bind (function
         | None -> Effect.unit
         | Some conn -> release conn)
  in
  (with_conn (fun conn -> query conn "first")
  |> Effect.bind (fun first ->
         with_conn (fun conn -> query conn "second")
         |> Effect.map (fun second -> (first, second))))
  |> Effect.finally close_idle

let pool_proposed acquire release query =
  let open Syntax in
  let* pool = Eta.Pool.create ~max_size:1 ~acquire ~release () in
  let* first = Eta.Pool.with_resource pool (fun conn -> query conn "first") in
  let* second = Eta.Pool.with_resource pool (fun conn -> query conn "second") in
  let before_shutdown = Eta.Pool.stats pool in
  let* () = Eta.Pool.shutdown pool in
  Effect.pure (first, second, before_shutdown)

let pubsub_current hub event closed_reason =
  Eta.Pubsub.subscribe hub (fun sub ->
      Eta.Pubsub.publish hub event
      |> Effect.bind (fun published ->
             Eta.Pubsub.recv sub
             |> Effect.bind (fun first ->
                    Eta.Pubsub.recv sub
                    |> Effect.bind_error closed_reason
                    |> Effect.map (fun closed -> (published, first, closed)))))

let pubsub_proposed hub event closed_reason =
  let open Syntax in
  let@ sub = Eta.Pubsub.subscribe hub in
  let* published = Eta.Pubsub.publish hub event in
  let* first = Eta.Pubsub.recv sub in
  let+ closed = Eta.Pubsub.recv sub |> Effect.bind_error closed_reason in
  (published, first, closed)

let pubsub_poll_current hub sub recover_closed =
  let stats = Eta.Pubsub.stats hub in
  if stats.depth = 0 || stats.subscribers = 0 then Effect.pure `Empty
  else
    Eta.Pubsub.recv sub
    |> Effect.map (fun item -> `Item item)
    |> Effect.bind_error recover_closed

let pubsub_poll_proposed sub =
  Eta.Pubsub.try_recv sub

let channel_current ch wait_blocked close_reason render_closed =
  let producer =
    Eta.Channel.send ch "first"
    |> Effect.bind (fun () ->
           Eta.Channel.send ch "second"
           |> Effect.bind (fun () ->
                  Effect.sync (fun () ->
                      Eta.Channel.close_with_error ch close_reason)))
  in
  Effect.with_background producer (fun () ->
      wait_blocked ch
      |> Effect.bind (fun () ->
             Eta.Channel.recv ch
             |> Effect.bind (fun first ->
                    Eta.Channel.recv ch
                    |> Effect.bind (fun second ->
                           Eta.Channel.recv ch
                           |> Effect.bind_error render_closed
                           |> Effect.map (fun closed -> (first, second, closed))))))

let channel_proposed ch wait_blocked close_reason render_closed =
  let open Syntax in
  let producer =
    let* () = Eta.Channel.send ch "first" in
    let* () = Eta.Channel.send ch "second" in
    Eta.Channel.close_with_error_effect ch close_reason
  in
  Effect.with_background producer (fun () ->
      let* () = wait_blocked ch in
      let* first = Eta.Channel.recv ch in
      let* second = Eta.Channel.recv ch in
      let+ closed = Eta.Channel.recv ch |> Effect.bind_error render_closed in
      (first, second, closed))

let channel_probe_current capacity ch value =
  let recover_send = function
    | `Closed -> Effect.pure `Closed
    | `Closed_with_error err -> Effect.pure (`Closed_with_error err)
  in
  let recover_recv = function
    | `Closed -> Effect.pure `Closed
    | `Closed_with_error err -> Effect.pure (`Closed_with_error err)
  in
  let send =
    let stats = Eta.Channel.stats ch in
    if stats.closed then Effect.pure `Closed
    else if stats.depth >= capacity then Effect.pure `Full
    else
      Eta.Channel.send ch value
      |> Effect.map (fun () -> `Sent)
      |> Effect.bind_error recover_send
  in
  let recv =
    if (Eta.Channel.stats ch).depth = 0 then Effect.pure `Empty
    else
      Eta.Channel.recv ch
      |> Effect.map (fun item -> `Item item)
      |> Effect.bind_error recover_recv
  in
  let open Syntax in
  let* sent = send in
  let+ received = recv in
  (sent, received)

let channel_probe_proposed ch value =
  let open Syntax in
  let* sent = Eta.Channel.try_send ch value in
  let+ received = Eta.Channel.try_recv ch in
  (sent, received)

let queue_current queue close_reason render_closed =
  Eta.Queue.send queue "first"
  |> Effect.bind (fun () ->
         Eta.Queue.send queue "second"
         |> Effect.bind (fun () ->
                Eta.Queue.send queue "third"
                |> Effect.bind (fun () ->
                       Effect.sync (fun () ->
                           Eta.Queue.close_with_error queue close_reason)
                       |> Effect.bind (fun () ->
                              Eta.Queue.take queue
                              |> Effect.bind (fun first ->
                                     Eta.Queue.take queue
                                     |> Effect.bind (fun second ->
                                            Eta.Queue.take queue
                                            |> Effect.bind (fun third ->
                                                   Eta.Queue.take queue
                                                   |> Effect.bind_error render_closed
                                                   |> Effect.map (fun closed ->
                                                          ( first,
                                                            second,
                                                            third,
                                                            closed )))))))))

let queue_proposed queue close_reason render_closed =
  let open Syntax in
  let* () = Eta.Queue.send queue "first" in
  let* () = Eta.Queue.send queue "second" in
  let* () = Eta.Queue.send queue "third" in
  let depth_after_send = (Eta.Queue.stats queue).Eta.Queue.depth in
  let* () = Eta.Queue.close_with_error_effect queue close_reason in
  let* first = Eta.Queue.take queue in
  let* second = Eta.Queue.take queue in
  let* third = Eta.Queue.take queue in
  let+ closed = Eta.Queue.take queue |> Effect.bind_error render_closed in
  (first, second, third, closed, depth_after_send)

let handoff_close_current ch queue hub reason =
  let open Syntax in
  let* () = Effect.sync (fun () -> Eta.Channel.close_with_error ch reason) in
  let* () = Effect.sync (fun () -> Eta.Queue.close_with_error queue reason) in
  Effect.sync (fun () -> Eta.Pubsub.close_with_error hub reason)

let handoff_close_proposed ch queue hub reason =
  let open Syntax in
  let* () = Eta.Channel.close_with_error_effect ch reason in
  let* () = Eta.Queue.close_with_error_effect queue reason in
  Eta.Pubsub.close_with_error_effect hub reason

let handoff_snapshot_current ch queue hub sem =
  let open Syntax in
  let* channel = Effect.sync (fun () -> Eta.Channel.stats ch) in
  let* queue_stats = Effect.sync (fun () -> Eta.Queue.stats queue) in
  let* pubsub = Effect.sync (fun () -> Eta.Pubsub.stats hub) in
  let+ available, waiting =
    Effect.sync (fun () -> (Eta.Semaphore.available sem, Eta.Semaphore.waiting sem))
  in
  ( channel.Eta.Channel.depth,
    queue_stats.Eta.Queue.depth,
    pubsub.Eta.Pubsub.subscribers,
    available,
    waiting )

let handoff_snapshot_proposed ch queue hub sem =
  let channel = Eta.Channel.stats ch in
  let queue_stats = Eta.Queue.stats queue in
  let pubsub = Eta.Pubsub.stats hub in
  let available = Eta.Semaphore.available sem in
  let waiting = Eta.Semaphore.waiting sem in
  Effect.pure
    ( channel.Eta.Channel.depth,
      queue_stats.Eta.Queue.depth,
      pubsub.Eta.Pubsub.subscribers,
      available,
      waiting )

let queue_probe_current queue value recover_send recover_recv =
  let send =
    if (Eta.Queue.stats queue).closed then Effect.pure `Closed
    else
      Eta.Queue.send queue value
      |> Effect.map (fun () -> `Sent)
      |> Effect.bind_error recover_send
  in
  let recv =
    let stats = Eta.Queue.stats queue in
    if stats.depth = 0 then
      if stats.closed then Effect.pure `Closed else Effect.pure `Empty
    else
      Eta.Queue.take queue
      |> Effect.map (fun item -> `Item item)
      |> Effect.bind_error recover_recv
  in
  let open Syntax in
  let* sent = send in
  let+ received = recv in
  (sent, received)

let queue_probe_proposed queue value =
  let open Syntax in
  let* sent = Eta.Queue.try_offer queue value in
  let+ received = Eta.Queue.poll queue in
  (sent, received)

let mutable_ref_current state batch =
  let rec update () =
    let current = Atomic.get state in
    let next = update_shared_stats current batch in
    if Atomic.compare_and_set state current next then next else update ()
  in
  Effect.sync update

let mutable_ref_proposed state batch =
  Effect.sync (fun () ->
      Eta.Mutable_ref.update_and_get state (fun current ->
          update_shared_stats current batch))

let random_current random =
  let span = 20 - 10 + 1 in
  let dice =
    10
    + int_of_float
        (Eta.Capabilities.random_float random (float_of_int span))
  in
  let ratio = 1.0 +. Eta.Capabilities.random_float random 2.0 in
  let coin = int_of_float (Eta.Capabilities.random_float random 2.0) = 1 in
  (dice, ratio, coin)

let random_proposed random =
  let dice = Eta.Random.int_in_range random ~min:10 ~max:20 in
  let ratio = Eta.Random.float_in_range random ~min:1.0 ~max:3.0 in
  let coin = Eta.Random.bool random in
  (dice, ratio, coin)

let random_collections_current random items weighted =
  let keyed =
    items
    |> List.map (fun item -> (Eta.Capabilities.random_float random 1.0, item))
  in
  let shuffled = keyed |> List.sort compare |> List.map snd in
  let sample =
    match items with
    | [] -> None
    | _ ->
        let index =
          int_of_float
            (Eta.Capabilities.random_float random
               (float_of_int (List.length items)))
        in
        Some (List.nth items index)
  in
  let total =
    List.fold_left
      (fun acc (_, weight) -> if weight > 0.0 then acc +. weight else acc)
      0.0 weighted
  in
  let weighted_choice =
    if total <= 0.0 then None
    else
      let target = Eta.Capabilities.random_float random total in
      let rec pick acc = function
        | [] -> None
        | (value, weight) :: rest ->
            if weight <= 0.0 then pick acc rest
            else
              let acc = acc +. weight in
              if target < acc then Some value else pick acc rest
      in
      pick 0.0 weighted
  in
  (shuffled, weighted_choice, sample)

let random_collections_proposed random items weighted =
  let shuffled = Eta.Random.shuffle random items in
  let weighted_choice = Eta.Random.weighted_choice random weighted in
  let sample = Eta.Random.sample random items in
  (shuffled, weighted_choice, sample)

let duration_current attempt =
  let base_ms = 125 in
  let raw = base_ms * (1 lsl attempt) in
  let scaled = int_of_float (float_of_int raw *. 1.5) in
  let clamped = min 2_000 (max 100 scaled) in
  let remaining = 5_000 - 250 in
  let io_budget = int_of_float (float_of_int remaining *. 0.5) in
  (clamped, io_budget)

let duration_proposed attempt =
  let retry =
    Eta.Duration.scale
      (Eta.Duration.times (Eta.Duration.ms 125) (1 lsl attempt))
      1.5
    |> Eta.Duration.clamp ~min:(Eta.Duration.ms 100)
         ~max:(Eta.Duration.seconds 2)
  in
  let io_budget =
    Eta.Duration.scale
      (Eta.Duration.subtract (Eta.Duration.seconds 5) (Eta.Duration.ms 250))
      0.5
  in
  (retry, io_budget)

let log_level_current threshold_raw level_raw =
  let rank = function
    | "TRACE" -> Some 1
    | "DEBUG" -> Some 2
    | "INFO" -> Some 3
    | "WARN" -> Some 4
    | "ERROR" -> Some 5
    | "FATAL" -> Some 6
    | "ALL" -> Some 0
    | "NONE" | "OFF" -> Some 7
    | _ -> None
  in
  match
    ( rank (String.uppercase_ascii threshold_raw),
      rank (String.uppercase_ascii level_raw) )
  with
  | Some 0, Some _ -> true
  | Some 7, Some _ | _, None | None, _ -> false
  | Some threshold, Some level -> level >= threshold

let log_level_proposed threshold_raw level_raw =
  match
    (Eta.Log_level.of_string threshold_raw, Eta.Log_level.of_string level_raw)
  with
  | Some threshold, Some at -> Eta.Log_level.is_enabled ~at ~threshold
  | _ -> false

let log_level_boundary_current level severity =
  let rendered = String.uppercase_ascii level in
  let otel =
    match rendered with
    | "TRACE" -> 1
    | "DEBUG" -> 5
    | "INFO" -> 9
    | "WARN" -> 13
    | "ERROR" -> 17
    | "FATAL" -> 21
    | _ -> 0
  in
  let from_otel =
    if severity <= 0 then "ALL"
    else if severity < 5 then "TRACE"
    else if severity < 9 then "DEBUG"
    else if severity < 13 then "INFO"
    else if severity < 17 then "WARN"
    else if severity < 21 then "ERROR"
    else "FATAL"
  in
  (rendered, otel, from_otel)

let log_level_boundary_proposed level severity =
  let rendered = Eta.Log_level.to_string level in
  let otel = Eta.Log_level.to_otel_severity level in
  let from_otel = Eta.Log_level.of_otel_severity severity in
  let display = Format.asprintf "%a" Eta.Log_level.pp from_otel in
  (rendered, otel, display)

let sampler_current trace_id parent_sampled =
  let bound = 1 lsl 30 in
  let hash = Hashtbl.hash trace_id land (bound - 1) in
  let root_sampled = float_of_int hash /. float_of_int bound < 0.5 in
  if parent_sampled then true else root_sampled

let sampler_proposed trace_id parent_sampled =
  let sampler =
    Eta.Sampler.parent_based ~root:(Eta.Sampler.ratio 0.5) ()
  in
  Eta.Sampler.sample sampler ~trace_id ~name:"request"
    ~attrs:[ ("route", "/users/:id") ]
    ~parent:parent_sampled

let trace_context_current headers body =
  match List.assoc_opt "traceparent" headers with
  | Some traceparent when String.length traceparent >= 55 ->
      let trace_id = String.sub traceparent 3 32 in
      let span_id = String.sub traceparent 36 16 in
      Effect.with_external_parent ~trace_id ~span_id body
  | _ -> body

let trace_context_proposed headers body =
  let open Syntax in
  let* ctx =
    Eta.Trace_context.extract headers
    |> Effect.from_option ~if_none:`Bad_trace_context
  in
  Effect.with_context ctx body

let trace_context_injection_current ctx =
  let flags = Printf.sprintf "%02x" ctx.Eta.Capabilities.trace_flags in
  let traceparent =
    "00-" ^ ctx.trace_id ^ "-" ^ ctx.span_id ^ "-" ^ flags
  in
  let tracestate =
    ctx.trace_state
    |> List.map (fun (key, value) -> key ^ "=" ^ value)
    |> String.concat ","
  in
  let baggage =
    ctx.baggage
    |> List.map (fun (key, value) -> key ^ "=" ^ value)
    |> String.concat ","
  in
  [ ("traceparent", traceparent); ("tracestate", tracestate); ("baggage", baggage) ]

let trace_context_injection_proposed () =
  let open Syntax in
  let* current = Effect.current_context in
  match current with
  | None -> Effect.fail `Missing_context
  | Some ctx -> Effect.pure (Eta.Trace_context.inject ctx)

let span_link_current published consume =
  Effect.named ~kind:Eta.Capabilities.Consumer "consume"
    (Effect.annotate_all
       [
         ("linked.trace_id", published.Eta.Capabilities.trace_id);
         ("linked.span_id", published.span_id);
       ]
       consume)

let span_link_proposed published consume =
  Effect.link_span ~trace_id:published.Eta.Capabilities.trace_id
    ~span_id:published.span_id
    (Effect.named ~kind:Eta.Capabilities.Consumer "consume" consume)

let exit_cause_current exit =
  match exit with
  | Eta.Exit.Ok value -> Some (Ok value)
  | Eta.Exit.Error (Eta.Cause.Fail err) -> Some (Error err)
  | Eta.Exit.Error
      ( Eta.Cause.Die _ | Eta.Cause.Interrupt _ | Eta.Cause.Sequential _
      | Eta.Cause.Concurrent _ | Eta.Cause.Finalizer _
      | Eta.Cause.Suppressed _ ) ->
      None

let exit_cause_proposed exit =
  Eta.Exit.to_result exit

let runtime_boundary_current rt eff =
  try Eta.Exit.Ok (Eta.Runtime.run_exn rt eff) with
  | Failure message ->
      Eta.Exit.Error (Eta.Cause.fail (`Runtime_raised message))

let runtime_boundary_proposed rt eff =
  Eta.Runtime.run rt eff

let cached_resource_current load schedule observe =
  let cache = ref None in
  let publish value = Effect.sync (fun () -> cache := Some value) in
  let refresh =
    load
    |> Effect.bind publish
    |> Effect.bind_error (fun err -> Effect.sync (fun () -> observe err))
  in
  load
  |> Effect.bind (fun initial ->
         publish initial
         |> Effect.bind (fun () ->
                Effect.with_background (Effect.repeat ~schedule:schedule refresh) (fun () ->
                    Effect.pure initial)))

let cached_resource_proposed load schedule observe =
  let open Syntax in
  let* resource = Eta.Resource.auto ~load ~schedule ~on_error:observe () in
  Eta.Resource.get resource

let resource_failures_current load schedule =
  let observed = ref [] in
  let observe err = observed := Eta.Cause.Fail err :: !observed in
  let open Syntax in
  let* resource = Eta.Resource.auto ~load ~schedule ~on_error:observe () in
  let* _value = Eta.Resource.get resource in
  Effect.sync (fun () -> List.rev !observed)

let resource_failures_proposed load schedule =
  let open Syntax in
  let* resource = Eta.Resource.auto ~load ~schedule () in
  let* _value = Eta.Resource.get resource in
  Eta.Resource.failures resource

let manual_resource_current load =
  let cache = ref None in
  let publish value = Effect.sync (fun () -> cache := Some value) in
  let get =
    Effect.sync (fun () -> !cache)
    |> Effect.bind (function
         | Some value -> Effect.pure value
         | None ->
             load
             |> Effect.bind (fun value ->
                    publish value |> Effect.map (fun () -> value)))
  in
  let refresh = load |> Effect.bind publish in
  refresh |> Effect.bind_error (fun _ -> Effect.unit) |> Effect.bind (fun () -> get)

let manual_resource_proposed load =
  let open Syntax in
  let* resource = Eta.Resource.manual load in
  let* () = Eta.Resource.refresh resource |> Effect.ignore_errors in
  Eta.Resource.get resource

let blueprint_names_current static_names dynamic_names =
  let registered = Hashtbl.create 8 in
  List.iter (fun name -> Hashtbl.replace registered name ()) static_names;
  List.iter (fun name -> Hashtbl.replace registered name ()) dynamic_names;
  Hashtbl.fold (fun name () acc -> name :: acc) registered []

let blueprint_names_proposed eff =
  (Effect.name eff, Effect.collect_names eff)

let source_location_current (file, line, col_start, col_end) name attrs body =
  let loc = Printf.sprintf "%s:%d:%d-%d" file line col_start col_end in
  Effect.named name
    (Effect.annotate ~key:"loc" ~value:loc (Effect.annotate_all attrs body))

let source_location_proposed attrs body =
  Effect.fn ~attrs __POS__ __FUNCTION__ body

let error_rendering_current name err =
  Effect.named name (Effect.fail err)

let error_rendering_proposed render_error name err =
  let pp fmt err = Format.pp_print_string fmt (render_error err) in
  Effect.with_error_pp pp (Effect.named name (Effect.fail err))

let tap_success_current audit body =
  body |> Effect.bind (fun value -> audit value |> Effect.map (fun () -> value))

let tap_success_proposed audit body =
  body |> Effect.tap audit

let sync_observer_current observe body =
  body |> Effect.bind (fun value ->
      Effect.sync (fun () -> observe value)
      |> Effect.map (fun () -> value))

let sync_observer_proposed observe body =
  body |> Effect.tap (fun value -> Effect.sync (fun () -> observe value))

let success_map_current project body =
  body |> Effect.bind (fun value -> Effect.pure (project value))

let success_map_proposed project body =
  let open Syntax in
  let+ value = body in
  project value

let finally_cleanup_current cleanup body =
  body
  |> Effect.bind_error (fun err ->
         cleanup |> Effect.bind (fun () -> Effect.fail err))
  |> Effect.bind (fun value -> cleanup |> Effect.map (fun () -> value))

let finally_cleanup_proposed cleanup body =
  Effect.finally cleanup body

type snippet = {
  area : string;
  variant : string;
  code : string;
}

let snippets =
  [
    {
      area = "resource";
      variant = "current";
      code =
        {|Effect.with_scope
  (Effect.acquire_release ~acquire ~release
   |> Effect.bind (fun db ->
        Effect.sync (fun () -> load_user db id)
        |> Effect.bind Effect.from_result))|};
    };
    {
      area = "resource";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let@ db = Effect.with_resource ~acquire ~release in
Effect.sync_result (fun () -> load_user db id)|};
    };
    {
      area = "cached_resource";
      variant = "current";
      code =
        {|let cache = ref None in
let publish value = Effect.sync (fun () -> cache := Some value) in
let refresh =
  load
  |> Effect.bind publish
  |> Effect.bind_error (fun err -> Effect.sync (fun () -> observe err))
in
load
|> Effect.bind (fun initial ->
     publish initial
     |> Effect.bind (fun () ->
          Effect.with_background (Effect.repeat ~schedule:schedule refresh) (fun () ->
            Effect.pure initial)))|};
    };
    {
      area = "cached_resource";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* resource = Resource.auto ~load ~schedule ~on_error:observe () in
Resource.get resource|};
    };
    {
      area = "resource_failures";
      variant = "current";
      code =
        {|let observed = ref [] in
let observe err = observed := Cause.Fail err :: !observed in
let open Eta.Syntax in
let* resource = Resource.auto ~load ~schedule ~on_error:observe () in
let* _value = Resource.get resource in
Effect.sync (fun () -> List.rev !observed)|};
    };
    {
      area = "resource_failures";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* resource = Resource.auto ~load ~schedule () in
let* _value = Resource.get resource in
Resource.failures resource|};
    };
    {
      area = "manual_resource";
      variant = "current";
      code =
        {|let cache = ref None in
let publish value = Effect.sync (fun () -> cache := Some value) in
let get =
  Effect.sync (fun () -> !cache)
  |> Effect.bind (function
       | Some value -> Effect.pure value
       | None ->
           load |> Effect.bind (fun value ->
             publish value |> Effect.map (fun () -> value)))
in
let refresh = load |> Effect.bind publish in
refresh |> Effect.bind_error (fun _ -> Effect.unit) |> Effect.bind (fun () -> get)|};
    };
    {
      area = "manual_resource";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* resource = Resource.manual load in
let* () = Resource.refresh resource |> Effect.ignore_errors in
Resource.get resource|};
    };
    {
      area = "scoped_resource";
      variant = "current";
      code =
        {|Effect.with_scope
  (Effect.acquire_release ~acquire ~release
   |> Effect.bind (fun session ->
        Effect.par (load session "config") (load session "profile")))|};
    };
    {
      area = "scoped_resource";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
Effect.with_scope
  (let* session = Effect.acquire_release ~acquire ~release in
   Effect.par (load session "config") (load session "profile"))|};
    };
    {
      area = "service";
      variant = "current";
      code =
        {|match (List.assoc_opt "clock" env, List.assoc_opt "db" env) with
| Some (Clock clock), Some (Db db) ->
    Effect.sync (fun () -> load_user_at clock db id)
    |> Effect.bind Effect.from_result
| Some _, Some _ -> Effect.fail (`Bad_args "service type mismatch")
| Some _, None | None, Some _ | None, None ->
    Effect.fail (`Bad_args "missing service")|};
    };
    {
      area = "service";
      variant = "proposed";
      code =
        {|Effect.sync_result (fun () -> load_user_at clock db id)|};
    };
    {
      area = "catch_recovery";
      variant = "current";
      code =
        {|body_as_result
|> Effect.bind (function
     | Ok value -> Effect.pure value
     | Error `Cache_miss -> fallback)|};
    };
    {
      area = "catch_recovery";
      variant = "proposed";
      code =
        {|body
|> Effect.bind_error (function
     | `Cache_miss -> fallback)|};
    };
    {
      area = "pure_recovery";
      variant = "current";
      code =
        {|load_user id
|> Effect.bind_error (fun err -> Effect.pure (render_error err))|};
    };
    {
      area = "pure_recovery";
      variant = "proposed";
      code = {|load_user id |> Effect.fold ~ok:Fun.id ~error:render_error|};
    };
    {
      area = "best_effort";
      variant = "current";
      code = {|cleanup |> Effect.bind_error (fun _ -> Effect.unit)|};
    };
    {
      area = "best_effort";
      variant = "proposed";
      code = {|cleanup |> Effect.ignore_errors|};
    };
    {
      area = "typed_failure_result";
      variant = "current";
      code =
        {|operation
|> Effect.map (fun value -> Ok value)
|> Effect.fold ~ok:Fun.id ~error:(fun err -> Error err)|};
    };
    {
      area = "typed_failure_result";
      variant = "proposed";
      code = {|operation |> Effect.to_result|};
    };
    {
      area = "validation_boundary";
      variant = "current";
      code =
        {|Effect.sync (fun () -> parse_id raw)
|> Effect.bind Effect.from_result|};
    };
    {
      area = "validation_boundary";
      variant = "proposed";
      code = {|Effect.from_result (parse_id raw)|};
    };
    {
      area = "sync_defect";
      variant = "current";
      code =
        {|Effect.sync (fun () ->
  try Ok (read_config ())
  with Failure message -> Error (`Bug message))
|> Effect.bind Effect.from_result|};
    };
    {
      area = "sync_defect";
      variant = "proposed";
      code = {|Effect.sync read_config|};
    };
    {
      area = "source_location";
      variant = "current";
      code =
        {|let loc = Printf.sprintf "%s:%d:%d-%d" file line col_start col_end in
Effect.named name
  (Effect.annotate ~key:"loc" ~value:loc
     (Effect.annotate_all attrs body))|};
    };
    {
      area = "source_location";
      variant = "proposed";
      code = {|Effect.fn ~attrs __POS__ __FUNCTION__ body|};
    };
    {
      area = "error_rendering";
      variant = "current";
      code = {|Effect.named "payment.charge" (Effect.fail (`Declined reason))|};
    };
    {
      area = "error_rendering";
      variant = "proposed";
      code =
        {|Effect.with_error_pp render_payment_error
  (Effect.named "payment.charge" (Effect.fail (`Declined reason)))|};
    };
    {
      area = "tap_success";
      variant = "current";
      code =
        {|load_user id
|> Effect.bind (fun user ->
     audit user |> Effect.map (fun () -> user))|};
    };
    {
      area = "tap_success";
      variant = "proposed";
      code = {|load_user id |> Effect.tap audit|};
    };
    {
      area = "sync_observer";
      variant = "current";
      code =
        {|load_user id
|> Effect.bind (fun user ->
     Effect.sync (fun () -> audit user)
     |> Effect.map (fun () -> user))|};
    };
    {
      area = "sync_observer";
      variant = "proposed";
      code =
        {|load_user id
|> Effect.tap (fun user -> Effect.sync (fun () -> audit user))|};
    };
    {
      area = "success_map";
      variant = "current";
      code =
        {|load_user id
|> Effect.bind (fun user ->
     Effect.pure (render_user user))|};
    };
    {
      area = "success_map";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let+ user = load_user id in
render_user user|};
    };
    {
      area = "finally_cleanup";
      variant = "current";
      code =
        {|body
|> Effect.bind_error (fun err ->
     cleanup |> Effect.bind (fun () -> Effect.fail err))
|> Effect.bind (fun value ->
     cleanup |> Effect.map (fun () -> value))|};
    };
    {
      area = "finally_cleanup";
      variant = "proposed";
      code = {|Effect.finally cleanup body|};
    };
    {
      area = "timeout_policy";
      variant = "current";
      code =
        {|Effect.race
  [ body;
    Effect.delay budget (Effect.fail `Request_timeout) ]|};
    };
    {
      area = "timeout_policy";
      variant = "proposed";
      code = {|body |> Effect.timeout_as budget ~on_timeout:`Request_timeout|};
    };
    {
      area = "uninterruptible_commit";
      variant = "current";
      code = {|Effect.race [ critical_commit; fast_response ]|};
    };
    {
      area = "uninterruptible_commit";
      variant = "proposed";
      code =
        {|Effect.race [ Effect.uninterruptible critical_commit; fast_response ]|};
    };
    {
      area = "cooperative_yield";
      variant = "current";
      code = {|Effect.sync Eio.Fiber.yield|};
    };
    {
      area = "cooperative_yield";
      variant = "proposed";
      code = {|Effect.yield|};
    };
    {
      area = "retry";
      variant = "current";
      code =
        {|Effect.sync (fun () -> external_call path)
|> Effect.bind Effect.from_result
|> Effect.retry ~schedule:policy ~while_:retryable|};
    };
    {
      area = "retry";
      variant = "proposed";
      code =
        {|Effect.sync_result (fun () -> external_call path)
|> Effect.retry ~schedule:policy ~while_:retryable|};
    };
    {
      area = "schedule_retry";
      variant = "current";
      code =
        {|let rec loop remaining =
  Effect.sync call
  |> Effect.bind Effect.from_result
  |> Effect.bind_error (fun err ->
       if remaining > 0 && retryable err then
         Effect.delay (next_delay remaining) (loop (remaining - 1))
       else Effect.fail err)
in
loop 3|};
    };
    {
      area = "schedule_retry";
      variant = "proposed";
      code =
        {|let policy =
  Schedule.(
    both (recurs 3) (exponential ~factor:2.0 (Duration.ms 10))
    |> jittered ~min:1.0 ~max:2.0)
in
Effect.sync_result call
|> Effect.retry ~schedule:policy ~while_:retryable|};
    };
    {
      area = "repeat_heartbeat";
      variant = "current";
      code =
        {|let rec loop driver =
  tick
  |> Effect.bind (fun () ->
       match Schedule.next ~now_ms:0 ~input:() driver with
       | None -> Effect.unit
       | Some (metadata, driver) -> Effect.delay metadata.delay (loop driver))
in
loop (Schedule.start policy)|};
    };
    {
      area = "repeat_heartbeat";
      variant = "proposed";
      code = {|Effect.repeat ~schedule:policy tick|};
    };
    {
      area = "stream";
      variant = "current";
      code =
        {|stream
|> Stream.map_effect (fun bytes ->
     Effect.sync (fun () -> decode bytes)
     |> Effect.bind Effect.from_result)|};
    };
    {
      area = "stream";
      variant = "proposed";
      code =
        {|stream
|> Stream.map_effect (fun bytes ->
     Effect.sync_result (fun () -> decode bytes))|};
    };
    {
      area = "batch";
      variant = "current";
      code =
        {|let rec loop = function
| [] -> Effect.pure []
| id :: rest ->
    load_user id
    |> Effect.bind (fun user ->
         loop rest |> Effect.map (fun users -> user :: users))|};
    };
    {
      area = "batch";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* users = Effect.map_par ~max_concurrent:2 load_user ids in
let+ outcomes =
  probes |> List.map load_user |> Effect.all_settled
in
(users, outcomes)|};
    };
    {
      area = "all_collect";
      variant = "current";
      code =
        {|let rec loop = function
| [] -> Effect.pure []
| check :: rest ->
    check
    |> Effect.bind (fun value ->
         loop rest |> Effect.map (fun values -> value :: values))
in
loop checks|};
    };
    {
      area = "all_collect";
      variant = "proposed";
      code = {|Effect.all checks|};
    };
    {
      area = "blueprint_names";
      variant = "current";
      code =
        {|let registered = Hashtbl.create 8 in
List.iter (fun name -> Hashtbl.replace registered name ()) static_names;
List.iter (fun name -> Hashtbl.replace registered name ()) dynamic_names;
Hashtbl.fold (fun name () acc -> name :: acc) registered []|};
    };
    {
      area = "blueprint_names";
      variant = "proposed";
      code =
        {|let top = Effect.name program in
let static = Effect.collect_names program in
(top, static)|};
    };
    {
      area = "channel";
      variant = "current";
      code =
        {|let producer =
  Channel.send ch "first"
  |> Effect.bind (fun () ->
       Channel.send ch "second"
       |> Effect.bind (fun () -> Effect.sync (fun () -> Channel.close_with_error ch reason)))
in
Effect.with_background producer (fun () ->
  wait_blocked ch
  |> Effect.bind (fun () ->
       Channel.recv ch
       |> Effect.bind (fun first ->
            Channel.recv ch
            |> Effect.bind (fun second ->
                 Channel.recv ch
                 |> Effect.bind_error render_closed
                 |> Effect.map (fun closed -> (first, second, closed))))))|};
    };
    {
      area = "channel";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let producer =
  let* () = Channel.send ch "first" in
  let* () = Channel.send ch "second" in
  Channel.close_with_error_effect ch reason
in
Effect.with_background producer (fun () ->
  let* () = wait_blocked ch in
  let* first = Channel.recv ch in
  let* second = Channel.recv ch in
  let+ closed = Channel.recv ch |> Effect.bind_error render_closed in
  (first, second, closed))|};
    };
    {
      area = "channel_probe";
      variant = "current";
      code =
        {|let stats = Channel.stats ch in
let send =
  if stats.closed then Effect.pure `Closed
  else if stats.depth >= capacity then Effect.pure `Full
  else
    Channel.send ch value
    |> Effect.map (fun () -> `Sent)
    |> Effect.bind_error recover_send
in
let recv =
  if (Channel.stats ch).depth = 0 then Effect.pure `Empty
  else
    Channel.recv ch
    |> Effect.map (fun item -> `Item item)
    |> Effect.bind_error recover_recv
in
let* sent = send in
let+ received = recv in
(sent, received)|};
    };
    {
      area = "channel_probe";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* sent = Channel.try_send ch value in
let+ received = Channel.try_recv ch in
(sent, received)|};
    };
    {
      area = "queue";
      variant = "current";
      code =
        {|Queue.send q "first"
|> Effect.bind (fun () ->
     Queue.send q "second"
     |> Effect.bind (fun () ->
          Queue.send q "third"
          |> Effect.bind (fun () ->
               Effect.sync (fun () -> Queue.close_with_error q reason)
               |> Effect.bind (fun () ->
                    Queue.take q
                    |> Effect.bind (fun first ->
                         Queue.take q
                         |> Effect.bind (fun second ->
                              Queue.take q
                              |> Effect.bind (fun third ->
                                   Queue.take q
                                   |> Effect.bind_error render_closed
                                   |> Effect.map (fun closed ->
                                        (first, second, third, closed))))))))|};
    };
    {
      area = "queue";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* () = Queue.send q "first" in
let* () = Queue.send q "second" in
let* () = Queue.send q "third" in
let depth_after_send = (Queue.stats q).Queue.depth in
let* () = Queue.close_with_error_effect q reason in
let* first = Queue.take q in
let* second = Queue.take q in
let* third = Queue.take q in
let+ closed = Queue.take q |> Effect.bind_error render_closed in
(first, second, third, closed, depth_after_send)|};
    };
    {
      area = "handoff_close";
      variant = "current";
      code =
        {|let open Eta.Syntax in
let* () = Effect.sync (fun () -> Channel.close_with_error ch reason) in
let* () = Effect.sync (fun () -> Queue.close_with_error q reason) in
Effect.sync (fun () -> Pubsub.close_with_error hub reason)|};
    };
    {
      area = "handoff_close";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* () = Channel.close_with_error_effect ch reason in
let* () = Queue.close_with_error_effect q reason in
Pubsub.close_with_error_effect hub reason|};
    };
    {
      area = "handoff_snapshot";
      variant = "current";
      code =
        {|let open Eta.Syntax in
let* channel = Effect.sync (fun () -> Channel.stats ch) in
let* queue = Effect.sync (fun () -> Queue.stats q) in
let* pubsub = Effect.sync (fun () -> Pubsub.stats hub) in
let+ available, waiting =
  Effect.sync (fun () -> (Semaphore.available sem, Semaphore.waiting sem))
in
(channel.depth, queue.depth, pubsub.subscribers, available, waiting)|};
    };
    {
      area = "handoff_snapshot";
      variant = "proposed";
      code =
        {|let channel = Channel.stats ch in
let queue = Queue.stats q in
let pubsub = Pubsub.stats hub in
let available = Semaphore.available sem in
let waiting = Semaphore.waiting sem in
Effect.pure
  (channel.depth, queue.depth, pubsub.subscribers, available, waiting)|};
    };
    {
      area = "queue_probe";
      variant = "current";
      code =
        {|let send =
  if (Queue.stats q).Queue.closed then Effect.pure `Closed
  else
    Queue.send q value
    |> Effect.map (fun () -> `Sent)
    |> Effect.bind_error recover_send
in
let recv =
  let stats = Queue.stats q in
  if stats.depth = 0 then
    if stats.closed then Effect.pure `Closed else Effect.pure `Empty
  else
    Queue.take q
    |> Effect.map (fun item -> `Item item)
    |> Effect.bind_error recover_recv
in
let* sent = send in
let+ received = recv in
(sent, received)|};
    };
    {
      area = "queue_probe";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* sent = Queue.try_offer q value in
let+ received = Queue.poll q in
(sent, received)|};
    };
    {
      area = "mutable_ref";
      variant = "current";
      code =
        {|let rec update () =
  let current = Atomic.get state in
  let next =
    { processed = current.processed + 1;
      bytes = current.bytes + batch;
      max_batch = max current.max_batch batch }
  in
  if Atomic.compare_and_set state current next then next else update ()
in
Effect.sync update|};
    };
    {
      area = "mutable_ref";
      variant = "proposed";
      code =
        {|Effect.sync (fun () ->
  Mutable_ref.update_and_get state (fun current ->
    { processed = current.processed + 1;
      bytes = current.bytes + batch;
      max_batch = max current.max_batch batch }))|};
    };
    {
      area = "random";
      variant = "current";
      code =
        {|let span = 20 - 10 + 1 in
let dice =
  10 + int_of_float (Capabilities.random_float random (float_of_int span))
in
let ratio = 1.0 +. Capabilities.random_float random 2.0 in
let coin = int_of_float (Capabilities.random_float random 2.0) = 1 in
(dice, ratio, coin)|};
    };
    {
      area = "random";
      variant = "proposed";
      code =
        {|let dice = Random.int_in_range random ~min:10 ~max:20 in
let ratio = Random.float_in_range random ~min:1.0 ~max:3.0 in
let coin = Random.bool random in
(dice, ratio, coin)|};
    };
    {
      area = "random_collections";
      variant = "current";
      code =
        {|let keyed =
  items |> List.map (fun item -> (Capabilities.random_float random 1.0, item))
in
let shuffled = keyed |> List.sort compare |> List.map snd in
let sample =
  if items = [] then None
  else
    let index =
      int_of_float
        (Capabilities.random_float random (float_of_int (List.length items)))
    in
    Some (List.nth items index)
in
let total =
  List.fold_left
    (fun acc (_, weight) -> if weight > 0.0 then acc +. weight else acc)
    0.0 weighted
in
let weighted_choice =
  if total <= 0.0 then None
  else choose_by_hand (Capabilities.random_float random total) weighted
in
(shuffled, weighted_choice, sample)|};
    };
    {
      area = "random_collections";
      variant = "proposed";
      code =
        {|let shuffled = Random.shuffle random items in
let weighted_choice = Random.weighted_choice random weighted in
let sample = Random.sample random items in
(shuffled, weighted_choice, sample)|};
    };
    {
      area = "duration";
      variant = "current";
      code =
        {|let base_ms = 125 in
let raw = base_ms * (1 lsl attempt) in
let scaled = int_of_float (float_of_int raw *. 1.5) in
let clamped = min 2_000 (max 100 scaled) in
let remaining = 5_000 - 250 in
let io_budget = int_of_float (float_of_int remaining *. 0.5) in
(clamped, io_budget)|};
    };
    {
      area = "duration";
      variant = "proposed";
      code =
        {|let retry =
  Duration.scale (Duration.times (Duration.ms 125) (1 lsl attempt)) 1.5
  |> Duration.clamp ~min:(Duration.ms 100) ~max:(Duration.seconds 2)
in
let io_budget =
  Duration.scale (Duration.subtract (Duration.seconds 5) (Duration.ms 250)) 0.5
in
(retry, io_budget)|};
    };
    {
      area = "log_level";
      variant = "current";
      code =
        {|let rank = function
| "TRACE" -> Some 1 | "DEBUG" -> Some 2 | "INFO" -> Some 3
| "WARN" -> Some 4 | "ERROR" -> Some 5 | "FATAL" -> Some 6
| "ALL" -> Some 0 | "NONE" | "OFF" -> Some 7 | _ -> None
in
match (rank (String.uppercase_ascii threshold), rank (String.uppercase_ascii level)) with
| Some 0, Some _ -> true
| Some 7, Some _ | _, None | None, _ -> false
| Some threshold, Some level -> level >= threshold|};
    };
    {
      area = "log_level";
      variant = "proposed";
      code =
        {|match (Log_level.of_string threshold, Log_level.of_string level) with
| Some threshold, Some at -> Log_level.is_enabled ~at ~threshold
| _ -> false|};
    };
    {
      area = "log_level_boundary";
      variant = "current";
      code =
        {|let rendered = String.uppercase_ascii level in
let otel =
  match rendered with
  | "TRACE" -> 1 | "DEBUG" -> 5 | "INFO" -> 9
  | "WARN" -> 13 | "ERROR" -> 17 | "FATAL" -> 21 | _ -> 0
in
let from_otel =
  if severity <= 0 then "ALL"
  else if severity < 5 then "TRACE"
  else if severity < 9 then "DEBUG"
  else if severity < 13 then "INFO"
  else if severity < 17 then "WARN"
  else if severity < 21 then "ERROR"
  else "FATAL"
in
(rendered, otel, from_otel)|};
    };
    {
      area = "log_level_boundary";
      variant = "proposed";
      code =
        {|let rendered = Log_level.to_string level in
let otel = Log_level.to_otel_severity level in
let from_otel = Log_level.of_otel_severity severity in
let display = Format.asprintf "%a" Log_level.pp from_otel in
(rendered, otel, display)|};
    };
    {
      area = "sampler";
      variant = "current";
      code =
        {|let bound = 1 lsl 30 in
let hash = Hashtbl.hash trace_id land (bound - 1) in
let root_sampled = float_of_int hash /. float_of_int bound < 0.5 in
if parent_sampled then true else root_sampled|};
    };
    {
      area = "sampler";
      variant = "proposed";
      code =
        {|let sampler = Sampler.parent_based ~root:(Sampler.ratio 0.5) () in
Sampler.sample sampler ~trace_id ~name:"request"
  ~attrs:[ ("route", "/users/:id") ]
  ~parent:parent_sampled|};
    };
    {
      area = "trace_context";
      variant = "current";
      code =
        {|match List.assoc_opt "traceparent" headers with
| Some traceparent when String.length traceparent >= 55 ->
    let trace_id = String.sub traceparent 3 32 in
    let span_id = String.sub traceparent 36 16 in
    Effect.with_external_parent ~trace_id ~span_id body
| _ -> body|};
    };
    {
      area = "trace_context";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* ctx =
  Trace_context.extract headers
  |> Effect.from_option ~if_none:`Bad_trace_context
in
Effect.with_context ctx body|};
    };
    {
      area = "trace_context_injection";
      variant = "current";
      code =
        {|let flags = Printf.sprintf "%02x" ctx.trace_flags in
let traceparent = "00-" ^ ctx.trace_id ^ "-" ^ ctx.span_id ^ "-" ^ flags in
let tracestate =
  ctx.trace_state
  |> List.map (fun (key, value) -> key ^ "=" ^ value)
  |> String.concat ","
in
let baggage =
  ctx.baggage
  |> List.map (fun (key, value) -> key ^ "=" ^ value)
  |> String.concat ","
in
[ ("traceparent", traceparent); ("tracestate", tracestate); ("baggage", baggage) ]|};
    };
    {
      area = "trace_context_injection";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* current = Effect.current_context in
match current with
| None -> Effect.fail `Missing_context
| Some ctx -> Effect.pure (Trace_context.inject ctx)|};
    };
    {
      area = "span_link";
      variant = "current";
      code =
        {|Effect.named ~kind:Consumer "consume"
  (Effect.annotate_all
     [ ("linked.trace_id", published.trace_id);
       ("linked.span_id", published.span_id) ]
     consume)|};
    };
    {
      area = "span_link";
      variant = "proposed";
      code =
        {|Effect.link_span ~trace_id:published.trace_id ~span_id:published.span_id
  (Effect.named ~kind:Consumer "consume" consume)|};
    };
    {
      area = "exit_cause";
      variant = "current";
      code =
        {|match exit with
| Exit.Ok value -> Some (Ok value)
| Exit.Error (Cause.Fail err) -> Some (Error err)
| Exit.Error
    (Cause.Die _ | Cause.Interrupt _ | Cause.Sequential _
    | Cause.Concurrent _ | Cause.Finalizer _ | Cause.Suppressed _) ->
    None|};
    };
    {
      area = "exit_cause";
      variant = "proposed";
      code = {|Exit.to_result exit|};
    };
    {
      area = "runtime_boundary";
      variant = "current";
      code =
        {|try Exit.Ok (Runtime.run_exn rt eff) with
| Failure message ->
    Exit.Error (Cause.fail (`Runtime_raised message))|};
    };
    {
      area = "runtime_boundary";
      variant = "proposed";
      code = {|Runtime.run rt eff|};
    };
    {
      area = "race";
      variant = "current";
      code =
        {|mirrors
|> List.map fetch
|> Effect.all_settled
|> Effect.bind (fun outcomes ->
     match first_success outcomes with
     | Some payload -> Effect.pure payload
     | None -> Effect.fail `No_mirror)|};
    };
    {
      area = "race";
      variant = "proposed";
      code = {|mirrors |> List.map fetch |> Effect.race|};
    };
    {
      area = "typed_error";
      variant = "current";
      code =
        {|Effect.from_result (parse raw)
|> Effect.bind (fun id -> load_user id)
|> Effect.bind_error (fun err ->
     observe err;
     Effect.fail (to_boundary err))|};
    };
    {
      area = "typed_error";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
(let* id = Effect.from_result (parse raw) in
 load_user id)
|> Effect.tap_error (fun err -> Effect.sync (fun () -> observe err))
|> Effect.map_error to_boundary|};
    };
    {
      area = "admission";
      variant = "current";
      code =
        {|let claimed = Atomic.make false in
let release_claimed =
  Effect.sync (fun () ->
    if Atomic.compare_and_set claimed true false then Semaphore.release sem 1)
in
Effect.race
  [ Semaphore.acquire sem 1
    |> Effect.map (fun () -> Atomic.set claimed true; true);
    abort |> Effect.map (fun _ -> false) ]
|> Effect.bind (fun acquired ->
     if acquired then body () |> Effect.map Option.some
     else Effect.pure None)
|> Effect.finally release_claimed|};
    };
    {
      area = "admission";
      variant = "proposed";
      code = {|Semaphore.with_permits_or_abort sem 1 ~abort body|};
    };
    {
      area = "semaphore_permit";
      variant = "current";
      code =
        {|Semaphore.acquire sem 1
|> Effect.bind (fun () ->
     body ()
     |> Effect.finally
          (Effect.sync (fun () -> Semaphore.release sem 1)))|};
    };
    {
      area = "semaphore_permit";
      variant = "proposed";
      code = {|Semaphore.with_permits sem 1 body|};
    };
    {
      area = "pool";
      variant = "current";
      code =
        {|let idle = ref None in
let sem = Semaphore.make ~permits:1 in
let take_idle = Effect.sync (fun () -> Option.take idle) in
let with_conn body =
  Semaphore.with_permits sem 1 (fun () ->
    let acquire =
      take_idle
      |> Effect.bind (function Some c -> Effect.pure c | None -> acquire)
    in
    Effect.with_resource ~acquire
      ~release:(fun c -> Effect.sync (fun () -> idle := Some c))
      body)
in
with_conn (fun c -> query c "first")
|> Effect.bind (fun first ->
     with_conn (fun c -> query c "second")
     |> Effect.map (fun second -> (first, second)))|};
    };
    {
      area = "pool";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* pool = Pool.create ~max_size:1 ~acquire ~release () in
let* first = Pool.with_resource pool (fun conn -> query conn "first") in
let* second = Pool.with_resource pool (fun conn -> query conn "second") in
let before_shutdown = Pool.stats pool in
let* () = Pool.shutdown pool in
Effect.pure (first, second, before_shutdown)|};
    };
    {
      area = "pubsub";
      variant = "current";
      code =
        {|Pubsub.subscribe hub (fun sub ->
  Pubsub.publish hub event
  |> Effect.bind (fun published ->
       Pubsub.recv sub
       |> Effect.bind (fun first ->
            Pubsub.recv sub
            |> Effect.bind_error closed_reason
            |> Effect.map (fun closed -> (published, first, closed)))))|};
    };
    {
      area = "pubsub";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let@ sub = Pubsub.subscribe hub in
let* published = Pubsub.publish hub event in
let* first = Pubsub.recv sub in
let+ closed = Pubsub.recv sub |> Effect.bind_error closed_reason in
(published, first, closed)|};
    };
    {
      area = "pubsub_poll";
      variant = "current";
      code =
        {|let stats = Pubsub.stats hub in
if stats.depth = 0 || stats.subscribers = 0 then Effect.pure `Empty
else
  Pubsub.recv sub
  |> Effect.map (fun item -> `Item item)
  |> Effect.bind_error recover_closed|};
    };
    {
      area = "pubsub_poll";
      variant = "proposed";
      code = {|Pubsub.try_recv sub|};
    };
    {
      area = "http";
      variant = "current";
      code =
        {|let handler request =
  match request.path with
  | "/" -> Effect.pure (Response.text "ok\n")
  | _ -> Handler.route_not_found request|};
    };
    {
      area = "http";
      variant = "proposed";
      code =
        {|let handler =
  Handler.of_sync (fun request ->
    match request.path with
    | "/" -> Response.text "ok\n"
    | _ -> Response.text ~status:404 "not found\n")|};
    };
    {
      area = "test";
      variant = "current";
      code =
        {|Effect.from_result (parse_id raw)
|> Effect.bind (fun id -> load_user id)
|> Effect.map render_user|};
    };
    {
      area = "test";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* id = Effect.from_result (parse_id raw) in
let* user = load_user id in
Effect.pure (render_user user)|};
    };
    {
      area = "cli";
      variant = "current";
      code =
        {|Effect.from_result (parse_id raw)
|> Effect.bind (fun id ->
     retrying_call ("/users/" ^ id)
     |> Effect.map format)|};
    };
    {
      area = "cli";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
let* id = Effect.from_result (parse_id raw) in
	let* payload = retrying_call ("/users/" ^ id) in
	Effect.pure (format payload)|};
    };
    {
      area = "blocking";
      variant = "current";
      code =
        {|Eta_blocking.run ~name:"fs.read" (fun () -> read_file path)
|> Effect.bind Effect.from_result|};
    };
    {
      area = "blocking";
      variant = "proposed";
      code =
        {|Eta_blocking.run_result ~name:"fs.read" (fun () -> read_file path)|};
    };
    {
      area = "supervisor";
      variant = "current";
      code =
        {|let failures = ref [] in
Effect.with_background
  (refresh
   |> Effect.bind_error (fun err ->
        Effect.sync (fun () -> failures := Cause.Fail err :: !failures)))
  (fun () -> Effect.sync (fun () -> List.length !failures))|};
    };
    {
      area = "supervisor";
      variant = "proposed";
      code =
        {|Supervisor.scoped {
  run = fun sup ->
    let open Supervisor.Scope in
    let* _child = start sup (fail `Refresh_failed) in
    let* () = yield in
    let* failures = failures sup in
    pure (List.length failures);
}|};
    };
    {
      area = "observability";
      variant = "current";
      code =
        {|Effect.named "request"
  (Effect.log "request.started"
   |> Effect.bind (fun () ->
        Effect.metric_counter ~name:"requests" ~monotonic:true (Int 1)
        |> Effect.bind (fun () ->
             load_user id
             |> Effect.with_result_attrs ~ok_attrs ~err_attrs)))|};
    };
    {
      area = "observability";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
Effect.named "request"
  (let* () = Effect.log "request.started" in
   let* () =
     Effect.metric_counter ~name:"requests" ~monotonic:true (Int 1)
   in
   load_user id
   |> Effect.with_result_attrs ~ok_attrs ~err_attrs)|};
    };
    {
      area = "metric_batch";
      variant = "current";
      code =
        {|let open Eta.Syntax in
let* stats = Effect.sync snapshot in
let* () = Effect.metric_gauge ~name:"pool.active" (Int stats.active) in
let* () = Effect.metric_gauge ~name:"pool.idle" (Int stats.idle) in
let* () =
  Effect.metric_gauge ~name:"pool.waiting" ~unit_:"{waiter}" (Int stats.waiting)
in
Effect.metric_gauge ~name:"pool.max_size" (Int stats.max_size)|};
    };
    {
      area = "metric_batch";
      variant = "proposed";
      code =
        {|Effect.metric_updates_lazy (fun () ->
  let stats = snapshot () in
  [
    Effect.metric ~name:"pool.active" ~kind:Gauge (Number (Int stats.active));
    Effect.metric ~name:"pool.idle" ~kind:Gauge (Number (Int stats.idle));
    Effect.metric ~name:"pool.waiting" ~unit_:"{waiter}" ~kind:Gauge
      (Number (Int stats.waiting));
    Effect.metric ~name:"pool.max_size" ~kind:Gauge (Number (Int stats.max_size));
  ])|};
    };
    {
      area = "observability_controls";
      variant = "current";
      code =
        {|let attrs = if tracing_enabled then expensive_attrs () else [] in
Effect.named "visible"
  (Effect.annotate_all attrs
     (hidden_export
      |> Effect.bind (fun () -> Effect.event "visible.done")))|};
    };
    {
      area = "observability_controls";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
Effect.named "visible"
  (let* tracing = Effect.is_tracing_enabled in
   let* () =
     Effect.annotate_all_lazy expensive_attrs
       (Effect.event "visible.done")
   in
   let* () = Effect.suppress_observability hidden_export in
   Effect.pure tracing)|};
    };
    {
      area = "observability_sinks";
      variant = "current";
      code =
        {|let logs = ref [] in
let logger =
  object
    method log record = logs := record :: !logs
  end
in
let points = ref [] in
let meter =
  object
    method record ~name ~description ~unit_ ~kind ~attrs ~value ~ts_ms =
      points := (name, description, unit_, kind, attrs, value, ts_ms) :: !points
  end
in
(logger, meter, List.rev !logs, List.rev !points)|};
    };
    {
      area = "observability_sinks";
      variant = "proposed";
      code =
        {|let tracer = Tracer.in_memory () in
let logger = Logger.in_memory () in
let meter = Meter.in_memory () in
let capabilities =
  (Tracer.as_capability tracer, Logger.as_capability logger, Meter.as_capability meter)
in
Tracer.retain_recent tracer ~max:1;
(capabilities, Tracer.dump tracer, Logger.dump logger, Meter.dump meter)|};
    };
    {
      area = "background";
      variant = "current";
      code =
        {|Effect.with_background heartbeat (fun () ->
  wait_started
  |> Effect.bind (fun () ->
       Effect.par (load_user left) (load_user right)
       |> Effect.map format_pair))|};
    };
    {
      area = "background";
      variant = "proposed";
      code =
        {|let open Eta.Syntax in
Effect.with_background heartbeat (fun () ->
  let* () = wait_started in
  Effect.par (load_user left) (load_user right)
  |> Effect.map format_pair)|};
    };
    {
      area = "daemon_drain";
      variant = "current";
      code =
        {|let done_ = Atomic.make false in
Eio.Fiber.fork_daemon ~sw (fun () ->
  run_worker ();
  Atomic.set done_ true;
  `Stop_daemon);
while not (Atomic.get done_) do Eio.Fiber.yield () done|};
    };
    {
      area = "daemon_drain";
      variant = "proposed";
      code =
        {|ignore (Runtime.run rt (Effect.daemon worker));
Runtime.drain rt|};
    };
  ]

let count_sub haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index acc =
    if needle_len = 0 || index + needle_len > hay_len then acc
    else if String.sub haystack index needle_len = needle then
      loop (index + needle_len) (acc + 1)
    else loop (index + 1) acc
  in
  loop 0 0

let count_token haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let is_ident_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> true
    | _ -> false
  in
  let rec loop index acc =
    if needle_len = 0 || index + needle_len > hay_len then acc
    else if String.sub haystack index needle_len = needle then
      let next = index + needle_len in
      let extends = next < hay_len && is_ident_char haystack.[next] in
      if extends then loop (index + 1) acc else loop next (acc + 1)
    else loop (index + 1) acc
  in
  loop 0 0

let line_count s =
  if String.equal s "" then 0 else 1 + count_sub s "\n"

let metric snippet =
  ( snippet.area,
    snippet.variant,
    line_count snippet.code,
    count_token snippet.code "Effect.bind",
    count_sub snippet.code "let*",
    count_sub snippet.code "let@",
    count_sub snippet.code "Effect.from_result" )

let assert_no_explicit_bind snippet =
  let bind = count_token snippet.code "Effect.bind" in
  let infix_bind = count_sub snippet.code ">>=" in
  if bind + infix_bind > 0 then
    failwith
      (Printf.sprintf
         "proposed %s example exposes explicit bind operators" snippet.area)

let assert_expected_shape snippet =
  match (snippet.area, snippet.variant, metric snippet) with
  | "resource", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 1 || from_result <> 0 then
        failwith
          "resource proposed example should use let@ plus sync_result";
      if count_sub snippet.code "Effect.sync_result" <> 1 then
        failwith "resource proposed example should use sync_result leaf"
  | "cached_resource", "proposed", (_, _, _, bind, let_star, let_at, from_result)
    ->
      if bind <> 0 || let_star <> 1 || let_at <> 0 || from_result <> 0 then
        failwith
          "cached_resource proposed example should use Resource.auto with one let*";
      if
        count_sub snippet.code "Resource.auto" <> 1
        || count_sub snippet.code "Resource.get" <> 1
      then
        failwith
          "cached_resource proposed example should prove Resource.auto and get"
  | ( "resource_failures",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 2 || let_at <> 0 || from_result <> 0 then
        failwith
          "resource_failures proposed example should use Resource APIs with syntax sequencing";
      if
        count_sub snippet.code "Resource.auto" <> 1
        || count_sub snippet.code "Resource.get" <> 1
        || count_sub snippet.code "Resource.failures" <> 1
        || count_sub snippet.code "ref []" <> 0
        || count_sub snippet.code "~on_error" <> 0
      then
        failwith
          "resource_failures proposed example should read Eta-owned resource diagnostics instead of a side-channel ref"
  | "manual_resource", "proposed", (_, _, _, bind, let_star, let_at, from_result)
    ->
      if bind <> 0 || let_star <> 2 || let_at <> 0 || from_result <> 0 then
        failwith
          "manual_resource proposed example should use Resource APIs with syntax sequencing";
      if
        count_sub snippet.code "Resource.manual" <> 1
        || count_sub snippet.code "Resource.refresh" <> 1
        || count_sub snippet.code "Resource.get" <> 1
        || count_sub snippet.code "Effect.ignore_errors" <> 1
        || count_sub snippet.code "Effect.bind_error" <> 0
        || count_sub snippet.code "ref None" <> 0
      then
        failwith
          "manual_resource proposed example should prove caller-driven Resource refresh without a manual ref cache or raw catch"
  | "scoped_resource", "proposed", (_, _, _, _, let_star, let_at, from_result) ->
      if let_star <> 1 || let_at <> 0 || from_result <> 0 then
        failwith
          "scoped_resource proposed example should use scoped let* plus Effect.par";
      if
        count_sub snippet.code "Effect.with_scope" <> 1
        || count_sub snippet.code "Effect.acquire_release" <> 1
        || count_sub snippet.code "Effect.par" <> 1
      then
        failwith
          "scoped_resource proposed example should prove acquire_release plus scoped Effect.par"
  | "service", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "service proposed example should be explicit dependency plus sync_result leaf";
      if
        count_sub snippet.code "load_user_at clock db id" <> 1
        || count_sub snippet.code "Effect.sync_result" <> 1
        || count_sub snippet.code "List.assoc_opt" <> 0
        || count_sub snippet.code "Clock" <> 0
        || count_sub snippet.code "Db" <> 0
      then
        failwith
          "service proposed example should pass ordinary OCaml dependencies instead of reading a service bag"
  | ( "catch_recovery",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "catch_recovery proposed example should be direct typed recovery";
      if
        count_sub snippet.code "Effect.bind_error" <> 1
        || count_token snippet.code "Effect.bind" <> 0
        || count_sub snippet.code "Ok " <> 0
        || count_sub snippet.code "Error " <> 0
      then
        failwith
          "catch_recovery proposed example should use Effect.bind_error instead of moving typed errors into result values"
  | ( "pure_recovery",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "pure_recovery proposed example should be direct recovery";
      if
        count_sub snippet.code "Effect.fold ~ok:Fun.id ~error:" <> 1
        || count_sub snippet.code "Effect.bind_error" <> 0
        || count_sub snippet.code "Effect.pure" <> 0
      then
        failwith
          "pure_recovery proposed example should use Effect.fold instead of bind_error plus pure"
  | ( "best_effort",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "best_effort proposed example should be one helper call";
      if
        count_sub snippet.code "Effect.ignore_errors" <> 1
        || count_sub snippet.code "Effect.bind_error" <> 0
        || count_sub snippet.code "Effect.unit" <> 0
      then
        failwith
          "best_effort proposed example should use Effect.ignore_errors instead of bind_error plus unit"
  | ( "typed_failure_result",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "typed_failure_result proposed example should be one helper call";
      if
        count_sub snippet.code "Effect.to_result" <> 1
        || count_sub snippet.code "Effect.fold ~ok:Fun.id ~error:" <> 0
        || count_sub snippet.code "Effect.map" <> 0
      then
        failwith
          "typed_failure_result proposed example should use Effect.to_result instead of map plus fold"
  | ( "validation_boundary",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 1 then
        failwith
          "validation_boundary proposed example should directly lift one result";
      if
        count_sub snippet.code "Effect.from_result" <> 1
        || count_sub snippet.code "fun ()" <> 0
      then
        failwith
          "validation_boundary proposed example should use from_result for an already-computed result"
  | "sync_defect", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "sync_defect proposed example should be a direct sync leaf";
      if
        count_sub snippet.code "Effect.sync " <> 1
        || count_sub snippet.code "try " <> 0
        || count_sub snippet.code "Error " <> 0
      then
        failwith
          "sync_defect proposed example should use sync instead of converting exceptions to typed failures"
  | ( "source_location",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "source_location proposed example should be a direct fn wrapper";
      if
        count_sub snippet.code "Effect.fn" <> 1
        || count_sub snippet.code "__POS__" <> 1
        || count_sub snippet.code "__FUNCTION__" <> 1
        || count_sub snippet.code "Printf.sprintf" <> 0
        || count_sub snippet.code "Effect.annotate" <> 0
      then
        failwith
          "source_location proposed example should use Effect.fn instead of manual loc formatting"
  | ( "error_rendering",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "error_rendering proposed example should be a direct renderer wrapper";
      if
        count_sub snippet.code "Effect.with_error_pp" <> 1
        || count_sub snippet.code "Effect.named" <> 1
        || count_sub snippet.code "<typed failure>" <> 0
      then
        failwith
          "error_rendering proposed example should render typed failures through Eta observability"
  | ( "tap_success",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "tap_success proposed example should be one success observer";
      if
        count_sub snippet.code "Effect.tap" <> 1
        || count_token snippet.code "Effect.bind" <> 0
        || count_sub snippet.code "Effect.map" <> 0
      then
        failwith
          "tap_success proposed example should use Effect.tap instead of observe-and-return bind"
  | ( "sync_observer",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "sync_observer proposed example should be one effectful tap observer";
      if
        count_sub snippet.code "Effect.tap " <> 1
        || count_sub snippet.code "Effect.sync" <> 1
        || count_token snippet.code "Effect.bind" <> 0
      then
        failwith
          "sync_observer proposed example should use Effect.tap with explicit sync observer"
  | "success_map", "proposed", (_, _, _, bind, let_star, let_at, from_result)
    ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "success_map proposed example should be one value projection";
      if
        count_sub snippet.code "let+" <> 1
        || count_token snippet.code "Effect.bind" <> 0
        || count_sub snippet.code "Effect.pure" <> 0
      then
        failwith
          "success_map proposed example should use let+ instead of bind plus pure"
  | ( "finally_cleanup",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "finally_cleanup proposed example should be one cleanup wrapper";
      if
        count_sub snippet.code "Effect.finally" <> 1
        || count_sub snippet.code "Effect.bind_error" <> 0
      then
        failwith
          "finally_cleanup proposed example should use Effect.finally instead of hand-written catch cleanup"
  | ( "timeout_policy",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "timeout_policy proposed example should be one timeout wrapper";
      if
        count_sub snippet.code "Effect.timeout_as" <> 1
        || count_sub snippet.code "Effect.race" <> 0
        || count_sub snippet.code "Effect.delay" <> 0
        || count_sub snippet.code "`Timeout" <> 0
      then
        failwith
          "timeout_policy proposed example should use Effect.timeout_as with a domain typed timeout"
  | ( "uninterruptible_commit",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "uninterruptible_commit proposed example should be one race wrapper";
      if
        count_sub snippet.code "Effect.uninterruptible" <> 1
        || count_sub snippet.code "Effect.race" <> 1
      then
        failwith
          "uninterruptible_commit proposed example should protect one critical branch inside race"
  | ( "cooperative_yield",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "cooperative_yield proposed example should be direct yield";
      if
        count_sub snippet.code "Effect.yield" <> 1
        || count_sub snippet.code "Effect.sync" <> 0
        || count_sub snippet.code "Eio.Fiber.yield" <> 0
      then
        failwith
          "cooperative_yield proposed example should use Effect.yield instead of backend-specific sync yield"
  | (("retry" | "stream"), "proposed", (_, _, _, _, let_star, let_at, from_result))
    ->
      if let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          (Printf.sprintf
             "%s proposed example should use sync_result without bind"
             snippet.area);
      if count_sub snippet.code "Effect.sync_result" <> 1 then
        failwith
          (Printf.sprintf "%s proposed example should use sync_result leaf"
             snippet.area)
  | "blocking", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "blocking proposed example should use Eta_blocking.run_result directly"
  | "schedule_retry", "proposed", (_, _, _, bind, let_star, let_at, from_result)
    ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "schedule_retry proposed example should use Schedule plus sync_result";
      if
        count_sub snippet.code "Schedule." <> 1
        || count_sub snippet.code "recurs" <> 1
        || count_sub snippet.code "exponential" <> 1
        || count_sub snippet.code "jittered" <> 1
        || count_sub snippet.code "Effect.retry ~schedule:" <> 1
        || count_sub snippet.code "Effect.sync_result" <> 1
      then
        failwith
          "schedule_retry proposed example should prove composed Schedule retry"
  | ( "repeat_heartbeat",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "repeat_heartbeat proposed example should be direct repeat";
      if
        count_sub snippet.code "Effect.repeat" <> 1
        || count_sub snippet.code "Schedule.next" <> 0
        || count_sub snippet.code "Schedule.start" <> 0
      then
        failwith
          "repeat_heartbeat proposed example should use Effect.repeat instead of manual schedule driving"
  | "batch", "proposed", (_, _, _, _, let_star, let_at, from_result) ->
      if let_star <> 1 || let_at <> 0 || from_result <> 0 then
        failwith "batch proposed example should use one workflow let*";
      if
        count_sub snippet.code "Effect.map_par" <> 1
        || count_sub snippet.code "Effect.all_settled" <> 1
      then
        failwith
          "batch proposed example should prove bounded fan-out and settled outcomes"
  | "all_collect", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "all_collect proposed example should be direct all";
      if
        count_sub snippet.code "Effect.all" <> 1
        || count_token snippet.code "Effect.bind" <> 0
        || count_sub snippet.code "Effect.map" <> 0
      then
        failwith
          "all_collect proposed example should use Effect.all instead of a recursive bind loop"
  | ( "blueprint_names",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "blueprint_names proposed example should be pure inspection";
      if
        count_sub snippet.code "Effect.name" <> 1
        || count_sub snippet.code "Effect.collect_names" <> 1
        || count_sub snippet.code "Hashtbl" <> 0
      then
        failwith
          "blueprint_names proposed example should use Eta blueprint inspection instead of a manual registry"
  | "channel", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 5 || let_at <> 0 || from_result <> 0 then
        failwith
          "channel proposed example should use syntax for producer and consumer";
      if
        count_sub snippet.code "Channel.send" <> 2
        || count_sub snippet.code "Channel.recv" <> 3
        || count_sub snippet.code "Channel.close_with_error_effect" <> 1
        || count_sub snippet.code "Effect.sync" <> 0
      then
        failwith
          "channel proposed example should prove send, recv, and effectful close_with_error"
  | ( "channel_probe",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 1 || let_at <> 0 || from_result <> 0 then
        failwith
          "channel_probe proposed example should use one let* for two non-blocking probes";
      if
        count_sub snippet.code "Channel.try_send" <> 1
        || count_sub snippet.code "Channel.try_recv" <> 1
        || count_sub snippet.code "Channel.stats" <> 0
        || count_sub snippet.code "Channel.send" <> 0
        || count_sub snippet.code "Channel.recv" <> 0
      then
        failwith
          "channel_probe proposed example should use non-blocking channel probes instead of manual stats checks or blocking operations"
  | "queue", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 7 || let_at <> 0 || from_result <> 0 then
        failwith "queue proposed example should use syntax for FIFO drain";
      if
        count_sub snippet.code "Queue.send" <> 3
        || count_sub snippet.code "Queue.take" <> 4
        || count_sub snippet.code "Queue.close_with_error_effect" <> 1
        || count_sub snippet.code "Queue.stats" <> 1
        || count_sub snippet.code "Effect.sync" <> 0
      then
        failwith
          "queue proposed example should prove send, recv, stats, and effectful typed close"
  | "handoff_close", "proposed", (_, _, _, bind, let_star, let_at, from_result)
    ->
      if bind <> 0 || let_star <> 2 || let_at <> 0 || from_result <> 0 then
        failwith
          "handoff_close proposed example should sequence effectful close helpers";
      if
        count_sub snippet.code "Channel.close_with_error_effect" <> 1
        || count_sub snippet.code "Queue.close_with_error_effect" <> 1
        || count_sub snippet.code "Pubsub.close_with_error_effect" <> 1
        || count_sub snippet.code "Effect.sync" <> 0
      then
        failwith
          "handoff_close proposed example should use effectful close helpers instead of raw sync wrappers"
  | ( "handoff_snapshot",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "handoff_snapshot proposed example should be a direct snapshot";
      if
        count_sub snippet.code "Effect.sync" <> 0
        || count_sub snippet.code "Effect.pure" <> 1
        || count_sub snippet.code "Channel.stats" <> 1
        || count_sub snippet.code "Queue.stats" <> 1
        || count_sub snippet.code "Pubsub.stats" <> 1
        || count_sub snippet.code "Semaphore.available" <> 1
        || count_sub snippet.code "Semaphore.waiting" <> 1
      then
        failwith
          "handoff_snapshot proposed example should read plain snapshots directly and lift once with Effect.pure"
  | "queue_probe", "proposed", (_, _, _, bind, let_star, let_at, from_result)
    ->
      if bind <> 0 || let_star <> 1 || let_at <> 0 || from_result <> 0 then
        failwith
          "queue_probe proposed example should use one let* for two non-blocking probes";
      if
        count_sub snippet.code "Queue.try_offer" <> 1
        || count_sub snippet.code "Queue.poll" <> 1
        || count_sub snippet.code "Queue.stats" <> 0
        || count_sub snippet.code "Queue.send" <> 0
        || count_sub snippet.code "Queue.take" <> 0
      then
        failwith
          "queue_probe proposed example should use non-blocking queue probes instead of manual stats checks or blocking operations"
  | "mutable_ref", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "mutable_ref proposed example should be one sync leaf without bind";
      if
        count_sub snippet.code "Mutable_ref.update_and_get" <> 1
        || count_sub snippet.code "Atomic." <> 0
      then
        failwith
          "mutable_ref proposed example should hide the raw Atomic CAS loop"
  | "random", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "random proposed example should be pure helper usage";
      if
        count_sub snippet.code "Random.int_in_range" <> 1
        || count_sub snippet.code "Random.float_in_range" <> 1
        || count_sub snippet.code "Random.bool" <> 1
        || count_sub snippet.code "Capabilities.random_float" <> 0
      then
        failwith
          "random proposed example should use Random helpers instead of raw random_float math"
  | ( "random_collections",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "random_collections proposed example should be pure helper usage";
      if
        count_sub snippet.code "Random.shuffle" <> 1
        || count_sub snippet.code "Random.weighted_choice" <> 1
        || count_sub snippet.code "Random.sample" <> 1
        || count_sub snippet.code "Capabilities.random_float" <> 0
        || count_sub snippet.code "List.nth" <> 0
      then
        failwith
          "random_collections proposed example should use collection helpers instead of raw random_float indexing"
  | "duration", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "duration proposed example should be pure helper usage";
      if
        count_sub snippet.code "Duration.ms" <> 3
        || count_sub snippet.code "Duration.seconds" <> 2
        || count_sub snippet.code "Duration.times" <> 1
        || count_sub snippet.code "Duration.scale" <> 2
        || count_sub snippet.code "Duration.clamp" <> 1
        || count_sub snippet.code "Duration.subtract" <> 1
        || count_sub snippet.code "_ms" <> 0
      then
        failwith
          "duration proposed example should use typed Duration helpers instead of raw millisecond plumbing"
  | "log_level", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "log_level proposed example should be pure helper usage";
      if
        count_sub snippet.code "Log_level.of_string" <> 2
        || count_sub snippet.code "Log_level.is_enabled" <> 1
        || count_sub snippet.code "String.uppercase_ascii" <> 0
      then
        failwith
          "log_level proposed example should use Log_level parsing and threshold helpers"
  | ( "log_level_boundary",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "log_level_boundary proposed example should be pure boundary conversion";
      if
        count_sub snippet.code "Log_level.to_string" <> 1
        || count_sub snippet.code "Log_level.to_otel_severity" <> 1
        || count_sub snippet.code "Log_level.of_otel_severity" <> 1
        || count_sub snippet.code "Log_level.pp" <> 1
        || count_sub snippet.code "String.uppercase_ascii" <> 0
        || count_sub snippet.code "severity <" <> 0
      then
        failwith
          "log_level_boundary proposed example should use Log_level boundary helpers instead of manual string/severity ladders"
  | "sampler", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "sampler proposed example should be pure policy usage";
      if
        count_sub snippet.code "Sampler.parent_based" <> 1
        || count_sub snippet.code "Sampler.ratio" <> 1
        || count_sub snippet.code "Sampler.sample" <> 1
        || count_sub snippet.code "Hashtbl.hash" <> 0
      then
        failwith
          "sampler proposed example should use Sampler policy helpers instead of manual hashing"
  | "trace_context", "proposed", (_, _, _, bind, let_star, let_at, from_result)
    ->
      if bind <> 0 || let_star <> 1 || let_at <> 0 || from_result <> 0 then
        failwith
          "trace_context proposed example should extract once and lift the optional context";
      if
        count_sub snippet.code "Trace_context.extract" <> 1
        || count_sub snippet.code "Effect.from_option" <> 1
        || count_sub snippet.code "Effect.with_context" <> 1
        || count_sub snippet.code "Effect.with_external_parent" <> 0
        || count_sub snippet.code "String.sub" <> 0
      then
        failwith
          "trace_context proposed example should preserve full extracted context"
  | ( "trace_context_injection",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 1 || let_at <> 0 || from_result <> 0 then
        failwith
          "trace_context_injection proposed example should read the runtime context with let*";
      if
        count_sub snippet.code "Effect.current_context" <> 1
        || count_sub snippet.code "Trace_context.inject" <> 1
        || count_sub snippet.code "Printf.sprintf" <> 0
        || count_sub snippet.code "String.concat" <> 0
        || count_sub snippet.code "traceparent" <> 0
      then
        failwith
          "trace_context_injection proposed example should inject runtime context instead of rebuilding W3C headers by hand"
  | "span_link", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "span_link proposed example should be direct span-link metadata";
      if
        count_sub snippet.code "Effect.link_span" <> 1
        || count_sub snippet.code "Effect.named" <> 1
        || count_sub snippet.code "Effect.annotate_all" <> 0
        || count_sub snippet.code "linked.trace_id" <> 0
      then
        failwith
          "span_link proposed example should use real tracer links instead of string attributes"
  | "exit_cause", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "exit_cause proposed example should be direct boundary use";
      if
        count_sub snippet.code "Exit.to_result" <> 1
        || count_sub snippet.code "Cause." <> 0
      then
        failwith
          "exit_cause proposed example should use Exit.to_result without re-matching causes"
  | ( "runtime_boundary",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "runtime_boundary proposed example should be direct run use";
      if
        count_sub snippet.code "Runtime.run " <> 1
        || count_sub snippet.code "Runtime.run_exn" <> 0
        || count_sub snippet.code "Cause." <> 0
      then
        failwith
          "runtime_boundary proposed example should keep Exit instead of catching run_exn"
  | "race", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "race proposed example should be direct race composition";
      if count_sub snippet.code "Effect.race" <> 1 then
        failwith "race proposed example should use Effect.race"
  | "typed_error", "proposed", (_, _, _, bind, let_star, let_at, _) ->
      if bind <> 0 || let_star <> 1 || let_at <> 0 then
        failwith
          "typed_error proposed example should use let* plus typed transforms";
      if
        count_sub snippet.code "Effect.tap_error" <> 1
        || count_sub snippet.code "Effect.map_error" <> 1
      then
        failwith
          "typed_error proposed example should prove tap_error and map_error"
  | "admission", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "admission proposed example should be a direct helper call";
      if count_sub snippet.code "Semaphore.with_permits_or_abort" <> 1 then
        failwith
          "admission proposed example should prove with_permits_or_abort"
  | ( "semaphore_permit",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith
          "semaphore_permit proposed example should be a direct helper call";
      if
        count_sub snippet.code "Semaphore.with_permits" <> 1
        || count_sub snippet.code "Semaphore.acquire" <> 0
        || count_sub snippet.code "Semaphore.release" <> 0
        || count_sub snippet.code "Effect.finally" <> 0
      then
        failwith
          "semaphore_permit proposed example should use scoped permits instead of manual acquire/release/finally"
  | "pool", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 4 || let_at <> 0 || from_result <> 0 then
        failwith
          "pool proposed example should use Pool APIs with syntax sequencing";
      if
        count_sub snippet.code "Pool.create" <> 1
        || count_sub snippet.code "Pool.with_resource" <> 2
        || count_sub snippet.code "Pool.shutdown" <> 1
      then
        failwith
          "pool proposed example should prove create, with_resource, and shutdown"
  | "pubsub", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 2 || let_at <> 1 || from_result <> 0 then
        failwith
          "pubsub proposed example should use let@ subscription and let* receives";
      if
        count_sub snippet.code "Pubsub.subscribe" <> 1
        || count_sub snippet.code "Pubsub.publish" <> 1
        || count_sub snippet.code "Pubsub.recv" <> 2
      then
        failwith
          "pubsub proposed example should prove subscribe, publish, and recv"
  | "pubsub_poll", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "pubsub_poll proposed example should be one non-blocking poll";
      if
        count_sub snippet.code "Pubsub.try_recv" <> 1
        || count_sub snippet.code "Pubsub.stats" <> 0
        || count_sub snippet.code "Pubsub.recv" <> 0
      then
        failwith
          "pubsub_poll proposed example should use try_recv instead of hub stats or blocking receive"
  | "supervisor", "proposed", (_, _, _, bind, let_star, let_at, from_result) ->
      if bind <> 0 || let_star <> 3 || let_at <> 0 || from_result <> 0 then
        failwith
          "supervisor proposed example should use Scope let* sequencing";
      if
        count_sub snippet.code "Supervisor.scoped" <> 1
        || count_sub snippet.code "Supervisor.Scope" <> 1
        || count_sub snippet.code "start sup" <> 1
        || count_sub snippet.code "failures sup" <> 1
        || count_sub snippet.code "Effect.with_background" <> 0
      then
        failwith
          "supervisor proposed example should prove the scoped nursery shape instead of manual background bookkeeping"
  | ("test" | "cli"), "proposed", (_, _, _, _, let_star, let_at, _) ->
      if let_star = 0 || let_at <> 0 then
        failwith
          (Printf.sprintf
             "%s proposed example should expose only sequencing let*"
             snippet.area)
  | "observability", "proposed", (_, _, _, _, let_star, let_at, from_result) ->
      if let_star <> 2 || let_at <> 0 || from_result <> 0 then
        failwith
          "observability proposed example should use let* for signal sequencing"
  | "metric_batch", "proposed", (_, _, _, bind, let_star, let_at, from_result)
    ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "metric_batch proposed example should be one lazy batch";
      if
        count_sub snippet.code "Effect.metric_updates_lazy" <> 1
        || count_sub snippet.code "Effect.metric ~name" <> 4
        || count_sub snippet.code "Effect.metric_update ~name" <> 0
      then
        failwith
          "metric_batch proposed example should prove lazy batch emission and metric descriptors"
  | ( "observability_controls",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 3 || let_at <> 0 || from_result <> 0 then
        failwith
          "observability_controls proposed example should use runtime-aware syntax controls";
      if
        count_sub snippet.code "Effect.is_tracing_enabled" <> 1
        || count_sub snippet.code "Effect.annotate_all_lazy" <> 1
        || count_sub snippet.code "Effect.suppress_observability" <> 1
        || count_sub snippet.code "Effect.annotate_all " <> 0
      then
        failwith
          "observability_controls proposed example should prove runtime tracing guard, lazy attrs, and suppression"
  | ( "observability_sinks",
      "proposed",
      (_, _, _, bind, let_star, let_at, from_result) ) ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "observability_sinks proposed example should be pure sink setup";
      if
        count_sub snippet.code "Tracer.in_memory" <> 1
        || count_sub snippet.code "Logger.in_memory" <> 1
        || count_sub snippet.code "Meter.in_memory" <> 1
        || count_sub snippet.code "Tracer.as_capability" <> 1
        || count_sub snippet.code "Logger.as_capability" <> 1
        || count_sub snippet.code "Meter.as_capability" <> 1
        || count_sub snippet.code "Tracer.retain_recent" <> 1
        || count_sub snippet.code "object" <> 0
        || count_sub snippet.code "ref []" <> 0
      then
        failwith
          "observability_sinks proposed example should use built-in in-memory sinks instead of custom collectors"
  | "background", "proposed", (_, _, _, _, let_star, let_at, from_result) ->
      if let_star <> 1 || let_at <> 0 || from_result <> 0 then
        failwith
          "background proposed example should use let* wait then Effect.par body work";
      if count_sub snippet.code "Effect.par" <> 1 then
        failwith
          "background proposed example should spell concurrent loads with Effect.par"
  | "daemon_drain", "proposed", (_, _, _, bind, let_star, let_at, from_result)
    ->
      if bind <> 0 || let_star <> 0 || let_at <> 0 || from_result <> 0 then
        failwith "daemon_drain proposed example should be direct lifecycle use";
      if
        count_sub snippet.code "Effect.daemon" <> 1
        || count_sub snippet.code "Runtime.drain" <> 1
        || count_sub snippet.code "Eio.Fiber.fork_daemon" <> 0
        || count_sub snippet.code "Atomic." <> 0
      then
        failwith
          "daemon_drain proposed example should use Eta daemon/drain instead of manual fiber bookkeeping"
  | _ -> ()

let () =
  List.iter
    (fun snippet ->
      let area, variant, lines, bind, let_star, let_at, from_result =
        metric snippet
      in
      Printf.printf
        "%s,%s,lines=%d,effect_bind=%d,let_star=%d,let_at=%d,from_result=%d\n"
        area variant lines bind let_star let_at from_result)
    snippets;
  snippets
  |> List.filter (fun snippet -> String.equal snippet.variant "proposed")
  |> List.iter (fun snippet ->
         assert_no_explicit_bind snippet;
         assert_expected_shape snippet)
