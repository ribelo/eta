type status = Capabilities.span_status = Ok | Error of string | Cancelled
type kind = Capabilities.span_kind = Internal | Server | Client | Producer | Consumer

type event : immutable_data = {
  ev_name : string;
  ev_ts_ms : int;
  ev_attrs : (string * string) list;
}

type link = Capabilities.span_link = {
  link_trace_id : string;
  link_span_id : string;
  link_attrs : (string * string) list;
}

type span : immutable_data = {
  span_id : int;
  parent_id : int option;
  name : string;
  attrs : (string * string) list;
  events : event list;
  links : link list;
  kind : kind;
  status : status;
  started_ms : int;
  ended_ms : int;
  trace_id : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
  external_parent : Capabilities.trace_context option;
}

type open_span = {
  span_id : int;
  span_context_id : string;
  parent_id : int option;
  name : string;
  trace_id : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
  external_parent : Capabilities.trace_context option;
  mutable attrs : (string * string) list;
  mutable events : event list;
  mutable links : link list;
  kind : kind;
  started_ms : int;
}

type fiber_state = {
  mutable stack : open_span list;
  mutable pending_attrs : (string * string) list;
  mutable pending_links : link list;
}

type in_memory = {
  context_id : int;
  mutable next_id : int;
  mutable spans : span list;
  fallback : fiber_state;
}

let fiber_context_key : (int, fiber_state) Hashtbl.t Eio.Fiber.key =
  Eio.Fiber.create_key ()

let next_context_id = ref 0

let fresh_context_id () =
  incr next_context_id;
  !next_context_id

let empty_state () = { stack = []; pending_attrs = []; pending_links = [] }

let with_fiber_context f =
  Eio.Fiber.with_binding fiber_context_key (Hashtbl.create 1) f

let fiber_context () =
  try Eio.Fiber.get fiber_context_key with Stdlib.Effect.Unhandled _ -> None

let state t =
  match fiber_context () with
  | None -> t.fallback
  | Some context -> (
      match Hashtbl.find_opt context t.context_id with
      | Some state -> state
      | None ->
          let state = empty_state () in
          Hashtbl.add context t.context_id state;
          state)

let in_memory () =
  {
    context_id = fresh_context_id ();
    next_id = 0;
    spans = [];
    fallback = empty_state ();
  }

let hex16 n = Printf.sprintf "%016x" n
let root_trace_id t span_id = hex16 t.context_id ^ hex16 (span_id + 1)

let begin_span t ?parent_id
    ?(external_parent : Capabilities.trace_context option) ?trace_id
    ?(trace_flags = 1) ?(trace_state = []) ?(baggage = [])
    ?(kind = Internal) ~name ~started_ms () =
  let state = state t in
  let span_id = t.next_id in
  t.next_id <- t.next_id + 1;
  let span_context_id = hex16 (span_id + 1) in
  let parent_id =
    match parent_id with
    | Some _ as parent -> parent
    | None -> (
        match state.stack with
        | span :: _ -> Some span.span_id
        | [] -> None)
  in
  let trace_id, trace_flags, trace_state, baggage =
    match (parent_id, external_parent, state.stack) with
    | _, Some ctx, _ ->
        (ctx.trace_id, ctx.trace_flags, ctx.trace_state, ctx.baggage)
    | Some _, None, parent :: _ ->
        (parent.trace_id, parent.trace_flags, parent.trace_state, parent.baggage)
    | _ ->
        ( Option.value trace_id ~default:(root_trace_id t span_id),
          trace_flags,
          trace_state,
          baggage )
  in
  let attrs = List.rev state.pending_attrs in
  let links = List.rev state.pending_links in
  state.pending_attrs <- [];
  state.pending_links <- [];
  state.stack <-
    {
      span_id;
      span_context_id;
      parent_id;
      name;
      trace_id;
      trace_flags;
      trace_state;
      baggage;
      external_parent;
      attrs;
      events = [];
      links;
      kind;
      started_ms;
    }
    :: state.stack;
  span_id

let find_open t span_id =
  let state = state t in
  let rec aux = function
    | [] -> None
    | s :: _ when s.span_id = span_id -> Some s
    | _ :: rest -> aux rest
  in
  aux state.stack

