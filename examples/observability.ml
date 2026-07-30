open Eta

type error = [ `Missing_user of string ]
[@@deriving eta_error]

let load_user id =
  Effect.sync_result (fun () ->
      if String.equal id "" then Error (`Missing_user id)
      else Ok ("user:" ^ id))

let program id =
  let open Syntax in
  Eta_observability.named ~error_pp:pp_error "example.request"
    (let* () =
       Eta_observability.log ~level:Eta_observability.Logger.Info
         ~attrs:[ ("route", "/users/:id") ]
         "request.started"
     in
     let* () =
       Eta_observability.metric_counter ~name:"example.requests"
         ~description:"handled example requests" ~unit_:"{request}"
         ~attrs:[ ("route", "/users/:id") ]
         (Eta_observability.Meter.Int 1)
     in
     let* user =
       load_user id
       |> Eta_observability.with_result_attrs
            ~ok_attrs:(fun user -> [ ("result", "ok"); ("user", user) ])
            ~err_attrs:(function
              | `Missing_user _ ->
                  [ ("result", "error"); ("error", "missing-user") ])
     in
     let* () = Eta_observability.event ~attrs:[ ("user", user) ] "request.user_loaded" in
     Effect.pure user)

let require label condition =
  if not condition then failwith ("missing observability signal: " ^ label)

let has_attr key value attrs =
  match List.assoc_opt key attrs with
  | Some actual -> String.equal actual value
  | None -> false

let verify user tracer logger meter =
  let spans = Eta_observability.Tracer.dump tracer in
  let logs = Eta_observability.Logger.dump logger in
  let metrics = Eta_observability.Meter.dump meter in
  let span =
    List.find
      (fun span -> String.equal span.Eta_observability.Tracer.name "example.request")
      spans
  in
  require "span status" (span.status = Eta_observability.Tracer.Ok);
  require "span result attr" (has_attr "result" "ok" span.attrs);
  require "span user attr" (has_attr "user" user span.attrs);
  require "span event"
    (List.exists
       (fun event -> String.equal event.Eta_observability.Tracer.ev_name "request.user_loaded")
       span.events);
  require "log record"
    (List.exists
       (fun record ->
         String.equal record.Eta_observability.Logger.body "request.started"
         && not (String.equal record.trace_id "")
         && not (String.equal record.span_id ""))
       logs);
  require "metric point"
    (List.exists
       (fun point ->
         String.equal point.Eta_observability.Meter.name "example.requests"
         && has_attr "route" "/users/:id" point.attrs)
       metrics);
  Format.printf "observability:%s spans=%d logs=%d metrics=%d@." user
    (List.length spans) (List.length logs) (List.length metrics)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta_observability.Tracer.in_memory () in
  let logger = Eta_observability.Logger.in_memory () in
  let meter = Eta_observability.Meter.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Eta_observability.Tracer.as_capability tracer)
      ~logger:(Eta_observability.Logger.as_capability logger) ~meter:(Eta_observability.Meter.as_capability meter)
      ()
  in
  match Eta_eio.Runtime.run rt (program "42") with
  | Exit.Ok user -> verify user tracer logger meter
  | Exit.Error cause ->
      Format.eprintf "observability failed: %a@." (Cause.pp pp_error) cause;
      exit 1
