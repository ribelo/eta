open Eta

type error = [ `Bad_trace_context | `Missing_context ]
[@@deriving eta_error]

let headers =
  [
    ( "TraceParent",
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" );
    ("tracestate", "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE");
    ("baggage", "tenant=acme,plan=pro");
  ]

let program ctx =
  let open Syntax in
  Eta_observability.with_context ctx
    (Eta_observability.named ~error_pp:pp_error "boundary.request"
       (let* current = Eta_observability.current_context in
        match current with
        | None -> Effect.fail `Missing_context
        | Some current -> Effect.pure current))

let has_assoc key value xs =
  match List.assoc_opt key xs with
  | Some actual -> String.equal actual value
  | None -> false

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  match Eta_observability.Trace_context.extract headers with
  | None ->
      Format.eprintf "trace context extraction failed@.";
      exit 1
  | Some ctx -> (
      let tracer = Eta_observability.Tracer.in_memory () in
      let rt =
        Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
          ~tracer:(Eta_observability.Tracer.as_capability tracer)
          ()
      in
      match Eta_eio.Runtime.run rt (program ctx) with
      | Exit.Ok current -> (
          let injected = Eta_observability.Trace_context.inject ctx in
          let spans = Eta_observability.Tracer.dump tracer in
          match spans with
          | [ span ] ->
              let preserves_context =
                String.equal current.trace_id ctx.trace_id
                && Eta_observability.Trace_context.sampled current
                && has_assoc "congo" "t61rcWkgMzE" current.trace_state
                && has_assoc "tenant" "acme" current.baggage
              in
              let external_parent =
                match span.Eta_observability.Tracer.external_parent with
                | None -> false
                | Some parent ->
                    String.equal parent.trace_id ctx.trace_id
                    && String.equal parent.span_id ctx.span_id
              in
              let injects_headers =
                has_assoc "traceparent"
                  "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
                  injected
                && has_assoc "baggage" "tenant=acme,plan=pro" injected
              in
              if preserves_context && external_parent && injects_headers then
                Format.printf
                  "trace-context:sampled=%b trace=%s parent=%s baggage=%s \
                   spans=%d@."
                  (Eta_observability.Trace_context.sampled current)
                  current.trace_id
                  (Option.value (List.assoc_opt "congo" current.trace_state)
                     ~default:"missing")
                  (Option.value (List.assoc_opt "tenant" current.baggage)
                     ~default:"missing")
                  (List.length spans)
              else (
                Format.eprintf "trace context produced unexpected state@.";
                exit 1)
          | _ ->
              Format.eprintf "trace context produced unexpected span count@.";
              exit 1)
      | Exit.Error cause ->
          Format.eprintf "trace context failed: %a@." (Cause.pp pp_error) cause;
          exit 1)
