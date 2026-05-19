type status = Capabilities.span_status = Ok | Error of string | Cancelled

type span = {
  span_id : int;
  parent_id : int option;
  name : string;
  attrs : (string * string) list;
  status : status;
  started_ms : int;
  ended_ms : int;
}

type open_span = {
  span_id : int;
  parent_id : int option;
  name : string;
  mutable attrs : (string * string) list;
  started_ms : int;
}

type in_memory = {
  mutable next_id : int;
  mutable stack : open_span list;
  mutable spans : span list;
  mutable pending : (string * string) list;
}

let in_memory () = { next_id = 0; stack = []; spans = []; pending = [] }

let begin_span t ?parent_id ~name ~started_ms () =
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
  let attrs = List.rev t.pending in
  t.pending <- [];
  t.stack <- { span_id; parent_id; name; attrs; started_ms } :: t.stack;
  span_id

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
          attrs = List.rev span.attrs;
          status;
          started_ms = span.started_ms;
          ended_ms;
        }
        :: t.spans

let add_attr t ~key ~value =
  match t.stack with
  | span :: _ -> span.attrs <- (key, value) :: span.attrs
  | [] -> t.pending <- (key, value) :: t.pending

let as_capability t : Capabilities.tracer =
  object
    method begin_span ?parent_id ~name ~started_ms () =
      begin_span t ?parent_id ~name ~started_ms ()

    method end_span ~span_id ~status ~ended_ms =
      end_span t ~span_id ~status ~ended_ms

    method add_attr ~key ~value = add_attr t ~key ~value
  end

let noop : Capabilities.tracer =
  object
    method begin_span ?parent_id:_ ~name:_ ~started_ms:_ () = -1
    method end_span ~span_id:_ ~status:_ ~ended_ms:_ = ()
    method add_attr ~key:_ ~value:_ = ()
  end

let dump t = List.rev t.spans
