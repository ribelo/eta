open Effect.Deep

module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

type _ Effect.t += Await : unit Effect.t

let log message =
  ignore
    (Unsafe.fun_call (Unsafe.js_expr "console.log")
       [| Unsafe.inject (Js.string message) |])

let set_timeout f =
  ignore
    (Unsafe.fun_call (Unsafe.js_expr "setTimeout")
       [| Unsafe.inject (Js.wrap_callback f); Unsafe.inject (Js.number_of_float 0.0) |])

let () =
  match_with
    (fun () ->
      Effect.perform Await;
      log "continued")
    ()
    {
      retc = (fun () -> log "returned");
      exnc = (fun exn -> log ("exception: " ^ Printexc.to_string exn));
      effc =
        (fun (type a) (eff : a Effect.t) ->
          match eff with
          | Await ->
              Some
                (fun (k : (a, unit) continuation) ->
                  set_timeout (fun () -> continue k ()))
          | _ -> None);
    }
