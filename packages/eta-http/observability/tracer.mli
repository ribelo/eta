(** Tracing wrappers for eta-http client requests.

    These functions use the runtime's {!Eta.Capabilities.tracer}; when
    [enabled=false], they suppress Eta tracer/logger/meter observations for
    the whole request subtree. This lets observability exporters call eta-http
    without recursively observing pool or transport internals. *)

val request :
  ?enabled:bool ->
  ?protocol:Eta_http_client.Client.protocol ->
  Eta_http_client.Client.t ->
  Eta_http_client.Request.t ->
  (Eta_http_client.Response.t, Eta_http_error.Error.t) Eta.Effect.t

val request_with_retry :
  ?enabled:bool ->
  ?policy:Eta_http_client.Retry.t ->
  ?protocol:Eta_http_client.Client.protocol ->
  Eta_http_client.Client.t ->
  Eta_http_client.Request.t ->
  (Eta_http_client.Response.t, Eta_http_error.Error.t) Eta.Effect.t
