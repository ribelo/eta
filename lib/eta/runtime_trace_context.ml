let sampled (context : Capabilities.trace_context) =
  context.trace_flags land 1 = 1

let is_hex len value =
  String.length value = len
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value

let not_zero value = String.exists (( <> ) '0') value
let valid_trace_id value = is_hex 32 value && not_zero value
let valid_span_id value = is_hex 16 value && not_zero value

let make ~trace_id ~span_id ~trace_flags ~trace_state ~baggage =
  if valid_trace_id trace_id && valid_span_id span_id then
    Some
      {
        Capabilities.trace_id;
        span_id;
        trace_flags = trace_flags land 255;
        trace_state;
        baggage;
      }
  else None
