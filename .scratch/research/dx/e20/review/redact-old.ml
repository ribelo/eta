open Eta

let scrub_attrs attrs =
  List.map
    (fun (key, value) ->
      if String.equal key "password" then (key, "[redacted]")
      else (key, value))
    attrs

let redacting_logger (sink : Capabilities.logger) : Capabilities.logger =
  object
    method log (record : Capabilities.log_record) =
      sink#log { record with attrs = scrub_attrs record.attrs }
  end

let login ~sink =
  Effect.with_logger (redacting_logger sink)
    (Effect.log ~attrs:[ ("password", "open-sesame") ] "login")

(* A nested [with_logger other_sink] replaces this wrapper and therefore also
   replaces its redaction policy. The wrapper must be rebuilt around every sink
   that needs the policy. *)
