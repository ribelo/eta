module S = Eta_sql.Sqlite
module E = Eta.Effect

let sample_count = 2_000
let warmup_count = 200

let elapsed_us start =
  Mtime.Span.to_uint64_ns (Mtime_clock.count start)
  |> Int64.to_float
  |> fun ns -> ns /. 1_000.0

let percentile sorted pct =
  match sorted with
  | [] -> 0.0
  | _ ->
      let len = List.length sorted in
      let idx =
        float_of_int (len - 1) *. pct |> int_of_float |> min (len - 1) |> max 0
      in
      List.nth sorted idx

let mean samples =
  match samples with
  | [] -> 0.0
  | _ ->
      List.fold_left ( +. ) 0.0 samples /. float_of_int (List.length samples)

let stddev samples =
  match samples with
  | [] | [ _ ] -> 0.0
  | _ ->
      let avg = mean samples in
      let variance =
        List.fold_left
          (fun acc sample ->
            let delta = sample -. avg in
            acc +. (delta *. delta))
          0.0 samples
        /. float_of_int (List.length samples - 1)
      in
      sqrt variance

let print_stats label samples =
  let sorted = List.sort Float.compare samples in
  let min_v = match sorted with [] -> 0.0 | x :: _ -> x in
  let max_v = match List.rev sorted with [] -> 0.0 | x :: _ -> x in
  Printf.printf
    "%s n=%d mean_us=%.3f stddev_us=%.3f min_us=%.3f p50_us=%.3f p95_us=%.3f p99_us=%.3f max_us=%.3f\n"
    label (List.length samples) (mean samples) (stddev samples) min_v
    (percentile sorted 0.50) (percentile sorted 0.95) (percentile sorted 0.99)
    max_v

let check_rc db operation rc =
  match S.check db ~operation rc with
  | Ok () -> ()
  | Error err -> failwith (Format.asprintf "%a" S.pp_error err)

let setup_db () =
  let db = S.open_memory () in
  S.exec_script db
    "CREATE TABLE items (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);\
     INSERT INTO items (id, value) VALUES (1, 42);";
  db

let setup_stmt db =
  S.prepare db "SELECT value FROM items WHERE id = ?"

let step_pk db stmt id =
  check_rc db "reset" (S.reset stmt);
  check_rc db "clear bindings" (S.clear_bindings stmt);
  check_rc db "bind id" (S.bind_int stmt 1 id);
  let rc = S.step stmt in
  if not (S.rc_equal rc S.row) then (
    let err = { S.operation = "step row"; code = rc; message = S.error_message db } in
    failwith (Format.asprintf "%a" S.pp_error err));
  let value = S.column_int stmt 0 in
  let rc = S.step stmt in
  if not (S.rc_equal rc S.done_) then (
    let err = { S.operation = "step done"; code = rc; message = S.error_message db } in
    failwith (Format.asprintf "%a" S.pp_error err));
  value

