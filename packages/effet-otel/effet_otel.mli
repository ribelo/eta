(** OTLP/JSON over HTTP/1.1 exporter for Effet's tracer capability.

    [Effet_otel] adapts {!Effet.Capabilities.tracer} to a real OpenTelemetry
    backend over the OTLP/JSON protocol. The implementation is deliberately
    small: hand-written JSON, hand-written HTTP/1.1, Eio TCP. It does not
    depend on cohttp, tls, protobuf, or [ocaml-opentelemetry].

    Usage:
    {[
      let exporter =
        Effet_otel.create ~sw
          ~net:(Eio.Stdenv.net stdenv)
          ~clock:(Eio.Stdenv.clock stdenv)
          ~host:"127.0.0.1" ~port:27686
          ~service_name:"my-app"
          ()
      in
      let rt =
        Effet.Runtime.create ~sw
          ~clock:(Eio.Stdenv.clock stdenv)
          ~tracer:(Effet_otel.tracer exporter)
          ~env:my_env
          ()
      in
      let _ = Effet.Runtime.run rt my_program in
      Effet_otel.flush exporter
    ]} *)

type t

val create :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?host:string ->
  ?port:int ->
  ?path:string ->
  ?service_name:string ->
  ?service_version:string ->
  ?resource_attrs:(string * string) list ->
  ?scope_name:string ->
  ?on_error:(string -> unit) ->
  unit ->
  t
(** Construct an exporter. A background fiber is forked on [sw] to drain the
    completed-spans queue and POST batches to [http://host:port/path].

    Defaults: host="127.0.0.1", port=4318, path="/v1/traces",
    service_name="effet", scope_name="effet". *)

val tracer : t -> Effet.Capabilities.tracer
(** Return a value satisfying {!Effet.Capabilities.tracer} backed by [t].
    Pass it to [Effet.Runtime.create ~tracer]. *)

val flush : ?timeout_s:float -> t -> unit
(** Block until the in-flight queue is drained or [timeout_s] elapses. *)
