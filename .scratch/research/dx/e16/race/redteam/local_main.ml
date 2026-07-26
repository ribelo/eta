open Eta

let run_value () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let released = ref false in
  let clock = Value_passing.{ now_ms = (fun () -> 42) } in
  let users = Value_passing.{ first = "alice"; second = "bob" } in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (Local_value.program_with_override clock released users) with
  | Exit.Ok result when !released -> result
  | Exit.Ok _ -> failwith "value local probe did not release"
  | Exit.Error cause ->
      failwith
        (Format.asprintf "value local probe failed: %a"
           (Cause.pp Value_passing.pp_error) cause)

let run_reader () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let released = ref false in
  let env =
    Reader_port.
      {
        clock = { now_ms = (fun () -> 42) };
        released;
        users = { first = "alice"; second = "bob" };
      }
  in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (Reader.run env Local_reader.program_with_override) with
  | Exit.Ok result when !released -> result
  | Exit.Ok _ -> failwith "Reader local probe did not release"
  | Exit.Error cause ->
      failwith
        (Format.asprintf "Reader local probe failed: %a"
           (Cause.pp Reader_port.pp_error) cause)

let () =
  let expected = ("alice@42", "carol@42") in
  if run_value () <> expected || run_reader () <> expected then
    failwith "local probes did not apply the subtree override";
  Format.printf "local-redteam:alice@42,carol@42 both-released=true@."
