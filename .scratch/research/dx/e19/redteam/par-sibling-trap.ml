(** Intentionally wrong red-team oracle.

    The executable regression selected as case 2 by [run.sh] observes
    [(11, 0)] when only the left [par] branch installs clock 11. This trap
    expects the override to leak into the right sibling. Running this file
    exits successfully only when the wrong expectation is disproved. *)

let expected_if_binding_leaked = (11, 11)
let observed_by_executable_regression = (11, 0)

let () =
  if observed_by_executable_regression = expected_if_binding_leaked then
    failwith "red-team trap unexpectedly observed a sibling leak"
  else
    print_endline
      "disarmed: branch-local override did not leak into its par sibling"
