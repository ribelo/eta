type log_level = Trace | Debug | Info | Warn | Error | Fatal

type log_record = {
  level : log_level;
  body : string;
  attrs : (string * string) list;
  trace_id : string;
  span_id : string;
}

type metric_value = Int of int | Float of float
type metric_kind = Counter | Gauge

type metric_point = {
  name : string;
  kind : metric_kind;
  attrs : (string * string) list;
  value : metric_value;
  trace_id : string;
  span_id : string;
}

type span = {
  id : int;
  trace_id : string;
  span_id : string;
  name : string;
}

type sink = {
  mutable next_span : int;
  mutable spans : span list;
  mutable logs : log_record list;
  mutable metrics : metric_point list;
}

let create_sink () = { next_span = 0; spans = []; logs = []; metrics = [] }

let begin_span sink name =
  let id = sink.next_span in
  sink.next_span <- sink.next_span + 1;
  let span =
    {
      id;
      trace_id = Printf.sprintf "trace-%d" id;
      span_id = Printf.sprintf "span-%d" id;
      name;
    }
  in
  sink.spans <- span :: sink.spans;
  span

let add_log sink record = sink.logs <- record :: sink.logs
let add_metric sink point = sink.metrics <- point :: sink.metrics
let logs sink = List.rev sink.logs
let metrics sink = List.rev sink.metrics
let spans sink = List.rev sink.spans

let assert_bool name value =
  if not value then failwith ("assertion failed: " ^ name)

let assert_equal_string name expected actual =
  if not (String.equal expected actual) then
    failwith
      (Printf.sprintf "assertion failed: %s expected=%S actual=%S" name
         expected actual)

let assert_equal_int name expected actual =
  if expected <> actual then
    failwith
      (Printf.sprintf "assertion failed: %s expected=%d actual=%d" name
         expected actual)
