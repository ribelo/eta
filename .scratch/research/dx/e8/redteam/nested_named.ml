open Eta

type error = [ `Unused ]

let program : (int, error) Effect.t =
  Effect.named "outer" [%eta.result "inner" (Ok 1)]

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ()
  in
  match Eta_eio.Runtime.run rt program with
  | Exit.Ok _ ->
      Tracer.dump tracer
      |> List.iter (fun s ->
             Printf.printf "span name=%s parent=%s\n" s.Tracer.name
               (match s.parent_id with
                | None -> "none"
                | Some id -> string_of_int id))
  | Exit.Error _ ->
      prerr_endline "FAIL";
      exit 1
