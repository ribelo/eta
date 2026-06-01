let bounded_string max_len =
  if max_len < 0 then invalid_arg "bounded_string";
  Crowbar.dynamic_bind (Crowbar.range (max_len + 1)) Crowbar.bytes_fixed

let bounded_bytes max_len =
  Crowbar.map [ bounded_string max_len ] Bytes.of_string

let rec fixed_list len gen =
  if len = 0 then Crowbar.const []
  else Crowbar.map [ gen; fixed_list (len - 1) gen ] (fun x xs -> x :: xs)

let bounded_list max_len gen =
  if max_len < 0 then invalid_arg "bounded_list";
  Crowbar.dynamic_bind (Crowbar.range (max_len + 1)) (fun len ->
      fixed_list len gen)

let check_span label limit (span : Eta_http.Core.Span.t) =
  if span.off < 0 || span.len < 0 || span.off > limit
     || span.len > limit - span.off
  then
    Crowbar.failf "%s span out of bounds: off=%d len=%d limit=%d" label
      span.off span.len limit

let check_nonnegative label value =
  if value < 0 then Crowbar.failf "%s is negative: %d" label value

let check_same_string label expected actual =
  if not (String.equal expected actual) then
    Crowbar.failf "%s mismatch\nexpected: %S\nactual:   %S" label expected
      actual

let check_same_bytes label expected actual =
  check_same_string label (Bytes.to_string expected) (Bytes.to_string actual)

let bytes_of_string_gen len =
  Crowbar.map [ Crowbar.bytes_fixed len ] Bytes.of_string
