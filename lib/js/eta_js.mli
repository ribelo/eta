module Capabilities = Eta.Capabilities
module Cause = Eta.Cause
module Channel = Eta.Channel
module Duration = Eta.Duration
module Effect = Eta.Effect
module Exit = Eta.Exit
module Log_level = Eta.Log_level
module Mutable_ref = Eta.Mutable_ref
module Pool = Eta.Pool
module Pubsub = Eta.Pubsub
module Queue = Eta.Queue
module Random = Eta.Random
module Refreshable = Eta_cache.Refreshable
module Runtime = Eta_jsoo.Runtime
module Runtime_contract = Eta.Runtime_contract
module Sampler = Eta.Sampler
module Schedule = Eta.Schedule
module Semaphore = Eta.Semaphore
module String_helpers = Eta.String_helpers
module Supervisor = Eta.Supervisor
module Trace_context = Eta.Trace_context

module Jsoo_host = Eta_jsoo

val version : string

val from_js_promise :
  ?on_cancel:(unit -> unit) ->
  on_reject:(Js_of_ocaml.Js.Unsafe.any -> 'err) ->
  Js_of_ocaml.Js.Unsafe.any ->
  ('a, 'err) Effect.t
(** Await a host JavaScript promise, inheriting the {!Effect.async} contract:
    handlers attach synchronously at registration and the first settlement
    wins. Rejection fails with [on_reject] applied to the raw host rejection
    value, unchanged even when it is not a JS [Error]; a raising mapper dies.
    Interruption detaches the Eta waiter: [?on_cancel] runs at most once, the
    mapper does not run for later rejection, and handlers stay attached until
    settlement. Eta does not itself cancel the host computation; [?on_cancel]
    may request that. The success type is caller-asserted and unchecked. A
    non-thenable [promise] raises at registration ({!Cause.Die}). *)