let end_span t ~span_id ~status ~ended_ms =
  let state = state t in
  let rec remove acc = function
    | [] -> None
    | span :: rest when span.span_id = span_id ->
        state.stack <- List.rev_append acc rest;
        Some span
    | span :: rest -> remove (span :: acc) rest
  in
  match remove [] state.stack with
  | None -> ()
  | Some span ->
      t.spans <-
        {
          span_id;
          parent_id = span.parent_id;
          name = span.name;
          trace_id = span.trace_id;
          trace_flags = span.trace_flags;
          trace_state = span.trace_state;
          baggage = span.baggage;
          external_parent = span.external_parent;
          attrs = List.rev span.attrs;
          events = List.rev span.events;
          links = List.rev span.links;
          kind = span.kind;
          status;
          started_ms = span.started_ms;
          ended_ms;
        }
        :: t.spans

let add_attr t ~key ~value =
  let state = state t in
  match state.stack with
  | span :: _ -> span.attrs <- (key, value) :: span.attrs
  | [] -> state.pending_attrs <- (key, value) :: state.pending_attrs

let add_attr_to t ~span_id ~key ~value =
  match find_open t span_id with
  | Some span -> span.attrs <- (key, value) :: span.attrs
  | None -> ()

let add_event t ~span_id ~name ~ts_ms ~attrs =
  match find_open t span_id with
  | Some s ->
      s.events <- { ev_name = name; ev_ts_ms = ts_ms; ev_attrs = attrs } :: s.events
  | None -> ()

let add_link t link =
  let state = state t in
  match state.stack with
  | s :: _ -> s.links <- link :: s.links
  | [] -> state.pending_links <- link :: state.pending_links

let add_link_to t ~span_id link =
  match find_open t span_id with
  | Some span -> span.links <- link :: span.links
  | None -> ()

let inspect t ~span_id : Capabilities.span_info option =
  match find_open t span_id with
  | Some s ->
      Some
        {
          Capabilities.trace_id = s.trace_id;
          span_id = s.span_context_id;
          name = s.name;
          trace_flags = s.trace_flags;
          trace_state = s.trace_state;
          baggage = s.baggage;
        }
  | None -> None

let as_capability t : Capabilities.tracer =
  object
    method with_fiber_context : 'a. (unit -> 'a) -> 'a = with_fiber_context

    method begin_span ?parent_id ?external_parent ?trace_id ?trace_flags
        ?trace_state ?baggage ?kind ~name ~started_ms () =
      begin_span t ?parent_id ?external_parent ?trace_id ?trace_flags
        ?trace_state ?baggage ?kind ~name ~started_ms ()

    method end_span ~span_id ~status ~ended_ms =
      end_span t ~span_id ~status ~ended_ms

    method add_attr ~key ~value = add_attr t ~key ~value
    method add_attr_to ~span_id ~key ~value = add_attr_to t ~span_id ~key ~value

    method add_event ~span_id ~name ~ts_ms ~attrs =
      add_event t ~span_id ~name ~ts_ms ~attrs

    method add_link link = add_link t link
    method add_link_to ~span_id link = add_link_to t ~span_id link

    method inspect ~span_id = inspect t ~span_id
  end

let noop : Capabilities.tracer =
  object
    method with_fiber_context : 'a. (unit -> 'a) -> 'a = fun f -> f ()

    method begin_span ?parent_id:_ ?external_parent:_ ?trace_id:_ ?trace_flags:_
        ?trace_state:_ ?baggage:_ ?kind:_ ~name:_ ~started_ms:_ () =
      -1
    method end_span ~span_id:_ ~status:_ ~ended_ms:_ = ()
    method add_attr ~key:_ ~value:_ = ()
    method add_attr_to ~span_id:_ ~key:_ ~value:_ = ()
    method add_event ~span_id:_ ~name:_ ~ts_ms:_ ~attrs:_ = ()
    method add_link _ = ()
    method add_link_to ~span_id:_ _ = ()
    method inspect ~span_id:_ = None
  end

let dump t = List.rev t.spans
