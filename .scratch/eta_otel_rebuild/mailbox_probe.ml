open Eta
open Stream

type t = {
  mailbox : int Mailbox.t;
  seen : int list ref;
}

let start ~sw ~clock =
  let mailbox = Mailbox.create ~capacity:16 () in
  let seen = ref [] in
  let rt = Runtime.create ~sw ~clock () in
  let consume =
    Mailbox.to_stream mailbox
    |> Stream.map_effect (fun n ->
           Effect.named "mailbox.record" (Effect.sync (fun () -> seen := n :: !seen)))
    |> run_drain
  in
  match Runtime.run rt (Effect.Private.daemon consume) with
  | Exit.Ok () -> { mailbox; seen }
  | Exit.Error cause ->
      Format.eprintf "daemon start failed: %a@." (Cause.pp Format.pp_print_string) cause;
      exit 2

let submit t n =
  match Mailbox.offer t.mailbox n with
  | Enqueued -> ()
  | Dropped -> failwith "mailbox dropped unexpectedly"
  | Closed -> failwith "mailbox closed unexpectedly"

let wait_until_seen t expected =
  let rec loop attempts =
    if List.length !(t.seen) >= expected then ()
    else if attempts = 0 then failwith "timed out waiting for mailbox"
    else (
      Eio.Fiber.yield ();
      loop (attempts - 1))
  in
  loop 100

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let t = start ~sw ~clock:(Eio.Stdenv.clock stdenv) in
  submit t 1;
  submit t 2;
  submit t 3;
  wait_until_seen t 3;
  match List.rev !(t.seen) with
  | [ 1; 2; 3 ] -> print_endline "mailbox_probe ok"
  | xs ->
      Format.eprintf "unexpected order: [%s]@."
        (String.concat "; " (List.map string_of_int xs));
      exit 1
