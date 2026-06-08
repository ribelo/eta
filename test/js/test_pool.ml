open Test_support

let pool_create_runtime runtime ?max_idle ~opened ~closed () =
  let open Eta_js in
  let acquire =
    Effect.sync (fun () ->
        incr opened;
        !opened)
  in
  let release conn =
    Effect.sync (fun () -> closed := conn :: !closed)
  in
  match
    Runtime.run_now runtime
      (Pool.create ~max_size:2 ?max_idle ~acquire ~release ())
  with
  | Some (Exit.Ok pool) -> pool
  | Some (Exit.Error _) -> fail "Pool.create" "expected ok" |> raise
  | None -> fail "Pool.create" "expected sync exit" |> raise

let tests =
  [
    ("pool_sync",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let opened = ref 0 in
       let closed = ref [] in
       let pool = pool_create_runtime runtime ~opened ~closed () in
       (match Runtime.run_now runtime (Pool.shutdown pool) with
       | Some exit -> check_exit_ok_unit "Pool.shutdown" exit
       | None -> fail "Pool.shutdown" "expected sync exit" |> raise);
       let stats = Pool.stats pool in
       check "Pool.shutting_down" stats.shutting_down;
       check_equal_int "Pool.closed empty" 0 stats.closed;
       check "Pool.release empty" (!closed = []);
       (match Runtime.run_now runtime (Pool.with_resource pool Effect.pure) with
       | Some (Exit.Error (Cause.Fail `Pool_shutdown)) -> ()
       | _ -> fail "Pool.with_resource after shutdown" "expected Pool_shutdown" |> raise);
       Js.Promise.resolve ());
    ("pool_cancel",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let opened = ref 0 in
       let closed = ref [] in
       let pool = pool_create_runtime runtime ~max_idle:0 ~opened ~closed () in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Error (Cause.Fail `Timeout) -> ()
             | _ -> fail "Pool.with_resource cancellation" "expected timeout" |> raise);
             let stats = Pool.stats pool in
             check_equal_int "Pool.active after cancellation" 0 stats.active;
             check_equal_int "Pool.closed after cancellation" 1 stats.closed;
             check "Pool.release after cancellation" (!closed = [ 1 ]);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Effect.timeout Duration.zero
                 (Pool.with_resource pool (fun _conn ->
                      Effect.delay (Duration.ms 10) Effect.unit))))
       in
       p1);
  ]
