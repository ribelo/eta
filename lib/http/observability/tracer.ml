module Client = Eta_http_client.Client
module Request = Eta_http_client.Request
module Retry = Eta_http_client.Retry
module Semconv = Semconv

let annotate attrs eff =
  List.fold_right
    (fun (key, value) acc -> Eta.Effect.annotate ~key ~value acc)
    attrs eff

let span_name request =
  "HTTP " ^ String.uppercase_ascii request.Request.method_

let with_span ?(attrs = []) ?(emit_url_full = false) ~protocol request eff =
  let request_attrs =
    attrs @ Semconv.request_attrs ~emit_url_full ~protocol request
  in
  let body =
    eff
    |> Eta.Effect.bind (fun response ->
           Eta.Effect.pure response |> annotate (Semconv.response_attrs response))
    |> Eta.Effect.catch (fun error ->
           Eta.Effect.fail error |> annotate (Semconv.error_attrs error))
    |> annotate request_attrs
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
           Eta.Effect.pure response |> annotate (Semconv.response_attrs response))
    |> Eta.Effect.catch (fun error ->
           Eta.Effect.fail error |> annotate (Semconv.error_attrs error))
    |> annotate (Semconv.request_attrs ~emit_url_full ~protocol request)
    |> Eta.Effect.named_kind ~kind:Eta.Capabilities.Client
         (span_name request ^ " retry")
