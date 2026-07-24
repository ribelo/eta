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
module Resource = Eta.Resource
module Runtime = Eta_jsoo.Runtime
module Runtime_contract = Eta.Runtime_contract
module Sampler = Eta.Sampler
module Schedule = Eta.Schedule
module Semaphore = Eta.Semaphore
module String_helpers = Eta.String_helpers
module Supervisor = Eta.Supervisor
module Trace_context = Eta.Trace_context

module Jsoo_host = Eta_jsoo

let version = "dev"

let from_js_promise ?on_cancel ~on_reject promise =
  let open Js_of_ocaml in
  Effect.async ~register:(fun resume ->
      let then_ = Js.Unsafe.get promise "then" in
      if not (String.equal (Js.to_string (Js.typeof then_)) "function") then
        invalid_arg "Eta_js.from_js_promise: expected a thenable";
      let on_fulfilled =
        Js.wrap_callback (fun value -> resume (Exit.Ok (`Fulfilled value)))
      in
      let on_rejected =
        Js.wrap_callback (fun reason -> resume (Exit.Ok (`Rejected reason)))
      in
      ignore
        (Js.Unsafe.meth_call promise "then"
           [|
             Js.Unsafe.inject on_fulfilled;
             Js.Unsafe.inject on_rejected;
           |]);
      match on_cancel with
      | None -> None
      | Some on_cancel -> Some (Effect.sync on_cancel))
  |> Effect.bind (function
       | `Fulfilled value -> Effect.pure value
       | `Rejected reason ->
           Effect.sync (fun () -> on_reject reason)
           |> Effect.bind Effect.fail)
