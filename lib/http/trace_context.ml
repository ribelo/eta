let extract_request request =
  Eta.Trace_context.extract (Header.to_list request.Request.headers)

let inject_header headers (name, value) =
  Header.unsafe_add name value (Header.remove name headers)

let inject_request ctx request =
  let headers =
    List.fold_left inject_header request.Request.headers (Eta.Trace_context.inject ctx)
  in
  { request with Request.headers = headers }
