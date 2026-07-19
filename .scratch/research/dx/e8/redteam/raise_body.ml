open Eta

type error = [ `Unused ]

let program : (int, error) Effect.t =
  [%eta.result "db.boom" (failwith "boom")]

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ()
  in
  match Eta_eio.Runtime.run rt program with
  | Exit.Error (Cause.Die die) ->
      Tracer.dump tracer
      |> List.iter (fun s ->
             Printf.printf "span name=%s status=%s\n" s.Tracer.name
               (match s.status with
                | Tracer.Ok -> "ok"
                | Tracer.Error m -> "error:" ^ m
                | Tracer.Cancelled -> "cancelled"));
      Printf.printf "die=%s\n" (Printexc.to_string die.exn)
  | Exit.Error (Cause.Fail _) ->
      prerr_endline "FAIL: typed failure instead of Die";
      exit 1
  | Exit.Error _ ->
      prerr_endline "FAIL: unexpected cause";
      exit 1
  | Exit.Ok _ ->
      prerr_endline "FAIL: ok";
      exit 1
