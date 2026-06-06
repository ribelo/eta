(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type drain_result =
  | Yield of { written : int }
  | Close of {
      written : int;
      code : int;
    }

let cstruct_of_iovec ({ H2.IOVec.buffer; off; len } : Bigstringaf.t H2.IOVec.t) =
  Cstruct.of_bigarray ~off ~len buffer

let cstructs_of_iovecs iovecs = List.map cstruct_of_iovec iovecs

let write_iovecs ~flow iovecs =
  if H2.IOVec.lengthv iovecs = 0 then 0
  else Eio.Flow.single_write flow (cstructs_of_iovecs iovecs)

let rec drain_client_loop ~flow client written =
  match H2.Client_connection.next_write_operation client with
  | `Write iovecs ->
      let count = write_iovecs ~flow iovecs in
      H2.Client_connection.report_write_result client (`Ok count);
      drain_client_loop ~flow client (written + count)
  | `Yield -> Yield { written }
  | `Close code ->
      H2.Client_connection.report_write_result client `Closed;
      Close { written; code }

let drain_client ~flow client = drain_client_loop ~flow client 0

let wait_writer client =
  let wake = Eta.Channel.create ~capacity:1 () in
  H2.Client_connection.yield_writer client (fun () -> Eta.Channel.close wake);
  Eta.Channel.recv wake
  |> Eta.Effect.map (fun _ -> ())
  |> Eta.Effect.catch (function
       | `Closed | `Closed_with_error _ -> Eta.Effect.unit)

let rec run_client ~write client =
  match H2.Client_connection.next_write_operation client with
  | `Write iovecs ->
      write iovecs
      |> Eta.Effect.bind (fun count ->
             Eta.Effect.sync (fun () ->
                 H2.Client_connection.report_write_result client (`Ok count)))
      |> Eta.Effect.bind (fun () -> run_client ~write client)
  | `Yield -> wait_writer client |> Eta.Effect.bind (fun () -> run_client ~write client)
  | `Close _ ->
      Eta.Effect.sync (fun () ->
          H2.Client_connection.report_write_result client `Closed)
