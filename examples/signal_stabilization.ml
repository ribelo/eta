open Eta

module Signal = Eta_signal.Make_no_error ()

let absurd_observer_error : Signal.observer_error -> 'a = function
  | (_ : Signal.observer_error) -> .

(* Enumerate public tags from Eta_signal signatures rather than inheriting rows. *)

type error =
  [ `Ambiguous_scope
  | `Counter_overflow of string
  | `Cycle
  | `Invalid_scope
  | `Reentrant_stabilization
  | `Runtime_mismatch
  | `Reentrant_update
  | `Disposed_observer
  | `No_current_value
  | `Uninitialized_observer
  | `Invalid_capacity ]
[@@deriving eta_error]

let widen
    (eff :
      ('a, [< error | `Observer_error of Signal.observer_error ]) Effect.t) :
    ('a, error) Effect.t =
  Effect.map_error
    (function
      | `Observer_error error -> absurd_observer_error error
      | #error as error -> error)
    eff

let program =
  let open Syntax in
  let source = Signal.Var.create 1 in
  let derived = Signal.Var.watch source |> Signal.map (fun value -> value * 2) in
  let* observer, stream = Signal.Stream.observe derived |> widen in
  let* () = Signal.stabilize |> widen in
  let* first = Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect |> widen in
  let* () = Signal.Var.set source 2 |> widen in
  let* before = Signal.Observer.read observer |> widen in
  let* () = Signal.stabilize |> widen in
  let* after = Signal.Observer.read observer |> widen in
  let* second =
    Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect |> widen
  in
  let* () = Signal.Observer.dispose observer |> widen in
  let* rest = Eta_stream.run_collect stream |> widen in
  Effect.pure (before, after, first, second, rest)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt program with
  | Exit.Ok
      ( 2,
        4,
        [ Signal.Initialized 2 ],
        [ Signal.Changed { old_value = 2; new_value = 4 } ],
        [] ) ->
      Format.printf "signal:before=2 after=4 stream=closed@."
  | Exit.Ok _ ->
      Format.eprintf "signal example produced unexpected values@.";
      exit 1
  | Exit.Error cause ->
      Format.eprintf "signal example failed: %a@." (Cause.pp pp_error) cause;
      exit 1
