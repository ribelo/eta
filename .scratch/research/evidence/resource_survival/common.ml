open Effet

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error _ -> failwith "expected Ok"

module Test_clock = struct
  type sleeper = { deadline_ms : int; resolver : unit Eio.Promise.u }
  type t = { mutable now_ms : int; mutable sleepers : sleeper list }

  let create () = { now_ms = 0; sleepers = [] }

  let wake_due t =
    let due, pending =
      List.partition (fun sleeper -> sleeper.deadline_ms <= t.now_ms) t.sleepers
    in
    t.sleepers <- pending;
    List.iter (fun sleeper -> Eio.Promise.resolve sleeper.resolver ()) due

  let sleep t duration =
    let deadline_ms = t.now_ms + Duration.to_ms duration in
    if deadline_ms <= t.now_ms then ()
    else
      let promise, resolver = Eio.Promise.create () in
      t.sleepers <- { deadline_ms; resolver } :: t.sleepers;
      Eio.Promise.await promise

  let adjust t duration =
    t.now_ms <- t.now_ms + Duration.to_ms duration;
    wake_due t

  let sleeper_count t = List.length t.sleepers
end

let yield () = Eio.Fiber.yield ()

let wait_for_sleepers clock expected =
  let attempts = ref 0 in
  while Test_clock.sleeper_count clock < expected && !attempts < 20 do
    incr attempts;
    yield ()
  done

let with_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  f rt

let with_test_clock f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Test_clock.create () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Test_clock.sleep clock) ~env:() ()
  in
  f clock rt

let check_int name expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %d, got %d" name expected actual)

let check_strings name expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: unexpected string list" name)
