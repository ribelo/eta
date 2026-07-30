open Eta

let parse_threshold raw =
  match Eta_observability.Log_level.of_string raw with
  | Some level -> level
  | None -> Eta_observability.Log_level.Info

let emitted threshold =
  Eta_observability.Log_level.all
  |> List.filter (fun level ->
         (not (Eta_observability.Log_level.equal level Eta_observability.Log_level.All))
         && (not (Eta_observability.Log_level.equal level Eta_observability.Log_level.Off))
         && Eta_observability.Log_level.is_enabled ~at:level ~threshold)

let format_levels levels =
  levels |> List.map Eta_observability.Log_level.to_string |> String.concat ","

let () =
  let threshold = parse_threshold "warn" in
  let enabled = emitted threshold in
  let otel_warn = Eta_observability.Log_level.to_otel_severity Eta_observability.Log_level.Warn in
  let severity_18 = Eta_observability.Log_level.of_otel_severity 18 in
  let off_enabled =
    Eta_observability.Log_level.is_enabled ~at:Eta_observability.Log_level.Fatal ~threshold:Eta_observability.Log_level.Off
  in
  let all_enabled =
    Eta_observability.Log_level.is_enabled ~at:Eta_observability.Log_level.Trace ~threshold:Eta_observability.Log_level.All
  in
  Format.printf
    "log-level:threshold=%a enabled=%s otel_warn=%d severity18=%a off=%b all=%b@."
    Eta_observability.Log_level.pp threshold (format_levels enabled) otel_warn Eta_observability.Log_level.pp
    severity_18 off_enabled all_enabled
