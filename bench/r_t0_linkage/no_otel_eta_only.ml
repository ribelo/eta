open Eta

let rec chain n acc =
  if n = 0 then acc
  else chain (n - 1) (Effect.bind (fun x -> Effect.pure (x + 1)) acc)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Runtime.run rt (chain 1_000 (Effect.pure 0)) with
  | Exit.Ok 1_000 -> print_endline "no_otel_eta_only=ok"
  | Exit.Ok n -> Printf.eprintf "unexpected result: %d\n" n; exit 1
  | Exit.Error _ -> print_endline "unexpected error"; exit 1

