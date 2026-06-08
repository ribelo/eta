open Eta

let rec run conn outbound =
  Channel.recv outbound
  |> Effect.bind (fun frame ->
         Fake_multiplex_connection.write_frame conn frame
         |> Effect.bind (fun () -> run conn outbound))
  |> Effect.catch (function
       | `Closed | `Socket_closed -> Effect.unit
       | err -> Effect.fail err)
