module Current_fixture = Cause_research.Fixture.Make (Cause_research.Current_both)
module Structured_fixture =
  Cause_research.Fixture.Make (Cause_research.Proposed_structured)

let assert_equal name expected actual =
  if not (String.equal expected actual) then
    failwith (Printf.sprintf "%s: expected %S, got %S" name expected actual)

let assert_none name = function
  | None -> ()
  | Some value -> failwith (Printf.sprintf "%s: unexpected Some %S" name value)

let assert_some name expected = function
  | Some value -> assert_equal name expected value
  | None -> failwith (Printf.sprintf "%s: expected Some %S" name expected)

let print_rendered label rows =
  Printf.printf "== %s ==\n" label;
  List.iter
    (fun (name, rendered, events) ->
      Printf.printf "%s: %s\n" name rendered;
      List.iter
        (fun (path, msg) -> Printf.printf "  event path=%s msg=%s\n" path msg)
        events)
    rows

let () =
  assert_some "current catches single Fail" "handled"
    (Current_fixture.catch_single_fail ());
  assert_none "current does not catch Both"
    (Current_fixture.catch_concurrent_failure ());
  assert_some "structured catches single Fail" "handled"
    (Structured_fixture.catch_single_fail ());
  assert_none "structured does not catch Concurrent"
    (Structured_fixture.catch_concurrent_failure ());

  let current = Current_fixture.render_all () in
  let structured = Structured_fixture.render_all () in
  print_rendered "current Both" current;
  print_rendered "structured" structured;
  Printf.printf "cause research smoke tests passed\n%!"
