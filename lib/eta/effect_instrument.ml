open Effect_core

let named_internal ?(kind = Capabilities.Internal) name eff =
  make ~leaf_name:name @@ fun frame ->
  try
    ok
      (Runtime_instrument.with_span ~runtime:frame.runtime
         ~error_renderer:frame.error_renderer ~fail_key:frame.fail_key ~kind
         ~name ~attrs:[] (fun () -> run_to_value frame eff))
  with exn -> exit_of_exn frame exn
