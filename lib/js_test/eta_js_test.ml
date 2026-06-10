module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

type test = string * ((unit -> unit) -> unit)

let fail name reason = failwith (name ^ ": " ^ reason)

let log message =
  ignore
    (Unsafe.fun_call (Unsafe.js_expr "console.log")
       [| Unsafe.inject (Js.string message) |])

let set_exit_code code =
  let process = Unsafe.get Unsafe.global "process" in
  Unsafe.set process "exitCode" code

let expect_ok name f =
  try f () with exn -> failwith (name ^ ": " ^ Printexc.to_string exn)

let finish done_ f =
  try
    f ();
    done_ ()
  with exn ->
    set_exit_code 1;
    log ("FAILED: " ^ Printexc.to_string exn)

let rec run_all tests =
  match tests with
  | [] -> ()
  | (name, test) :: rest ->
      let finished = ref false in
      let done_ () =
        if not !finished then (
          finished := true;
          log ("ok: " ^ name);
          run_all rest)
      in
      try test done_
      with exn ->
        finished := true;
        set_exit_code 1;
        log ("FAILED: " ^ name ^ ": " ^ Printexc.to_string exn)

let main tests = run_all tests
