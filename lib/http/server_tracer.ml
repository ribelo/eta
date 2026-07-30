(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Request = Server_request
module Semconv = Server_semconv

let method_name method_ = Method.(method_ |> of_string |> to_string)
let span_name request = "HTTP " ^ method_name request.Request.method_

let with_span ?(emit_url_full = false) request eff =
  let body =
    eff
    |> Eta.Effect.bind (fun response ->
           Eta.Effect.pure response
           |> Eta_observability.annotate_all_lazy (fun () ->
                  Semconv.response_attrs response))
    |> Eta.Effect.bind_error (fun error ->
           Eta.Effect.fail error
           |> Eta_observability.annotate_all_lazy (fun () ->
                  Semconv.error_attrs error))
    |> Eta_observability.annotate_all_lazy (fun () ->
           Semconv.request_attrs ~emit_url_full request)
  in
  let span =
    body
    |> Eta_observability.named ~kind:Eta.Capabilities.Server (span_name request)
  in
  match Request.trace_context request with
  | None -> span
  | Some context -> Eta_observability.with_context context span

let request ?(enabled = true) ?(emit_url_full = false) handler request =
  if not enabled then Eta_observability.suppress_observability (handler request)
  else
    (* Only pay the span-wrapper Effect overhead (bind/catch/named +
       die-context bindings) when a tracer is actually installed. With no
       tracer the span would never be recorded, so run the handler bare — but
       leave logging/metrics untouched (unlike suppress_observability). *)
    Eta_observability.is_tracing_enabled
    |> Eta.Effect.bind (fun tracing ->
           let eff = handler request in
           if tracing then with_span ~emit_url_full request eff else eff)
