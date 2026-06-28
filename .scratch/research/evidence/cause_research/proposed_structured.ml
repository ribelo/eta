type interrupt_id = string

type 'err t =
  | Fail of 'err
  | Die of string
  | Interrupt of interrupt_id option
  | Sequential of 'err t list
  | Concurrent of 'err t list
  | Suppressed of { primary : 'err t; finalizer : 'err t }

let fail err = Fail err
let die msg = Die msg
let interrupt id = Interrupt id

let concurrent causes =
  match causes with
  | [] -> Die "empty concurrent cause"
  | [ one ] -> one
  | many -> Concurrent many

let sequential causes =
  match causes with
  | [] -> Die "empty sequential cause"
  | [ one ] -> one
  | many -> Sequential many

let suppressed ~primary ~finalizer = Suppressed { primary; finalizer }

let catch_fail f = function
  | Fail err -> f err
  | Die _ | Interrupt _ | Sequential _ | Concurrent _ | Suppressed _ -> None

let rec pp show_err = function
  | Fail err -> "Fail(" ^ show_err err ^ ")"
  | Die msg -> "Die(" ^ msg ^ ")"
  | Interrupt None -> "Interrupt"
  | Interrupt (Some id) -> "Interrupt(" ^ id ^ ")"
  | Sequential causes ->
      "Sequential[" ^ String.concat "; " (List.map (pp show_err) causes) ^ "]"
  | Concurrent causes ->
      "Concurrent[" ^ String.concat "; " (List.map (pp show_err) causes) ^ "]"
  | Suppressed { primary; finalizer } ->
      "Suppressed{primary=" ^ pp show_err primary ^ "; finalizer="
      ^ pp show_err finalizer ^ "}"

let otel_events show_err cause =
  let rec collect path acc = function
    | Fail err -> (path, "Fail:" ^ show_err err) :: acc
    | Die msg -> (path, "Die:" ^ msg) :: acc
    | Interrupt None -> (path, "Interrupt") :: acc
    | Interrupt (Some id) -> (path, "Interrupt:" ^ id) :: acc
    | Sequential causes ->
        causes
        |> List.mapi (fun i c -> (i, c))
        |> List.fold_left
             (fun acc (i, c) -> collect (path ^ ".seq." ^ string_of_int i) acc c)
             acc
    | Concurrent causes ->
        causes
        |> List.mapi (fun i c -> (i, c))
        |> List.fold_left
             (fun acc (i, c) ->
               collect (path ^ ".concurrent." ^ string_of_int i) acc c)
             acc
    | Suppressed { primary; finalizer } ->
        let acc = collect (path ^ ".primary") acc primary in
        collect (path ^ ".suppressed_finalizer") acc finalizer
  in
  List.rev (collect "cause" [] cause)

module F = Fixture.Make (struct
  type nonrec 'err t = 'err t

  let fail = fail
  let die = die
  let interrupt = interrupt
  let concurrent = concurrent
  let sequential = sequential
  let suppressed = suppressed
  let catch_fail = catch_fail
  let pp = pp
  let otel_events = otel_events
end)

module type LOCKED = sig
  type interrupt_id = string

  type 'err t =
    | Fail of 'err
    | Die of string
    | Interrupt of interrupt_id option
    | Sequential of 'err t list
    | Concurrent of 'err t list
    | Suppressed of { primary : 'err t; finalizer : 'err t }

  val par_two_failures : unit -> F.err t
  val sequential_tap_rethrow : unit -> F.err t
  val catch_single_fail : unit -> string option
  val catch_concurrent_failure : unit -> string option
end

module _ : LOCKED = struct
  type nonrec interrupt_id = interrupt_id

  type nonrec 'err t = 'err t =
    | Fail of 'err
    | Die of string
    | Interrupt of interrupt_id option
    | Sequential of 'err t list
    | Concurrent of 'err t list
    | Suppressed of { primary : 'err t; finalizer : 'err t }

  let par_two_failures = F.par_two_failures
  let sequential_tap_rethrow = F.sequential_tap_rethrow
  let catch_single_fail = F.catch_single_fail
  let catch_concurrent_failure = F.catch_concurrent_failure
end
