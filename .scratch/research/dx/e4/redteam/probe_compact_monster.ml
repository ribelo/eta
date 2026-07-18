(* E4 red-team: the ugliest causes I can construct. For each, check
   (a) pp_compact stays one line;
   (b) every leaf payload survives the compact render exactly once
       (truthfulness: no leaf silently dropped);
   (c) the primary/finalizer distinction is still visible. *)

open Eta

let die_record exn =
  match Cause.die exn with Cause.Die die -> die | _ -> assert false

let die_full exn =
  match
    Cause.die_with_diagnostics ~span_name:"span.export"
      ~annotations:[ ("batch", "42") ] exn
  with
  | Cause.Die die -> die
  | _ -> assert false

let contains haystack needle =
  let hlen = String.length haystack and nlen = String.length needle in
  let rec go i =
    i + nlen <= hlen
    && (String.sub haystack i nlen = needle || go (i + 1))
  in
  go 0

let failures = ref 0

let check name cause ~leaves =
  let compact = Cause.pp_compact Fun.id cause in
  Printf.printf "=== %s ===\ncompact: %s\n" name compact;
  if String.contains compact '\n' || String.contains compact '\r' then (
    incr failures;
    Printf.printf "FAIL: not one line\n");
  List.iter
    (fun leaf ->
      if not (contains compact leaf) then (
        incr failures;
        Printf.printf "FAIL: leaf %S missing from compact\n" leaf))
    leaves;
  Printf.printf "pretty:\n%s\n\n" (Cause.pretty Fun.id cause)

let () =
  let id1 = Cause.fresh_interrupt_id () in
  let id2 = Cause.fresh_interrupt_id () in
  (* Monster 1: suppressed x concurrent x sequential x finalizer x nested
     suppressed, anonymous and identified interrupts, multi-line payloads. *)
  let monster1 =
    Cause.suppressed
      ~primary:
        (Cause.concurrent
           [
             Cause.sequential
               [ Cause.fail "timeout"; Cause.die (Failure "shard exploded") ];
             Cause.suppressed
               ~primary:
                 (Cause.sequential
                    [ Cause.fail "auth"; Cause.interrupt_with_id id1 ])
               ~finalizer:
                 (Cause.Finalizer.Sequential
                    [
                      Cause.Finalizer.Fail "span export failed";
                      Cause.Finalizer.Finalizer
                        (Cause.Finalizer.Die
                           (die_record (Invalid_argument "closed twice")));
                    ]);
             Cause.interrupt;
             Cause.finalizer
               (Cause.Finalizer.Suppressed
                  {
                    primary = Cause.Finalizer.Fail "flush failed";
                    finalizer = Cause.Finalizer.Interrupt (Some id2);
                  });
           ])
      ~finalizer:
        (Cause.Finalizer.Concurrent
           [
             Cause.Finalizer.Fail "metrics flush failed\nwith detail";
             Cause.Finalizer.Die (die_record (Failure "finalizer exploded\nover lines"));
           ])
  in
  check "monster1: everything at once" monster1
    ~leaves:
      [
        "fail(timeout)";
        "die(Failure(\"shard exploded\"))";
        "fail(auth)";
        Printf.sprintf "interrupt#%d" (Cause.interrupt_id_to_int id1);
        "fail(\"span export failed\")";
        "die(Invalid_argument(\"closed twice\"))";
        "interrupt";
        "fail(\"flush failed\")";
        Printf.sprintf "interrupt#%d" (Cause.interrupt_id_to_int id2);
        "metrics flush failed\\nwith detail";
        "finalizer exploded\\nover lines";
      ];
  (* Monster 2: empty and singleton raw composites mixed in. *)
  let monster2 =
    Cause.sequential
      [
        Cause.Sequential [];
        Cause.Concurrent [ Cause.fail "lone" ];
        Cause.finalizer (Cause.Finalizer.Sequential []);
      ]
  in
  check "monster2: degenerate composites" monster2
    ~leaves:[ "sequential()"; "fail(lone)"; "finalizer(sequential())" ];
  (* Monster 3: defect metadata omission — compact drops span/annotations;
     confirm pretty keeps them so the information is not lost from the
     system, only from the one-line summary. *)
  let monster3 = Cause.Die (die_full (Failure "export boom")) in
  let compact3 = Cause.pp_compact Fun.id monster3 in
  let pretty3 = Cause.pretty Fun.id monster3 in
  Printf.printf "=== monster3: metadata omission ===\ncompact: %s\n" compact3;
  if contains compact3 "span.export" || contains compact3 "batch" then (
    incr failures;
    Printf.printf "FAIL: compact leaked metadata\n");
  if not (contains pretty3 "span.export" && contains pretty3 "batch=42") then (
    incr failures;
    Printf.printf "FAIL: pretty lost metadata\n");
  Printf.printf "pretty:\n%s\n\n" pretty3;
  (* Monster 4: payloads with parens — compact is human-facing, not
     machine-parseable; record how it reads. *)
  let monster4 =
    Cause.concurrent
      [ Cause.fail "unbalanced ) paren"; Cause.fail "another (" ]
  in
  check "monster4: parens in payloads" monster4
    ~leaves:[ "fail(unbalanced ) paren)"; "fail(another ()" ];
  if !failures = 0 then Printf.printf "verdict: all red-team checks passed\n"
  else Printf.printf "verdict: %d check(s) FAILED\n" !failures
