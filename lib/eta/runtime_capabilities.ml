let logger : Capabilities.logger =
  object
    method log _ = ()
  end

let meter : Capabilities.meter =
  object
    method record _ = ()
  end

let tracer : Capabilities.tracer =
  object
    method with_task_context : 'a. Runtime_contract.t -> (unit -> 'a) -> 'a =
      fun _ f -> f ()

    method begin_span _ ?parent_id:_ ?external_parent:_ ?trace_id:_ ?trace_flags:_
        ?trace_state:_ ?baggage:_ ?kind:_ ~name:_ ~started_ms:_ () =
      -1

    method end_span _ ~span_id:_ ~status:_ ~ended_ms:_ = ()
    method add_attr _ ~key:_ ~value:_ = ()
    method add_attr_to _ ~span_id:_ ~key:_ ~value:_ = ()
    method add_event _ ~span_id:_ ~name:_ ~ts_ms:_ ~attrs:_ = ()
    method add_link _ _ = ()
    method add_link_to _ ~span_id:_ _ = ()
    method inspect _ ~span_id:_ = None
  end
