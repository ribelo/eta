open Eta
module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

let on_event target name =
  Effect.Expert.make ~capabilities:[ `Concurrency ] @@ fun context ->
  let has_api = Unsafe.fun_call
      (Unsafe.js_expr "(x => typeof x.addEventListener === 'function' && typeof x.removeEventListener === 'function')")
      [| Unsafe.inject target |] in
  if not (Js.to_bool (has_api : bool Js.t)) then
    invalid_arg "EventTarget add/removeEventListener is unavailable";
  let contract = Effect.Expert.contract context in
  let promise, resolver = contract.Runtime_contract.create_promise () in
  let settled = ref false in
  let handler = Js.wrap_callback (fun event ->
      if not !settled then (settled := true;
        contract.Runtime_contract.resolve_promise resolver event)) in
  let options = Unsafe.obj [| ("once", Unsafe.inject Js._true) |] in
  Unsafe.meth_call target "addEventListener"
    [| Unsafe.inject (Js.string name); Unsafe.inject handler; options |] |> ignore;
  let remove () = Unsafe.meth_call target "removeEventListener"
      [| Unsafe.inject (Js.string name); Unsafe.inject handler |] |> ignore in
  try Exit.Ok (contract.Runtime_contract.await_promise promise) with exn ->
    if Option.is_some (contract.Runtime_contract.cancellation_reason exn) then
      remove ();
    raise exn
