(* Minimal effect type + in-memory tracer + interpreter with real span
   semantics. This is the substrate the surface options test against. *)

(* ------------- Tracer (in-memory, OTel-shaped) ------------- *)
module Tracer = struct
  type span = {
    name : string;
    parent_id : int option;
    span_id : int;
    mutable attrs : (string * string) list;
    mutable status : [ `Ok | `Error of string | `Cancelled ];
    mutable started_ms : int;
    mutable ended_ms : int option;
  }

  type t = {
    mutable counter : int;
    mutable now_ms : int;
    mutable spans : span list;
    mutable stack : span list;
    (* Pending attrs: collected by Annotate when no span is active,
       consumed by the NEXT Named that opens a span on this branch. *)
    mutable pending : (string * string) list;
  }

  let make () =
    { counter = 0; now_ms = 0; spans = []; stack = []; pending = [] }
  let advance t ms = t.now_ms <- t.now_ms + ms
  let now t = t.now_ms

  let begin_span t ~name =
    t.counter <- t.counter + 1;
    let parent_id = match t.stack with [] -> None | s :: _ -> Some s.span_id in
    (* Drain pending attrs onto this new span. *)
    let initial_attrs = t.pending in
    t.pending <- [];
    let s =
      { name; parent_id; span_id = t.counter;
        attrs = initial_attrs; status = `Ok;
        started_ms = t.now_ms; ended_ms = None }
    in
    t.stack <- s :: t.stack;
    t.spans <- s :: t.spans;
    s

  let end_span t s status =
    s.status <- status;
    s.ended_ms <- Some t.now_ms;
    t.stack <- (match t.stack with [] -> [] | _ :: xs -> xs)

  (* If a span is active, attach to it. Otherwise buffer for the next one. *)
  let add_attr t k v =
    match t.stack with
    | [] -> t.pending <- (k, v) :: t.pending
    | s :: _ -> s.attrs <- (k, v) :: s.attrs

  (* For tests: produce a printable trace. *)
  let dump t =
    let buf = Buffer.create 256 in
    let by_id = List.rev t.spans in
    List.iter (fun s ->
      let parent = match s.parent_id with None -> "-" | Some i -> string_of_int i in
      let status =
        match s.status with
        | `Ok -> "ok"
        | `Error e -> "err:" ^ e
        | `Cancelled -> "cancelled"
      in
      let dur =
        match s.ended_ms with
        | None -> "?"
        | Some e -> string_of_int (e - s.started_ms)
      in
      Buffer.add_string buf
        (Printf.sprintf "[%d<-%s] %s status=%s dur=%s attrs=%s\n"
           s.span_id parent s.name status dur
           (String.concat ","
              (List.map (fun (k,v) -> k^"="^v) (List.rev s.attrs))))
    ) by_id;
    Buffer.contents buf
end

(* ------------- Effect type ------------- *)
module Effect = struct
  type ('env, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Sync : ('env -> 'a) -> ('env, _, 'a) t
    | Bind : ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) -> ('env, 'err, 'a) t
    | Fail : 'err -> (_, 'err, _) t
    | Named : string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
    | Annotate : string * string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t

  let pure v = Pure v
  let sync f = Sync f
  let bind k e = Bind (e, k)
  let fail e = Fail e
  let ( let* ) e k = Bind (e, k)
  let ( |>= ) e k = Bind (e, k)

  (* Pipe-friendly decorators *)
  let named name e = Named (name, e)
  let annotate ~key ~value e = Annotate (key, value, e)

  (* Convenience: include source location as an annotation. *)
  let here_attr (file, line, _, _) e =
    Annotate ("loc", Printf.sprintf "%s:%d" file line, e)

  (* "fn" smart constructor: combine name + call-site loc in one go. *)
  let fn pos name e = e |> here_attr pos |> named name
end

(* ------------- Interpreter that emits spans ------------- *)
let rec interpret : type env err a.
    tracer:Tracer.t -> env:env -> (env, err, a) Effect.t -> (a, err) result =
 fun ~tracer ~env eff ->
  match eff with
  | Effect.Pure v -> Ok v
  | Effect.Sync f -> Ok (f env)
  | Effect.Fail e -> Error e
  | Effect.Bind (e, k) ->
      (match interpret ~tracer ~env e with
       | Ok v -> interpret ~tracer ~env (k v)
       | Error e -> Error e)
  | Effect.Named (name, body) ->
      let s = Tracer.begin_span tracer ~name in
      Tracer.advance tracer 1;
      let r = interpret ~tracer ~env body in
      Tracer.advance tracer 1;
      let status =
        match r with Ok _ -> `Ok | Error _ -> `Error "fail"
      in
      Tracer.end_span tracer s status;
      r
  | Effect.Annotate (k, v, body) ->
      Tracer.add_attr tracer k v;
      interpret ~tracer ~env body
