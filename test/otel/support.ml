let now_ms clock () = int_of_float (Eio.Time.now clock *. 1000.0)

let runtime_factory ~sw ~clock tracer =
  Eta_eio.Runtime.create ~sw ~clock ~tracer ()

let create_exporter ~sw ~net ~clock ?host ?port ?traces_path ?logs_path
    ?metrics_path ?self_metrics_path ?disable_self_metrics ?debug ?service_name
    ?service_version ?resource_attrs ?scope_name ?headers ?queue_capacity
    ?on_error ?on_send () =
  let http_client = Eta_http_eio.Client.make_h1 ~sw ~net () in
  Eta_otel.create ~runtime_factory:(runtime_factory ~sw ~clock) ~http_client
    ~clock:(Eta_eio.clock clock) ~now_ms:(now_ms clock) ?host ?port
    ?traces_path ?logs_path ?metrics_path ?self_metrics_path
    ?disable_self_metrics ?debug ?service_name ?service_version ?resource_attrs
    ?scope_name ?headers ?queue_capacity ?on_error ?on_send ()
