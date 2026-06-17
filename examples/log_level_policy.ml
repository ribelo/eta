open Eta

let parse_threshold raw =
  match Log_level.of_string raw with
  | Some level -> level
  | None -> Log_level.Info

let emitted threshold =
  Log_level.all
  |> List.filter (fun level ->
         (not (Log_level.equal level Log_level.All))
         && (not (Log_level.equal level Log_level.Off))
         && Log_level.is_enabled ~at:level ~threshold)

let format_levels levels =
  levels |> List.map Log_level.to_string |> String.concat ","

let () =
  let threshold = parse_threshold "warn" in
  let enabled = emitted threshold in
  let otel_warn = Log_level.to_otel_severity Log_level.Warn in
  let severity_18 = Log_level.of_otel_severity 18 in
  let off_enabled =
    Log_level.is_enabled ~at:Log_level.Fatal ~threshold:Log_level.Off
  in
  let all_enabled =
    Log_level.is_enabled ~at:Log_level.Trace ~threshold:Log_level.All
  in
  Format.printf
    "log-level:threshold=%a enabled=%s otel_warn=%d severity18=%a off=%b all=%b@."
    Log_level.pp threshold (format_levels enabled) otel_warn Log_level.pp
    severity_18 off_enabled all_enabled
