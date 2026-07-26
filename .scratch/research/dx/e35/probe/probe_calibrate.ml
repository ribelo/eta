(* Substrate calibration: does deep raw OCaml recursion survive on this
   backend, independent of Eta? *)

let rec nontail n = if n = 0 then 0 else 1 + nontail (n - 1)
let rec tail_loop acc n = if n = 0 then acc else tail_loop (acc + 1) (n - 1)

let run mode depth =
  let result =
    match mode with
    | "nontail" -> nontail depth
    | "tail" -> tail_loop 0 depth
    | other ->
        Printf.printf "CALIBRATE_ERROR unknown mode %s\n%!" other;
        exit 64
  in
  Printf.printf "CALIBRATE mode=%s depth=%d status=PASS value=%d\n%!" mode depth
    result

let () =
  match Array.to_list Sys.argv with
  | [ _; mode; depth ] -> (
      let depth = int_of_string depth in
      try run mode depth
      with exn ->
        Printf.printf "CALIBRATE mode=%s depth=%d status=FAIL exn=%s\n%!" mode
          depth (Printexc.to_string exn))
  | _ ->
      Printf.eprintf "usage: %s tail|nontail DEPTH\n%!" Sys.argv.(0);
      exit 64
