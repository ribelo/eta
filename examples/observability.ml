open Eta

type error = [ `Missing_user of string ]

let load_user id =
  Effect.sync_result (fun () ->
      if String.equal id "" then Error (`Missing_user id)
      else Ok ("user:" ^ id))

let program id =
  let open Syntax in
  Effect.named "example.request"
    (let* () =
       Effect.log ~level:Logger.Info
         ~attrs:[ ("route", "/users/:id") ]
         "request.started"
     in
     let* () =
       Effect.metric_update ~name:"example.requests"
         ~description:"handled example requests" ~unit_:"{request}"
         ~attrs:[ ("route", "/users/:id") ] ~kind:Meter.Counter_monotonic
         (Meter.Int 1)
     in
     let* user =
       load_user id
       |> Effect.with_result_attrs
            ~ok_attrs:(fun user -> [ ("result", "ok"); ("user", user) ])
            ~err_attrs:(function
              | `Missing_user _ ->
                  [ ("result", "error"); ("error", "missing-user") ])
     in
     let* () = Effect.event ~attrs:[ ("user", user) ] "request.user_loaded" in
     Effect.pure user)

let pp_error fmt = function
  | `Missing_user id -> Format.fprintf fmt "missing-user:%s" id

let require label condition =
  if not condition then failwith ("missing observability signal: " ^ label)

let has_attr key value attrs =
  match List.assoc_opt key attrs with
  | Some actual -> String.equal actual value
  | None -> false

let verify user tracer logger meter =
  let spans = Tracer.dump tracer in
  let logs = Logger.dump logger in
  let metrics = Meter.dump meter in
  let span =
    List.find
      (fun span -> String.equal span.Tracer.name "example.request")
      spans
  in
  require "span status" (span.status = Tracer.Ok);
  require "span result attr" (has_attr "result" "ok" span.attrs);
  require "span user attr" (has_attr "user" user span.attrs);
  require "span event"
    (List.exists
       (fun event -> String.equal event.Tracer.ev_name "request.user_loaded")
       span.events);
  require "log record"
    (List.exists
       (fun record ->
         String.equal record.Logger.body "request.started"
         && not (String.equal record.trace_id "")
         && not (String.equal record.span_id ""))
       logs);
  require "metric point"
    (List.exists
       (fun point ->
         String.equal point.Meter.name "example.requests"
         && has_attr "route" "/users/:id" point.attrs)
       metrics);
  Format.printf "observability:%s spans=%d logs=%d metrics=%d@." user
    (List.length spans) (List.length logs) (List.length metrics)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let logger = Logger.in_memory () in
  let meter = Meter.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer)
      ~logger:(Logger.as_capability logger) ~meter:(Meter.as_capability meter)
      ()
  in
  match Eta_eio.Runtime.run rt (program "42") with
  | Exit.Ok user -> verify user tracer logger meter
  | Exit.Error cause ->
      Format.eprintf "observability failed: %a@." (Cause.pp pp_error) cause;
      exit 1
