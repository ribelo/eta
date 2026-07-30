open Eta

let events = ref []

let tracer : Capabilities.tracer =
  object
    method with_task_context : 'a. Runtime_contract.t -> (unit -> 'a) -> 'a =
      fun _ run -> run ()

    method begin_span _ ?parent_id:_ ?external_parent:_ ?trace_id:_ ?trace_flags:_
        ?trace_state:_ ?baggage:_ ?kind:_ ~name:_ ~started_ms:_ () =
      1

    method end_span _ ~span_id:_ ~status:_ ~ended_ms:_ = ()
    method add_attr _ ~key:_ ~value:_ = ()
    method add_attr_to _ ~span_id:_ ~key:_ ~value:_ = ()

    method add_event _ ~span_id:_ ~name ~ts_ms:_ ~attrs =
      events := (name, attrs) :: !events

    method add_link _ _ = ()
    method add_link_to _ ~span_id:_ _ = ()

    method inspect _ ~span_id:_ =
      Some
        {
          Capabilities.trace_id = "0af7651916cd43dd8448eb211c80319c";
          span_id = "b7ad6b7169203331";
          name = "root.defect";
          trace_flags = 1;
          trace_state = [];
          baggage = [];
        }
  end

let program =
  Effect.with_background ~name:"root.defect"
    (Effect.sync (fun () -> failwith "root-only boom"))
    (fun () -> Effect.never)

let has_defect_event () =
  List.exists
    (fun (name, attrs) ->
      String.equal name "exception"
      && List.mem_assoc "exception.type" attrs
      && List.mem_assoc "eta.cause.path" attrs)
    !events

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~tracer ()
  in
  match Runtime.run runtime program with
  | Exit.Error _ when has_defect_event () ->
      print_endline "PASS root-only tracer received defect annotation"
  | Exit.Error _ -> failwith "defect did not annotate the hand-written tracer"
  | Exit.Ok _ -> failwith "defect unexpectedly succeeded"