let run_ok rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith (Format.asprintf "Eta failure: %a" (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>")) cause)

let effect_loop count f =
  let rec loop remaining acc =
    if remaining = 0 then
      E.pure (List.rev acc)
    else
      E.sync Mtime_clock.counter
      |> E.bind (fun started ->
             f ()
             |> E.bind (fun value ->
                    if value <> 42 then
                      E.sync (fun () -> failwith "unexpected value")
                    else
                      E.sync (fun () -> elapsed_us started)
                      |> E.map (fun elapsed -> elapsed :: acc))
             |> E.bind (loop (remaining - 1)))
  in
  loop count []

let measure_effect_blocking rt =
  let db = setup_db () in
  let stmt = setup_stmt db in
  let pool =
    E.Blocking.Pool.create ~name:"sqlite-floor-b"
      {
        max_threads = 4;
        max_queued = 64;
        queue_policy = E.Blocking.Pool.Wait;
        shutdown_policy = E.Blocking.Pool.Drain;
      }
  in
  Fun.protect
    ~finally:(fun () ->
      run_ok rt (E.Blocking.Pool.shutdown pool);
      ignore (S.finalize stmt);
      ignore (S.close db))
    (fun () ->
      ignore
        (run_ok rt
           (effect_loop warmup_count (fun () ->
                E.blocking ~pool ~name:"sqlite.floor.pk" (fun () ->
                    step_pk db stmt 1))) : float list);
      run_ok rt
        (effect_loop sample_count (fun () ->
             E.blocking ~pool ~name:"sqlite.floor.pk" (fun () -> step_pk db stmt 1))))

module Worker = struct
  type response = {
    mutex : Mutex.t;
    mutable value : (int, string) result option;
  }

  type request =
    | Pk of int * response
    | Stop

  type t = {
    mutex : Mutex.t;
    condition : Condition.t;
    queue : request Queue.t;
    read_fd : Unix.file_descr;
    write_fd : Unix.file_descr;
    mutable thread : Thread.t option;
  }

  let notify fd =
    let buf = Bytes.make 1 'x' in
    ignore (Unix.write fd buf 0 1)

  let set_response fd (response : response) value =
    Mutex.lock response.mutex;
    response.value <- Some value;
    Mutex.unlock response.mutex;
    notify fd

  let take t =
    Mutex.lock t.mutex;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock t.mutex)
      (fun () ->
        while Queue.is_empty t.queue do
          Condition.wait t.condition t.mutex
        done;
        Queue.pop t.queue)

  let create () =
    let read_fd, write_fd = Unix.pipe () in
    let mutex = Mutex.create () in
    let condition = Condition.create () in
    let queue = Queue.create () in
    let ready_mutex = Mutex.create () in
    let ready_condition = Condition.create () in
    let ready = ref None in
    let state =
      {
        mutex;
        condition;
        queue;
        read_fd;
        write_fd;
        thread = None;
      }
    in
    let thread =
      Thread.create
        (fun () ->
          let init =
            try
              let db = setup_db () in
              let stmt = setup_stmt db in
              Ok (db, stmt)
            with exn -> Error (Printexc.to_string exn)
          in
          Mutex.lock ready_mutex;
          ready := Some init;
          Condition.signal ready_condition;
          Mutex.unlock ready_mutex;
          match init with
          | Error _ -> ()
          | Ok (db, stmt) ->
              let running = ref true in
              while !running do
                match take state with
                | Stop -> running := false
                | Pk (id, response) -> (
                    match step_pk db stmt id with
                    | value -> set_response write_fd response (Ok value)
                    | exception exn ->
                        set_response write_fd response
                          (Error (Printexc.to_string exn)))
              done;
              ignore (S.finalize stmt);
              ignore (S.close db))
        ()
    in
    state.thread <- Some thread;
    Mutex.lock ready_mutex;
    while Option.is_none !ready do
      Condition.wait ready_condition ready_mutex
    done;
    let init = Option.get !ready in
    Mutex.unlock ready_mutex;
    match init with
    | Error reason ->
        Unix.close read_fd;
        Unix.close write_fd;
        failwith reason
    | Ok _ -> state

  let submit t id =
    let response = { mutex = Mutex.create (); value = None } in
    Mutex.lock t.mutex;
    Queue.push (Pk (id, response)) t.queue;
    Condition.signal t.condition;
    Mutex.unlock t.mutex;
    Eio_unix.await_readable t.read_fd;
    let buf = Bytes.create 1 in
    ignore (Unix.read t.read_fd buf 0 1);
    Mutex.lock response.mutex;
    let result = response.value in
    Mutex.unlock response.mutex;
    match result with
    | Some (Ok value) -> value
    | Some (Error reason) -> failwith reason
    | None -> failwith "worker response missing after wake"

  let shutdown t =
    Mutex.lock t.mutex;
    Queue.push Stop t.queue;
    Condition.signal t.condition;
    Mutex.unlock t.mutex;
    Option.iter Thread.join t.thread;
    Unix.close t.read_fd;
    Unix.close t.write_fd
end

let measure_pinned_worker rt =
  let worker = Worker.create () in
  Fun.protect
    ~finally:(fun () -> Worker.shutdown worker)
    (fun () ->
      ignore
        (run_ok rt
           (effect_loop warmup_count (fun () ->
                E.sync (fun () -> Worker.submit worker 1))) : float list);
      run_ok rt
        (effect_loop sample_count (fun () ->
             E.sync (fun () -> Worker.submit worker 1))))

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking = measure_effect_blocking rt in
  let pinned_worker = measure_pinned_worker rt in
  print_stats "B_effect_blocking" blocking;
  print_stats "C_pinned_worker_pipe" pinned_worker
