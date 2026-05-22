open Eta

let fd_count () =
  try Array.length (Sys.readdir "/proc/self/fd") with
  | Sys_error _ -> -1

let yield_many n =
  for _ = 1 to n do
    Eio.Fiber.yield ()
  done

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let cleanup_ran = ref false in
  let permit = ref 0 in
  let never, _resolve_never = Eio.Promise.create () in
  let before_fd = fd_count () in
  incr permit;
  let effect =
    Effect.sync "h_s4a_blocked_loser" (fun () ->
      Fun.protect
        ~finally:(fun () ->
          cleanup_ran := true;
          decr permit)
        (fun () -> Eio.Promise.await never))
    |> Effect.timeout (Duration.ms 20)
  in
  let outcome =
    match Runtime.run rt effect with
    | Exit.Error (Cause.Fail `Timeout) -> "timeout_fail"
    | Exit.Error (Cause.Interrupt _) -> "interrupt"
    | Exit.Error cause ->
        Format.asprintf "other_error:%a"
          (Cause.pp (fun fmt (`Timeout : [ `Timeout ]) ->
             Format.pp_print_string fmt "Timeout"))
          cause
    | Exit.Ok () -> "ok"
  in
  yield_many 10;
  let after_fd = fd_count () in
  Printf.printf
    "h_s4a_timeout_taxonomy outcome=%s cleanup_ran=%b permit=%d fd_before=%d fd_after=%d fd_delta=%d\n%!"
    outcome
    !cleanup_ran
    !permit
    before_fd
    after_fd
    (if before_fd < 0 || after_fd < 0 then 0 else after_fd - before_fd)
