(* F-E: supervisor strategies.

   This candidate tests the policy axis separately from the handle axis:
   one-for-one restarts only the failed child, while one-for-all restarts all
   children after any child failure. The lab keeps the children synchronous so
   the strategy semantics are easy to verify. *)

module Supervisor = struct
  type strategy = One_for_one | One_for_all
  type restart = Never | On_failure | Always
  type 'err cause = Fail of 'err | Die of string | Interrupt

  type ('err, 'a) child = {
    name : string;
    max_restarts : int;
    run : int -> ('a, 'err cause) result;
  }

  type 'err event =
    | Started of string * int
    | Succeeded of string
    | Failed of string * 'err cause
    | Restarted of string * int
    | Gave_up of string

  type ('err, 'a) report = {
    results : (string * ('a, 'err cause) result) list;
    events : 'err event list;
  }

  let should_restart policy = function
    | Ok _ -> policy = Always
    | Error _ -> policy = On_failure || policy = Always

  let run_child policy child =
    let rec loop events attempt =
      let events = Started (child.name, attempt) :: events in
      let result = child.run attempt in
      match result with
      | Ok _ when should_restart policy result && attempt < child.max_restarts ->
          loop (Restarted (child.name, attempt + 1) :: events) (attempt + 1)
      | Ok _ -> (result, Succeeded child.name :: events)
      | Error cause
        when should_restart policy result && attempt < child.max_restarts ->
          loop
            (Restarted (child.name, attempt + 1) :: Failed (child.name, cause)
             :: events)
            (attempt + 1)
      | Error cause ->
          (result, Gave_up child.name :: Failed (child.name, cause) :: events)
    in
    loop [] 0

  let run ~strategy ~restart children =
    match strategy with
    | One_for_one ->
        let pairs =
          List.map
            (fun child ->
              let result, events = run_child restart child in
              ((child.name, result), events))
            children
        in
        {
          results = List.map fst pairs;
          events = List.concat_map (fun (_, events) -> List.rev events) pairs;
        }
    | One_for_all ->
        let rec attempt_all attempt events =
          let events =
            List.fold_left
              (fun acc child -> Started (child.name, attempt) :: acc)
              events children
          in
          let results =
            List.map (fun child -> (child.name, child.run attempt)) children
          in
          let failed =
            List.filter_map
              (function
                | name, Error cause -> Some (name, cause)
                | _ -> None)
              results
          in
          match failed with
          | [] ->
              {
                results;
                events =
                  List.rev
                    (List.fold_left
                       (fun acc (name, _) -> Succeeded name :: acc)
                       events results);
              }
          | (name, cause) :: _
            when restart <> Never
                 && attempt
                    < List.fold_left
                        (fun m child -> max m child.max_restarts)
                        0 children ->
              let events =
                Restarted ("*", attempt + 1) :: Failed (name, cause) :: events
              in
              attempt_all (attempt + 1) events
          | (name, cause) :: _ ->
              {
                results;
                events = List.rev (Gave_up "*" :: Failed (name, cause) :: events);
              }
        in
        attempt_all 0 []
end

module type STRATEGY_SIG = sig
  val one_for_one_only_restarts_failed : ([> `Boom ], int) Supervisor.report
  val one_for_all_restarts_everyone : ([> `Boom ], int) Supervisor.report
end

let flaky name =
  {
    Supervisor.name;
    max_restarts = 1;
    run =
      (fun attempt ->
        if attempt = 0 then Error (Supervisor.Fail `Boom) else Ok 10);
  }

let stable name counter =
  {
    Supervisor.name;
    max_restarts = 1;
    run =
      (fun _ ->
        incr counter;
        Ok 1);
  }

let one_for_one_only_restarts_failed =
  let stable_runs = ref 0 in
  Supervisor.run ~strategy:One_for_one ~restart:On_failure
    [ flaky "bad"; stable "good" stable_runs ]

let one_for_all_restarts_everyone =
  let stable_runs = ref 0 in
  Supervisor.run ~strategy:One_for_all ~restart:On_failure
    [ flaky "bad"; stable "good" stable_runs ]

module _ : STRATEGY_SIG = struct
  let one_for_one_only_restarts_failed = one_for_one_only_restarts_failed
  let one_for_all_restarts_everyone = one_for_all_restarts_everyone
end
