(* Must fail at runtime if malformed traceparent is accepted. The defended
   property is that extract rejects invalid W3C trace IDs instead of silently
   correlating to a broken parent. *)

open Otel_propagation

let () =
  match
    P_b_core_context.extract
      [
        ( "traceparent",
          "00-00000000000000000000000000000000-00f067aa0ba902b7-01" );
      ]
  with
  | None -> ()
  | Some _ -> failwith "malformed traceparent was accepted"
