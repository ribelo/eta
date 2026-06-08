type trace_context = {
  trace_id : string;
  span_id : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
}

let parent_sampled =
  {
    trace_id = "4bf92f3577b34da6a3ce929d0e0e4736";
    span_id = "00f067aa0ba902b7";
    trace_flags = 1;
    trace_state = [ ("rojo", "00f067aa0ba902b7") ];
    baggage = [ ("tenant", "acme"); ("plan", "pro") ];
  }

let parent_unsampled = { parent_sampled with trace_flags = 0 }

let assert_equal name expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %S, got %S" name expected actual)

let assert_bool name value = if not value then failwith name

