module Client = Client
module Request = Request
module Retry = Retry
module Semconv = Semconv

let method_name method_ = Method.(method_ |> of_string |> to_string)

let span_name request =
  "HTTP " ^ method_name request.Request.method_

let[@inline always] resolve_protocol client = function
  | Some protocol -> protocol
  | None -> Client.protocol client

let with_span ?(attrs = []) ?(emit_url_full = false) ~protocol request eff =
  let request_attrs =
    attrs @ Semconv.request_attrs ~emit_url_full ~protocol request
  in
  eff
  |> Eta.Effect.bind (fun response ->
         Eta.Effect.pure response
         |> Eta.Effect.annotate_all (Semconv.response_attrs response))
  |> Eta.Effect.catch (fun error ->
         Eta.Effect.fail error
         |> Eta.Effect.annotate_all (Semconv.error_attrs error))
  |> Eta.Effect.annotate_all request_attrs
  |> Eta.Effect.named_kind ~kind:Eta.Capabilities.Client (span_name request)

let request ?(enabled = true) ?(emit_url_full = false) ?protocol client request =
  let eff = Client.request client request in
  if enabled then
    let protocol = resolve_protocol client protocol in
    with_span ~emit_url_full ~protocol request eff
  else Eta.Effect.suppress_observability eff

let request_with_retry ?(enabled = true) ?(emit_url_full = false) ?policy
    ?protocol client request =
  if not enabled then
    Client.request_with_retry ?policy client request
    |> Eta.Effect.suppress_observability
  else
    let protocol = resolve_protocol client protocol in
    let attempt = ref 0 in
    let request_once request =
      incr attempt;
      Client.request client request
      |> with_span ~attrs:(Semconv.retry_attrs ~attempt:!attempt)
           ~emit_url_full ~protocol request
    in
    Retry.run ?policy request_once request
    |> with_span ~emit_url_full ~protocol request
    |> Eta.Effect.named_kind ~kind:Eta.Capabilities.Client
         (span_name request ^ " retry")
