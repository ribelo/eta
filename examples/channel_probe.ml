open Eta

type upstream_error = [ `Upstream_failed of string ]

let render_send = function
  | `Sent -> "sent"
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
  let ch = Channel.create ~capacity:1 () in
  let* empty = Channel.try_recv ch in
  let* sent = Channel.try_send ch "alpha" in
  let* full = Channel.try_send ch "beta" in
  let* first = Channel.try_recv ch in
  let stats_after_drain = Channel.stats ch in
  let* () = Channel.close_with_error_effect ch (`Upstream_failed "done") in
  let* closed_send = Channel.try_send ch "gamma" in
  let+ closed_recv = Channel.try_recv ch in
  ( empty,
    sent,
    full,
    first,
    stats_after_drain,
    closed_send,
    closed_recv )

let pp_error fmt = function _ -> Format.pp_print_string fmt "impossible"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program ()) with
  | Exit.Ok
      ( empty,
        sent,
        full,
        first,
        stats_after_drain,
        closed_send,
        closed_recv ) -> (
      match
        ( render_recv empty,
          render_send sent,
          render_send full,
          render_recv first,
          stats_after_drain.Channel.depth,
          stats_after_drain.Channel.sent,
          stats_after_drain.Channel.received,
          render_send closed_send,
          render_recv closed_recv )
      with
      | "empty", "sent", "full", "item:alpha", 0, 1, 1, "closed:done", "closed:done" ->
          Format.printf
            "channel-probe:empty=%s sent=%s full=%s first=%s depth=%d \
             counters=%d/%d closed_send=%s closed_recv=%s@."
            (render_recv empty) (render_send sent) (render_send full)
            (render_recv first) stats_after_drain.Channel.depth
            stats_after_drain.Channel.sent stats_after_drain.Channel.received
            (render_send closed_send) (render_recv closed_recv)
      | _ ->
          Format.eprintf "channel probe produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "channel probe failed: %a@." (Cause.pp pp_error) cause;
      exit 1
