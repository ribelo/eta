type status = Capabilities.span_status = Ok | Error of string | Cancelled

type event = {
  ev_name : string;
  ev_ts_ms : int;
  ev_attrs : (string * string) list;
}

type link = Capabilities.span_link = {
  link_trace_id : string;
  link_span_id : string;
  link_attrs : (string * string) list;
}

type span = {
  span_id : int;
  parent_id : int option;
  name : string;
  attrs : (string * string) list;
  events : event list;
  links : link list;
  status : status;
  started_ms : int;
  ended_ms : int;
  trace_id : string;
  external_parent : (string * string) option;
}

type open_span = {
  span_id : int;
  parent_id : int option;
  name : string;
  trace_id : string;
  external_parent : (string * string) option;
  mutable attrs : (string * string) list;
  mutable events : event list;
  mutable links : link list;
  started_ms : int;
}

type in_memory = {
  mutable next_id : int;
  mutable stack : open_span list;
  mutable spans : span list;
  mutable pending_attrs : (string * string) list;
  mutable pending_links : link list;
}

let in_memory () =
  {
    next_id = 0;
    stack = [];
    spans = [];
    pending_attrs = [];
    pending_links = [];
  }

let begin_span t ?parent_id ?external_parent ~name ~started_ms () =
  let span_id = t.next_id in
  t.next_id <- t.next_id + 1;
  let parent_id =
    match parent_id with
    | Some _ as parent -> parent
    | None -> (
        match t.stack with
        | span :: _ -> Some span.span_id
        | [] -> None)
  in
  let trace_id = "" in
  let attrs = List.rev t.pending_attrs in
  let links = List.rev t.pending_links in
  t.pending_attrs <- [];
  t.pending_links <- [];
  t.stack <-
    {
      span_id;
      parent_id;
      name;
      trace_id;
      external_parent;
      attrs;
      events = [];
      links;
      started_ms;
    }
    :: t.stack;
  span_id

let find_open t span_id =
  let rec aux = function
    | [] -> None
    | s :: _ when s.span_id = span_id -> Some s
    | _ :: rest -> aux rest
  in
  aux t.stack

let end_span t ~span_id ~status ~ended_ms =
  let rec remove acc = function
    | [] -> None
    | span :: rest when span.span_id = span_id ->
        t.stack <- List.rev_append acc rest;
        Some span
    | span :: rest -> remove (span :: acc) rest
  in
  match remove [] t.stack with
  | None -> ()
  | Some span ->
      t.spans <-
        {
          span_id;
          parent_id = span.parent_id;
          name = span.name;
          trace_id = span.trace_id;
          external_parent = span.external_parent;
          attrs = List.rev span.attrs;
          events = List.rev span.events;
          links = List.rev span.links;
          status;
          started_ms = span.started_ms;
          ended_ms;
        }
        :: t.spans

let add_attr t ~key ~value =
  match t.stack with
  | span :: _ -> span.attrs <- (key, value) :: span.attrs
  | [] -> t.pending_attrs <- (key, value) :: t.pending_attrs

let add_event t ~span_id ~name ~ts_ms ~attrs =
  match find_open t span_id with
  | Some s ->
      s.events <- { ev_name = name; ev_ts_ms = ts_ms; ev_attrs = attrs } :: s.events
  | None -> ()

let add_link t link =
  match t.stack with
  | s :: _ -> s.links <- link :: s.links
  | [] -> t.pending_links <- link :: t.pending_links

let inspect t ~span_id : Capabilities.span_info option =
  match find_open t span_id with
  | Some s ->
      Some
        {
          Capabilities.trace_id = s.trace_id;
          span_id = "";
          name = s.name;
        }
  | None -> None

let as_capability t : Capabilities.tracer =
  object
    method begin_span ?parent_id ?external_parent ~name ~started_ms () =
      begin_span t ?parent_id ?external_parent ~name ~started_ms ()

    method end_span ~span_id ~status ~ended_ms =
      end_span t ~span_id ~status ~ended_ms

    method add_attr ~key ~value = add_attr t ~key ~value

    method add_event ~span_id ~name ~ts_ms ~attrs =
      add_event t ~span_id ~name ~ts_ms ~attrs

    method add_link link = add_link t link

    method inspect ~span_id = inspect t ~span_id
  end

let noop : Capabilities.tracer =
  object
    method begin_span ?parent_id:_ ?external_parent:_ ~name:_ ~started_ms:_ () = -1
    method end_span ~span_id:_ ~status:_ ~ended_ms:_ = ()
    method add_attr ~key:_ ~value:_ = ()
    method add_event ~span_id:_ ~name:_ ~ts_ms:_ ~attrs:_ = ()
    method add_link _ = ()
    method inspect ~span_id:_ = None
  end

let dump t = List.rev t.spans
