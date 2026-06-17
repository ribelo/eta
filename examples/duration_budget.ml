open Eta

let retry_delay attempt =
  Duration.scale (Duration.times (Duration.ms 125) (1 lsl attempt)) 1.5
  |> Duration.clamp ~min:(Duration.ms 100) ~max:(Duration.seconds 2)

let retry_delays attempts =
  List.map retry_delay attempts

let average_duration durations =
  let total = List.fold_left Duration.add Duration.zero durations in
  Duration.divide total (List.length durations)

let format_ms duration =
  string_of_int (Duration.to_ms duration)

let format_delays durations =
  durations |> List.map format_ms |> String.concat ","

let () =
  let delays = retry_delays [ 0; 1; 2; 3; 4 ] in
  let average =
    match average_duration delays with
    | Some duration -> duration
    | None -> failwith "non-empty duration list divided by zero"
  in
  let io_budget =
    Duration.scale
      (Duration.subtract (Duration.seconds 5) (Duration.ms 250))
      0.5
  in
  let within_policy =
    List.for_all
      (Duration.between ~min:(Duration.ms 100) ~max:(Duration.seconds 2))
      delays
  in
  Format.printf "duration:delays=%s average=%a io=%a within=%b@."
    (format_delays delays) Duration.pp average Duration.pp io_budget
    within_policy
