open Eta

type error = [ `Missing_span of string ]
[@@deriving eta_error]

let require label condition =
  if not condition then failwith ("span linking check failed: " ^ label)

let current_span_or_fail label =
  let open Syntax in
  let* span = Effect.current_span in
  match span with
  | Some span -> Effect.pure span
  | None -> Effect.fail (`Missing_span label)

let producer =
  Effect.named ~error_pp:pp_error ~kind:Tracer.Producer "events.publish"
    (current_span_or_fail "producer")

let consumer (published : Capabilities.span_info) =
  let open Syntax in
  Effect.link_span ~trace_id:published.Capabilities.trace_id
    ~span_id:published.span_id
    (Effect.named ~error_pp:pp_error ~kind:Tracer.Consumer "events.consume"
       (let* active = current_span_or_fail "consumer" in
        let* () =
          Effect.event ~attrs:[ ("linked.span_id", published.span_id) ]
            "event.linked"
        in
        Effect.pure active))

let program =
  let open Syntax in
  let* published = producer in
  let+ consumed = consumer published in
  (published, consumed)

let span_named name span =
  String.equal span.Tracer.name name

let event_named name event =
  String.equal event.Tracer.ev_name name

let link_matches (published : Capabilities.span_info) link =
  String.equal link.Tracer.link_trace_id published.Capabilities.trace_id
  && String.equal link.link_span_id published.span_id

let verify (published : Capabilities.span_info) (consumed : Capabilities.span_info)
    tracer =
  let spans = Tracer.dump tracer in
  let producer =
    match List.find_opt (span_named "events.publish") spans with
    | Some span -> span
    | None -> failwith "span linking check failed: missing producer"
  in
  let consumer =
    match List.find_opt (span_named "events.consume") spans with
    | Some span -> span
    | None -> failwith "span linking check failed: missing consumer"
  in
  require "producer kind" (producer.kind = Tracer.Producer);
  require "consumer kind" (consumer.kind = Tracer.Consumer);
  require "current consumer name"
    (String.equal consumed.Capabilities.name "events.consume");
  require "consumer event"
    (List.exists (event_named "event.linked") consumer.events);
  require "consumer link"
    (List.exists (link_matches published) consumer.links);
  Format.printf "span-linking:producer=%s consumer=%s links=%d spans=%d@."
    published.span_id consumed.span_id (List.length consumer.links)
    (List.length spans)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer)
      ()
  in
  match Eta_eio.Runtime.run rt program with
  | Exit.Ok (published, consumed) -> verify published consumed tracer
  | Exit.Error cause ->
      Format.eprintf "span linking failed: %a@." (Cause.pp pp_error) cause;
      exit 1
