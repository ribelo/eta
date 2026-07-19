open Eta

type bus_failed = [ `Bus_failed of string ] [@@deriving eta_error]

type error =
  [ `Closed
  | `Closed_with_error of bus_failed [@eta.render pp_bus_failed] ]
[@@deriving eta_error]

let render_close = function
  | `Closed -> "closed"
  | `Closed_with_error (`Bus_failed reason) -> "closed:" ^ reason

let program () =
  let open Syntax in
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  let@ sub = Pubsub.subscribe hub in
  let* published = Pubsub.publish hub "created" in
  let* first = Pubsub.recv sub in
  let* () = Pubsub.close_with_error_effect hub (`Bus_failed "broker") in
  let* closed =
    Pubsub.recv sub
    |> Effect.map (fun msg -> "unexpected:" ^ msg)
    |> Effect.fold ~ok:Fun.id ~error:render_close
  in
  let stats = Pubsub.stats hub in
  Effect.pure
    (published, first, closed, stats)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program ()) with
  | Exit.Ok (published, first, closed, stats) -> (
      match
        ( published.Pubsub.subscriber_count,
          published.Pubsub.dropped,
          first,
          closed,
          stats.Pubsub.subscribers,
          stats.Pubsub.received,
          stats.Pubsub.closed )
      with
      | 1, 0, "created", "closed:broker", 1, 1, true ->
          Format.printf
            "pubsub:published=%d first=%s closed=%s subscribers=%d received=%d@."
            published.Pubsub.subscriber_count first closed
            stats.Pubsub.subscribers stats.Pubsub.received
      | _ ->
          Format.eprintf "pubsub produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "pubsub failed: %a@." (Cause.pp pp_error) cause;
      exit 1
