(* Generates the review-packet render files: each corpus case rendered both
   ways (pretty multi-line tree, pp_compact one line) into case-*.txt. *)

open Eta

let die_record exn =
  match Cause.die exn with Cause.Die die -> die | _ -> assert false

let render_err = function
  | `A -> "A"
  | `B -> "B"
  | `C n -> "C:" ^ string_of_int n

let write_case filename title cause =
  let out = open_out filename in
  Printf.fprintf out "%s\n\n== pretty (multi-line tree) ==\n%s\n\n== pp_compact (one line) ==\n%s\n"
    title
    (Cause.pretty render_err cause)
    (Cause.pp_compact render_err cause);
  close_out out

let () =
  let id_a = Cause.fresh_interrupt_id () in
  let id_b = Cause.fresh_interrupt_id () in
  write_case "case-1-concurrent-fail-interrupt.txt"
    "Concurrent [ Fail `A; Interrupt (anonymous) ]"
    (Cause.concurrent [ Cause.fail `A; Cause.interrupt ]);
  write_case "case-2-suppressed-fail-die.txt"
    "Suppressed { primary = Fail `B; finalizer = Die (Invalid_argument \"cleanup\") }"
    (Cause.suppressed ~primary:(Cause.fail `B)
       ~finalizer:(Cause.Finalizer.Die (die_record (Invalid_argument "cleanup"))));
  write_case "case-3-nested-finalizer-sequential.txt"
    "Finalizer (Sequential [ Fail \"cleanup failed\"; Die (Invalid_argument \"cleanup defect\"); Interrupt (identified) ])"
    (Cause.finalizer
       (Cause.Finalizer.Sequential
          [
            Cause.Finalizer.Fail "cleanup failed";
            Cause.Finalizer.Die (die_record (Invalid_argument "cleanup defect"));
            Cause.Finalizer.Interrupt (Some id_a);
          ]));
  write_case "case-4-interrupts-anonymous-vs-identified.txt"
    "Concurrent [ Interrupt (anonymous); Interrupt (identified) ]"
    (Cause.concurrent [ Cause.interrupt; Cause.interrupt_with_id id_b ]);
  write_case "case-5-multi-defect-composite.txt"
    "Concurrent [ Die (Failure \"a\"); Die (Failure \"b\") ]"
    (Cause.concurrent [ Cause.die (Failure "a"); Cause.die (Failure "b") ]);
  write_case "case-6-suppressed-concurrent-finalizer.txt"
    "Suppressed { primary = Concurrent [ Fail `A; Die (Failure \"boom\") ]; finalizer = Sequential [ Fail \"cleanup failed\"; Interrupt ] }"
    (Cause.suppressed
       ~primary:(Cause.concurrent [ Cause.fail `A; Cause.die (Failure "boom") ])
       ~finalizer:
         (Cause.Finalizer.Sequential
            [ Cause.Finalizer.Fail "cleanup failed"; Cause.Finalizer.Interrupt None ]));
  print_endline "wrote 6 case files"
