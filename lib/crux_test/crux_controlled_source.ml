module Crux = Eta_crux

type state =
  | Opening
  | Running
  | Completed
  | Failed
  | Cancelled

type control_error = Wrong_state of state

type emit_error =
  | Control of control_error
  | Admission of Crux.Endpoint.admission_error

type ('spec, 'item, 'error) incarnation = {
  spec : 'spec;
  lock : Eta.Sync_lock.t;
  mutable state : state;
  mutable emitter : 'item Crux.Source.emit option;
  mutable open_resume :
    (((unit, 'error) Eta.Effect.t, 'error) Eta.Exit.t -> unit)
    option;
  mutable running_resume :
    ((unit, 'error) Eta.Exit.t -> unit) option;
  mutable terminal : (unit, 'error) Eta.Exit.t option;
}

type ('spec, 'item, 'error) t = {
  incarnations :
    (('spec, 'item, 'error) incarnation, empty) Eta.Queue.t;
}

and empty = |

let create () = { incarnations = Eta.Queue.unbounded () }

let cancel incarnation =
  Eta.Sync_lock.use incarnation.lock @@ fun () ->
  match incarnation.state with
  | Opening | Running -> incarnation.state <- Cancelled
  | Completed | Failed | Cancelled -> ()

let producer controlled spec ~emit =
  Eta.Effect.async ~register:(fun resume ->
      let incarnation =
        {
          spec;
          lock = Eta.Sync_lock.create ();
          state = Opening;
          emitter = Some emit;
          open_resume = Some resume;
          running_resume = None;
          terminal = None;
        }
      in
      (match
         Eta.Queue.try_offer_now controlled.incarnations
           incarnation
       with
      | `Sent -> ()
      | `Closed | `Full | `Dropped ->
          invalid_arg
            "Eta_crux_test.Controlled_source: observation queue rejected an incarnation"
      | `Closed_with_error (_ : empty) -> .);
      Some
        (Eta.Effect.sync (fun () -> cancel incarnation)))

let poll_incarnation controlled =
  match Eta.Queue.poll_now controlled.incarnations with
  | `Item incarnation -> Some incarnation
  | `Empty | `Closed -> None
  | `Closed_with_error (_ : empty) -> .

let await_incarnation controlled =
  Eta.Queue.take controlled.incarnations
  |> Eta.Effect.map_error (function
       | `Closed ->
           invalid_arg
             "Eta_crux_test.Controlled_source: observation queue closed"
       | `Closed_with_error (_ : empty) -> .)

let spec incarnation = incarnation.spec

let state incarnation =
  Eta.Sync_lock.use incarnation.lock @@ fun () ->
  incarnation.state

let running_effect incarnation =
  Eta.Effect.async ~register:(fun resume ->
      let terminal =
        Eta.Sync_lock.use incarnation.lock @@ fun () ->
        incarnation.running_resume <- Some resume;
        incarnation.terminal
      in
      Option.iter resume terminal;
      Some
        (Eta.Effect.sync (fun () -> cancel incarnation)))

let open_ incarnation =
  let resume =
    Eta.Sync_lock.use incarnation.lock @@ fun () ->
    match incarnation.state, incarnation.open_resume with
    | Opening, Some resume ->
        incarnation.state <- Running;
        incarnation.open_resume <- None;
        Ok resume
    | state, _ -> Error (Wrong_state state)
  in
  match resume with
  | Error _ as error -> error
  | Ok resume ->
      resume (Eta.Exit.Ok (running_effect incarnation));
      Ok ()

let fail_open incarnation error =
  let resume =
    Eta.Sync_lock.use incarnation.lock @@ fun () ->
    match incarnation.state, incarnation.open_resume with
    | Opening, Some resume ->
        incarnation.state <- Failed;
        incarnation.open_resume <- None;
        Ok resume
    | state, _ -> Error (Wrong_state state)
  in
  match resume with
  | Error _ as result -> result
  | Ok resume ->
      resume (Eta.Exit.Error (Eta.Cause.fail error));
      Ok ()

let emit incarnation item =
  let emitter =
    Eta.Sync_lock.use incarnation.lock @@ fun () ->
    match incarnation.state, incarnation.emitter with
    | Running, Some emitter -> Ok emitter
    | state, _ -> Error (Control (Wrong_state state))
  in
  match emitter with
  | Error error -> Eta.Effect.fail error
  | Ok emitter ->
      emitter item
      |> Eta.Effect.map_error (fun error -> Admission error)

let finish incarnation state exit =
  let result =
    Eta.Sync_lock.use incarnation.lock @@ fun () ->
    match incarnation.state with
    | Running ->
        incarnation.state <- state;
        incarnation.terminal <- Some exit;
        Ok incarnation.running_resume
    | current -> Error (Wrong_state current)
  in
  match result with
  | Error _ as error -> error
  | Ok resume ->
      Option.iter (fun resume -> resume exit) resume;
      Ok ()

let complete incarnation =
  finish incarnation Completed (Eta.Exit.Ok ())

let fail incarnation error =
  finish incarnation Failed
    (Eta.Exit.Error (Eta.Cause.fail error))

let captured_emitter incarnation =
  Eta.Sync_lock.use incarnation.lock @@ fun () ->
  incarnation.emitter

let expect_no_pending controlled =
  match poll_incarnation controlled with
  | None -> ()
  | Some _ ->
      Alcotest.fail
        "Eta_crux_test.Controlled_source has an unobserved incarnation"
