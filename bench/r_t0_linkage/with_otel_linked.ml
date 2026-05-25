let () =
  let body =
    Otel.Internal.encode_traces_request ~resource_attrs:[] ~scope_name:"r-t0"
      []
  in
  Printf.printf "with_otel_linked=%d\n" (String.length body)

