open Eta
module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

let require_event_target target =
  let has_api =
    Unsafe.fun_call
      (Unsafe.js_expr "(x => typeof x.addEventListener === 'function' && typeof x.removeEventListener === 'function')")
      [| Unsafe.inject target |]
  in
  if not (Js.to_bool (has_api : bool Js.t)) then
    invalid_arg "EventTarget add/removeEventListener is unavailable"

let on_event target name =
  Effect.async ~register:(fun resume ->
      require_event_target target;
      let handler = Js.wrap_callback (fun event -> resume (Exit.Ok event)) in
      let options = Unsafe.obj [| ("once", Unsafe.inject Js._true) |] in
      Unsafe.meth_call target "addEventListener"
        [| Unsafe.inject (Js.string name); Unsafe.inject handler; options |]
      |> ignore;
      Some
        (Effect.sync (fun () ->
             Unsafe.meth_call target "removeEventListener"
               [| Unsafe.inject (Js.string name); Unsafe.inject handler |]
             |> ignore)))
