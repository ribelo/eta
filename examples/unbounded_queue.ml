open Eta

type upstream_error = [ `Upstream_failed of string ]
type error = [ `Closed | `Closed_with_error of upstream_error | `Dropped ]

let render_close = function
  | `Closed -> "closed"
  | `Closed_with_error (`Upstream_failed reason) -> "closed:" ^ reason
  | `Dropped -> "dropped"

let producer queue =
  let open Syntax in
  let* () = Queue.send queue "alpha" in
  let* () = Queue.send queue "beta" in
  let* () = Queue.send queue "gamma" in
  Queue.close_with_error_effect queue (`Upstream_failed "done")

let program () =
  let open Syntax in
  let queue = Queue.create () in
  let* () = producer queue in
  let stats_after_send = Queue.stats queue in
  let* first = Queue.recv queue in
  let* second = Queue.recv queue in
  let* third = Queue.recv queue in
  let* closed =
    Queue.recv queue
    |> Effect.map (fun msg -> "unexpected:" ^ msg)
    |> Effect.recover render_close
  in
  let final_stats = Queue.stats queue in
  Effect.pure
    (first, second, third, closed, stats_after_send, final_stats)

let pp_error fmt err =
  Format.pp_print_string fmt (render_close err)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program ()) with
  | Exit.Ok (first, second, third, closed, after_send, final_stats) -> (
      match
        ( first,
          second,
          third,
          closed,
          after_send.Queue.depth,
          after_send.Queue.waiting_receivers,
          final_stats.Queue.sent,
          final_stats.Queue.received,
          final_stats.Queue.closed )
      with
      | "alpha", "beta", "gamma", "closed:done", 3, 0, 3, 3, true ->
          Format.printf
            "queue:first=%s second=%s third=%s closed=%s depth=%d waiting=%d \
             sent=%d received=%d@."
            first second third closed after_send.Queue.depth
            after_send.Queue.waiting_receivers final_stats.Queue.sent
            final_stats.Queue.received
      | _ ->
          Format.eprintf "queue produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "queue failed: %a@." (Cause.pp pp_error) cause;
      exit 1
