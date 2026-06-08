module C = Blocking_research_common
module Pool = Blocking_research_pool

let iterations = 4_000_000
let items = List.init 16 (fun i -> i + 1)

let cpu_work n =
  let rec loop i acc =
    if i = 0 then acc
    else loop (i - 1) (((acc lxor (i * 33)) + n) land 0x3fffffff)
  in
  loop iterations n

let (cpu_work_portable @ portable) n =
  let rec loop i acc =
    if i = 0 then acc
    else loop (i - 1) (((acc lxor (i * 33)) + n) land 0x3fffffff)
  in
  loop iterations n

let config =
  {
    Pool.max_threads = 4;
    max_queued = 32;
    idle_timeout = 30.0;
    shutdown_timeout = Some 1.0;
    queue_policy = Wait;
  }

open Effet

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let island_pool = Effect.Island.Pool.create ~domains:2 () in
  Fun.protect
    ~finally:(fun () -> Effect.Island.Pool.shutdown island_pool)
    (fun () ->
      let rt =
        Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~island_pool ()
      in
      let result, heartbeat, elapsed_us =
        C.with_heartbeat (fun () ->
            match Runtime.run rt (Effect.Island.map ~name:"cpu.island" ~f:cpu_work_portable items) with
            | Exit.Ok values -> ignore values
            | Exit.Error cause ->
                failwith (Format.asprintf "%a" (Cause.pp Format.pp_print_string) cause))
      in
      C.print_summary "cpu_island_pool"
        ([
           ("items", string_of_int (List.length items));
           ("verdict", match result with Ok () -> "ok" | Error (exn, _) -> Printexc.to_string exn);
           ("elapsed_us", string_of_int elapsed_us);
         ]
        @ C.latency_fields "heartbeat" heartbeat))

