include Eta_http_h1.Write

let flow_write_error ~method_ ~url =
  Error.make ~protocol:H1 ~method_ ~uri:(Url.to_string url)
    (Connection_closed { during = Http_request })

let write_to_flow flow ~method_ ~url ~headers ~body =
  let buffer = Buffer.create 512 in
  match write buffer ~method_ ~url ~headers ~body with
  | Error _ as error -> error
  | Ok () -> (
      try
        Eio.Flow.copy_string (Buffer.contents buffer) flow;
        Ok ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> Error (flow_write_error ~method_ ~url))
