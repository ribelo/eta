type signal = Trace | Log | Metric

type batch = {
  signal : signal;
  size : int;
}

type export_result = {
  delivered : int;
  dropped : int;
  attempts : int;
  diagnostics : string list;
}

let signal_name = function
  | Trace -> "trace"
  | Log -> "log"
  | Metric -> "metric"

let rec chunks_of ~batch_size signal remaining =
  if remaining <= 0 then []
  else
    let size = min batch_size remaining in
    { signal; size } :: chunks_of ~batch_size signal (remaining - size)

let add_result a b =
  {
    delivered = a.delivered + b.delivered;
    dropped = a.dropped + b.dropped;
    attempts = a.attempts + b.attempts;
    diagnostics = a.diagnostics @ b.diagnostics;
  }

let empty_result =
  { delivered = 0; dropped = 0; attempts = 0; diagnostics = [] }

let context_round_trip () =
  let headers =
    [
      ( "traceparent",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" );
      ("tracestate", "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE");
      ("baggage", "user_id=alice,plan=pro");
    ]
  in
  match Effet.Trace_context.extract headers with
  | None -> invalid_arg "expected valid traceparent fixture"
  | Some ctx -> Effet.Trace_context.inject ctx

let assert_equal_int label expected actual =
  if expected <> actual then
    failwith
      (Printf.sprintf "%s: expected %d, got %d" label expected actual)

let assert_true label value =
  if not value then failwith (label ^ ": expected true")
