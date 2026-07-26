let result ~case ~depth ~status ~mode ?detail () =
  let detail =
    match detail with
    | None -> ""
    | Some detail ->
        let sanitized =
          String.map
            (function '\n' | '\r' | '\t' -> ' ' | character -> character)
            detail
        in
        " detail=" ^ sanitized
  in
  Printf.printf "RESULT case=%s depth=%d status=%s mode=%s%s\n%!" case depth
    status mode detail

let pass ~case ~depth = result ~case ~depth ~status:"PASS" ~mode:"none" ()

let fail ~case ~depth ~mode detail =
  result ~case ~depth ~status:"FAIL" ~mode ~detail ()

let classify_exception ~case ~depth = function
  | Stack_overflow -> fail ~case ~depth ~mode:"stack_overflow" "caught exception"
  | Out_of_memory -> fail ~case ~depth ~mode:"oom" "caught exception"
  | exn -> fail ~case ~depth ~mode:"exception" (Printexc.to_string exn)

let finish_exit ~case ~depth verify exit =
  match exit with
  | Eta.Exit.Error cause when Probe_cases.stack_overflow_in_cause cause ->
      fail ~case ~depth ~mode:"stack_overflow" "captured as an Eta defect"
  | exit -> (
      match verify exit with
      | Ok () -> pass ~case ~depth
      | Error detail -> fail ~case ~depth ~mode:"wrong_result" detail)

let arguments () =
  match Array.to_list Sys.argv with
  | [ _; case; depth ] -> (
      match int_of_string_opt depth with
      | Some depth -> Ok (case, depth)
      | None -> Error (Printf.sprintf "invalid depth %S" depth))
  | _ ->
      Error
        (Printf.sprintf "usage: %s CASE DEPTH; cases: %s" Sys.argv.(0)
           (String.concat ", " Probe_cases.cases))
