type 'err t =
  | Fail of 'err
  | Die of string
  | Interrupt
  | Both of 'err t * 'err t

let fail err = Fail err
let die msg = Die msg
let interrupt _id = Interrupt

let pairwise = function
  | [] -> Die "empty cause"
  | [ one ] -> one
  | first :: rest -> List.fold_left (fun acc cause -> Both (acc, cause)) first rest

let concurrent causes = pairwise causes
let sequential causes = pairwise causes
let suppressed ~primary ~finalizer = Both (primary, finalizer)

let catch_fail f = function
  | Fail err -> f err
  | Die _ | Interrupt | Both _ -> None

let rec pp show_err = function
  | Fail err -> "Fail(" ^ show_err err ^ ")"
  | Die msg -> "Die(" ^ msg ^ ")"
  | Interrupt -> "Interrupt"
  | Both (left, right) ->
      "Both(" ^ pp show_err left ^ ", " ^ pp show_err right ^ ")"

let otel_events show_err cause =
  let rec collect acc = function
    | Both (left, right) -> collect (collect acc left) right
    | Fail err -> ("exception", "Fail:" ^ show_err err) :: acc
    | Die msg -> ("exception", "Die:" ^ msg) :: acc
    | Interrupt -> ("exception", "Interrupt") :: acc
  in
  List.rev (collect [] cause)

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
  type 'err t =
    | Fail of 'err
    | Die of string
    | Interrupt
    | Both of 'err t * 'err t

  val par_two_failures : unit -> F.err t
  val sequential_tap_rethrow : unit -> F.err t
  val catch_single_fail : unit -> string option
  val catch_concurrent_failure : unit -> string option
end

module _ : LOCKED = struct
  type nonrec 'err t = 'err t =
    | Fail of 'err
    | Die of string
    | Interrupt
    | Both of 'err t * 'err t

  let par_two_failures = F.par_two_failures
  let sequential_tap_rethrow = F.sequential_tap_rethrow
  let catch_single_fail = F.catch_single_fail
  let catch_concurrent_failure = F.catch_concurrent_failure
end
