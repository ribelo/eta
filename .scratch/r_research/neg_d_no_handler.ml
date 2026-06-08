(* NEGATIVE TEST: R-D native handlers. Boot without installing handlers.
   Expected: COMPILES (a runtime error, not compile-time) — proves
   that R-D loses static checking of service availability. *)
open R_d_native_handlers

(* This compiles fine. Demonstrates the safety gap. *)
let _no_static_check () = unsafe_boot_no_handler ()
