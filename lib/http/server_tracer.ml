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
           |> Eta.Effect.annotate_all_lazy (fun () ->
                  Semconv.response_attrs response))
    |> Eta.Effect.catch (fun error ->
           Eta.Effect.fail error
           |> Eta.Effect.annotate_all_lazy (fun () -> Semconv.error_attrs error))
    |> Eta.Effect.annotate_all_lazy (fun () ->
           Semconv.request_attrs ~emit_url_full request)
  in
  let span =
    body |> Eta.Effect.named_kind ~kind:Eta.Capabilities.Server (span_name request)
  in
  match Request.trace_context request with
  | None -> span
  | Some context -> Eta.Effect.with_context context span

let request ?(enabled = true) ?(emit_url_full = false) handler request =
  let eff = handler request in
  if enabled then with_span ~emit_url_full request eff
  else Eta.Effect.suppress_observability eff
