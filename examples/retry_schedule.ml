open Eta

type error = [ `Transient of int | `Fatal ]

let retry_policy () =
  Schedule.(
    both (recurs 3) (exponential ~factor:2.0 (Duration.ms 10))
    |> jittered ~min:1.0 ~max:2.0
    |> named "api.retry")

let retryable = function
  | `Transient _ -> true
  | `Fatal -> false

let call attempts =
  Effect.sync (fun () ->
      incr attempts;
      if !attempts < 3 then Error (`Transient !attempts)
      else Ok (Printf.sprintf "ok:%d" !attempts))
  |> Effect.flatten_result

let program attempts =
  call attempts |> Effect.retry ~schedule:(retry_policy ()) ~while_:retryable

let preview_delays ~seed count =
  let random = Capabilities.random_of_seed seed in
  let rec loop driver remaining acc =
    if remaining = 0 then List.rev acc
    else
      match Schedule.next ~now_ms:0 ~input:(`Transient 0) driver with
      | None -> List.rev acc
      | Some (metadata, next) ->
          loop next (remaining - 1) (Duration.to_ms metadata.delay :: acc)
  in
  loop (Schedule.start ~random (retry_policy ())) count []

let format_ints values =
  values |> List.map string_of_int |> String.concat ","

let pp_error fmt = function
  | `Transient attempt -> Format.fprintf fmt "transient:%d" attempt
  | `Fatal -> Format.pp_print_string fmt "fatal"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let seed = 17 in
  let attempts = ref 0 in
  let sleeps = ref [] in
  let sleep duration = sleeps := Duration.to_ms duration :: !sleeps in
  let random = Capabilities.random_of_seed seed in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~sleep ~random
      ()
  in
  match Eta_eio.Runtime.run rt (program attempts) with
  | Exit.Ok payload -> (
      let observed = List.rev !sleeps in
      let expected = preview_delays ~seed (List.length observed) in
      match (payload, !attempts, observed = expected) with
      | "ok:3", 3, true ->
          Format.printf
            "retry-schedule:payload=%s attempts=%d sleeps=%s expected=%s@."
            payload !attempts (format_ints observed) (format_ints expected)
      | _ ->
          Format.eprintf "retry schedule produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "retry schedule failed: %a@." (Cause.pp pp_error) cause;
      exit 1
