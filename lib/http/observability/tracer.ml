module Client = Client
module Request = Request
module Retry = Retry
module Semconv = Semconv

let span_name request =
  "HTTP " ^ String.uppercase_ascii request.Request.method_

let with_span ?(attrs = []) ?(emit_url_full = false) ~protocol request eff =
  let request_attrs =
    attrs @ Semconv.request_attrs ~emit_url_full ~protocol request
  in
  let body =
    eff
    |> Eta.Effect.bind (fun response ->
           Eta.Effect.pure response
           |> Eta.Effect.annotate_all (Semconv.response_attrs response))
    |> Eta.Effect.catch (fun error ->
           Eta.Effect.fail error
           |> Eta.Effect.annotate_all (Semconv.error_attrs error))
    |> Eta.Effect.annotate_all request_attrs
  in
  body |> Eta.Effect.named_kind ~kind:Eta.Capabilities.Client (span_name request)

let request ?(enabled = true) ?(emit_url_full = false) ?protocol client request =
  let protocol = Option.value ~default:(Client.protocol client) protocol in
  let eff = Client.request client request in
  if enabled then with_span ~emit_url_full ~protocol request eff
  else Eta.Effect.suppress_observability eff

let request_with_retry ?(enabled = true) ?(emit_url_full = false) ?policy
    ?protocol client request =
  let protocol = Option.value ~default:(Client.protocol client) protocol in
  if not enabled then
    Client.request_with_retry ?policy client request
    |> Eta.Effect.suppress_observability
  else
    let attempt = ref 0 in
    let request_once request =
      incr attempt;
      Client.request client request
      |> with_span ~attrs:(Semconv.retry_attrs ~attempt:!attempt)
           ~emit_url_full ~protocol request
    in
    Retry.run ?policy request_once request
    |> Eta.Effect.bind (fun response ->
           Eta.Effect.pure response
           |> Eta.Effect.annotate_all (Semconv.response_attrs response))
    |> Eta.Effect.catch (fun error ->
           Eta.Effect.fail error
           |> Eta.Effect.annotate_all (Semconv.error_attrs error))
    |> Eta.Effect.annotate_all (Semconv.request_attrs ~emit_url_full ~protocol request)
    |> Eta.Effect.named_kind ~kind:Eta.Capabilities.Client
         (span_name request ^ " retry")
