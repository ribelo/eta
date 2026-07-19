open Eta

type upstream_error = [ `Upstream_failed of string ] [@@deriving eta_error]

type error =
  [ `Closed
  | `Closed_with_error of upstream_error [@eta.render pp_upstream_error] ]
[@@deriving eta_error]

let render_close = function
  | `Closed -> "closed"
  | `Closed_with_error (`Upstream_failed reason) -> "closed:" ^ reason

let wait_blocked_sender ch =
  Effect.sync (fun () ->
      let rec loop attempts =
        if (Channel.stats ch).Channel.waiting_senders = 1 then ()
        else if attempts = 0 then failwith "channel sender did not block"
        else (
          Eio.Fiber.yield ();
          loop (attempts - 1))
      in
      loop 1_000)

let producer ch =
  let open Syntax in
  let* () = Channel.send ch "first" in
  let* () = Channel.send ch "second" in
  Channel.close_with_error_effect ch (`Upstream_failed "done")

let program () =
  let open Syntax in
  let ch = Channel.create ~capacity:1 () in
  Effect.with_background ~name:"channel.producer" (producer ch) (fun () ->
      let* () = wait_blocked_sender ch in
      let stats_while_blocked = Channel.stats ch in
      let* first = Channel.recv ch in
      let* second = Channel.recv ch in
      let* closed =
        Channel.recv ch
        |> Effect.map (fun msg -> "unexpected:" ^ msg)
        |> Effect.fold ~ok:Fun.id ~error:render_close
      in
      let final_stats = Channel.stats ch in
      Effect.pure (first, second, closed, stats_while_blocked, final_stats))

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program ()) with
  | Exit.Ok (first, second, closed, blocked_stats, final_stats) -> (
      match
        ( first,
          second,
          closed,
          blocked_stats.Channel.depth,
          blocked_stats.Channel.waiting_senders,
          final_stats.Channel.sent,
          final_stats.Channel.received,
          final_stats.Channel.closed )
      with
      | "first", "second", "closed:done", 1, 1, 2, 2, true ->
          Format.printf
            "channel:first=%s second=%s closed=%s blocked=%d/%d sent=%d \
             received=%d@."
            first second closed blocked_stats.Channel.depth
            blocked_stats.Channel.waiting_senders final_stats.Channel.sent
            final_stats.Channel.received
      | _ ->
          Format.eprintf "channel produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "channel failed: %a@." (Cause.pp pp_error) cause;
      exit 1
