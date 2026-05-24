(** Tracing wrappers for eta-http client requests.

    These functions use the runtime's {!Eta.Capabilities.tracer}; when
    [enabled=false], they suppress Eta tracer/logger/meter observations for
    the whole request subtree. This lets observability exporters call eta-http
    without recursively observing pool or transport internals. *)

val request :
  ?enabled:bool ->
  ?emit_url_full:bool ->
  ?protocol:Eta_http_client.Client.protocol ->
  Eta_http_client.Client.t ->
  Eta_http_client.Request.t ->
  (Eta_http_client.Response.t, Eta_http_error.Error.t) Eta.Effect.t
(** [emit_url_full] defaults to [false], so [url.full] redacts query strings.
    Set it to [true] only for trusted tracing environments. *)

val request_with_retry :
  ?enabled:bool ->
  ?emit_url_full:bool ->
  ?policy:Eta_http_client.Retry.t ->
  ?protocol:Eta_http_client.Client.protocol ->
  Eta_http_client.Client.t ->
  Eta_http_client.Request.t ->
  (Eta_http_client.Response.t, Eta_http_error.Error.t) Eta.Effect.t
