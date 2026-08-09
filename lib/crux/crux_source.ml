open Crux_engine

type 'error terminal =
  | Completed
  | Failed of 'error

type 'item emit =
  'item ->
  (unit, Endpoint.admission_error) Eta.Effect.t

type ('item, 'error) producer =
  emit:'item emit ->
  ((unit, 'error) Eta.Effect.t, 'error) Eta.Effect.t

type ('item, 'error, 'action) mapping = {
  mutable target : 'action Endpoint.t;
  mutable on_item : 'item -> 'action;
  mutable on_terminal : 'error terminal -> 'action;
}

let source_open producer spec mapping ~scope =
  let open Eta.Syntax in
  let emit item =
    Endpoint.send_owned mapping.target ~scope (mapping.on_item item)
  in
  let terminal outcome =
    Endpoint.send_owned mapping.target ~scope
      (mapping.on_terminal outcome)
    |> Eta.Effect.ignore_errors
  in
  let* opened =
    producer spec ~emit
    |> Eta.Effect.to_result
  in
  match opened with
  | Error error ->
      Eta.Effect.pure (Some (terminal (Failed error)))
  | Ok running ->
      let running =
        let* outcome = Eta.Effect.to_result running in
        match outcome with
        | Ok () -> terminal Completed
        | Error error -> terminal (Failed error)
      in
      Eta.Effect.pure (Some running)

let create ~spec_cutoff ~spec ~producer ~target ~on_item ~on_terminal =
  make @@ fun ctx ->
  let (module S) = unpack_package ctx in
  let spec_signal : ('spec * contribution) S.signal =
    unpack_signal (spec.compile ctx)
  in
  let producer_signal : ('producer * contribution) S.signal =
    unpack_signal (producer.compile ctx)
  in
  let target_signal : ('action Endpoint.t * contribution) S.signal =
    unpack_signal (target.compile ctx)
  in
  let on_item_signal : (('item -> 'action) * contribution) S.signal =
    unpack_signal (on_item.compile ctx)
  in
  let on_terminal_signal
      : (('error terminal -> 'action) * contribution) S.signal =
    unpack_signal (on_terminal.compile ctx)
  in
  let pair left right =
    S.map2
      (fun (left_value, left_contribution)
           (right_value, (right_contribution : contribution)) ->
        ( (left_value, right_value),
          contribution_append left_contribution right_contribution ))
      left right
  in
  let inputs =
    pair spec_signal
      (pair producer_signal
         (pair target_signal (pair on_item_signal on_terminal_signal)))
  in
  (* The open node republishes only when [spec_cutoff] rejects the previous
     spec. Each publication allocates one scope, one mapping, and one open
     work; the root stages them when the frame carrying them is installed.
     Computes discarded by the cutoff allocate inert garbage because a
     blocked publication never reaches a frame. *)
  let openings =
    S.map
      ~cutoff:
        (Eta_signal.Cutoff.of_equal (fun (left, _) (right, _) ->
             spec_cutoff (fst left) (fst right)))
      (fun ( (spec_value, (producer_value, (target_value, (on_item_value, on_terminal_value)))),
             (_input_contribution : contribution) )
         ->
        let scope = fresh_scope ctx.ctx_root ~parent:ctx.ctx_scope in
        let mapping =
          {
            target = target_value;
            on_item = on_item_value;
            on_terminal = on_terminal_value;
          }
        in
        let work =
          {
            scope = scope.id;
            origin = Failure.Owned_work;
            trigger = Failure.Source_opening;
            payload =
              Source_open
                (source_open producer_value spec_value mapping
                   ~scope:scope.id);
          }
        in
        ( (spec_value, mapping),
          {
            contribution_empty with
            works = [ work ];
            added_scopes = [ scope ];
          } ))
      inputs
  in
  (* Mapper refresh is a structural commit hook. Stabilization can construct
     the hook, but only frame installation can mutate the live mapping. *)
  pack_signal
    (S.map2
       (fun ((_, mapping), (open_contribution : contribution))
            ( (_, (_, (target_value, (on_item_value, on_terminal_value)))),
              (refresh_contribution : contribution) )
         ->
         let refresh () =
           mapping.target <- target_value;
           mapping.on_item <- on_item_value;
           mapping.on_terminal <- on_terminal_value
         in
         let contribution =
           contribution_append open_contribution refresh_contribution
         in
         ( (),
           {
             contribution with
             commit_hooks = refresh :: contribution.commit_hooks;
           } ))
       openings inputs)
