open Eta

type error = [ `Impossible ] [@@deriving eta_error]

let render_send = function
  | `Sent -> "sent"
  | `Dropped -> "dropped"
  | `Full -> "full"
  | `Closed -> "closed"
  | `Closed_with_error (`Upstream_failed reason) -> "closed:" ^ reason

let render_recv = function
  | `Item value -> "item:" ^ value
  | `Empty -> "empty"
  | `Closed -> "closed"
  | `Closed_with_error (`Upstream_failed reason) -> "closed:" ^ reason

let program () =
  let open Syntax in
  let queue = Queue.unbounded () in
  let* empty = Queue.poll queue in
  let* sent = Queue.try_offer queue "alpha" in
  let* first = Queue.poll queue in
  let stats_after_drain = Queue.stats queue in
  let* () = Queue.close_with_error_effect queue (`Upstream_failed "done") in
  let* closed_send = Queue.try_offer queue "beta" in
  let+ closed_recv = Queue.poll queue in
  (empty, sent, first, stats_after_drain, closed_send, closed_recv)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program ()) with
  | Exit.Ok (empty, sent, first, stats_after_drain, closed_send, closed_recv)
    -> (
      match
        ( render_recv empty,
          render_send sent,
          render_recv first,
          stats_after_drain.Queue.depth,
          stats_after_drain.Queue.sent,
          stats_after_drain.Queue.received,
          render_send closed_send,
          render_recv closed_recv )
      with
      | "empty", "sent", "item:alpha", 0, 1, 1, "closed:done", "closed:done" ->
          Format.printf
            "queue-probe:empty=%s sent=%s first=%s depth=%d counters=%d/%d \
             closed_send=%s closed_recv=%s@."
            (render_recv empty) (render_send sent) (render_recv first)
            stats_after_drain.Queue.depth stats_after_drain.Queue.sent
            stats_after_drain.Queue.received (render_send closed_send)
            (render_recv closed_recv)
      | _ ->
          Format.eprintf "queue probe produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "queue probe failed: %a@." (Cause.pp pp_error) cause;
      exit 1
