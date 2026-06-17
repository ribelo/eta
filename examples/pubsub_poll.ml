open Eta

type error = [ `Bus_failed of string ]

let render_recv = function
  | `Item value -> "item:" ^ value
  | `Empty -> "empty"
  | `Closed -> "closed"
  | `Closed_with_error (`Bus_failed reason) -> "closed:" ^ reason

let program () =
  let open Syntax in
  let hub = Pubsub.create ~overflow:Pubsub.Unbounded () in
  let@ sub = Pubsub.subscribe hub in
  let* empty = Pubsub.try_recv sub in
  let* published = Pubsub.publish hub "created" in
  let* first = Pubsub.try_recv sub in
  let* () = Pubsub.close_with_error_effect hub (`Bus_failed "broker") in
  let* closed = Pubsub.try_recv sub in
  let stats = Pubsub.stats hub in
  Effect.pure
    (empty, published, first, closed, stats)

let pp_error fmt err =
  Format.pp_print_string fmt (render_recv err)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program ()) with
  | Exit.Ok (empty, published, first, closed, stats) -> (
      match
        ( render_recv empty,
          published.Pubsub.subscriber_count,
          published.Pubsub.dropped,
          render_recv first,
          render_recv closed,
          stats.Pubsub.subscribers,
          stats.Pubsub.received,
          stats.Pubsub.closed )
      with
      | "empty", 1, 0, "item:created", "closed:broker", 1, 1, true ->
          Format.printf
            "pubsub-poll:empty=%s published=%d first=%s closed=%s \
             subscribers=%d received=%d@."
            (render_recv empty) published.Pubsub.subscriber_count
            (render_recv first) (render_recv closed) stats.Pubsub.subscribers
            stats.Pubsub.received
      | _ ->
          Format.eprintf "pubsub poll produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "pubsub poll failed: %a@." (Cause.pp pp_error) cause;
      exit 1
