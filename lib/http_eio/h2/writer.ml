(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type drain_result =
  | Yield of { written : int }
  | Close of {
      written : int;
      code : int;
    }

module H2 = Eta_http.H2

let cstruct_of_iovec
    ({ H2.IOVec.buffer; off; len } : Bigstringaf.t H2.IOVec.t) =
  Cstruct.of_bigarray ~off ~len buffer

let cstructs_of_iovecs iovecs = List.map cstruct_of_iovec iovecs

let cstruct_of_iovecs iovecs =
  let len = H2.IOVec.lengthv iovecs in
  let bytes = Bytes.create len in
  let dst_off = ref 0 in
  List.iter
    (fun ({ H2.IOVec.buffer; off; len } : Bigstringaf.t H2.IOVec.t) ->
      Bigstringaf.blit_to_bytes buffer ~src_off:off bytes ~dst_off:!dst_off
        ~len;
      dst_off := !dst_off + len)
    iovecs;
  Cstruct.of_bytes bytes

let write_iovecs ~flow iovecs =
  let len = H2.IOVec.lengthv iovecs in
  if len > 0 then Eio.Flow.write flow [ cstruct_of_iovecs iovecs ];
  len

let rec drain_client_loop ~flow client written =
  match H2.Connection.next_write_operation client with
  | Write iovecs ->
      let count = write_iovecs ~flow iovecs in
      H2.Connection.report_write_result client (`Ok count);
      drain_client_loop ~flow client (written + count)
  | Yield -> Yield { written }
  | Close code ->
      H2.Connection.report_write_result client `Closed;
      Close { written; code }

let drain_client ~flow client = drain_client_loop ~flow client 0

let wait_writer client =
  let wake = Eta.Channel.create ~capacity:1 () in
  H2.Connection.yield_writer client (fun () -> Eta.Channel.close wake);
  Eta.Channel.recv wake
  |> Eta.Effect.map (fun _ -> ())
  |> Eta.Effect.catch (function
       | `Closed | `Closed_with_error _ -> Eta.Effect.unit)

let rec run_client ~write client =
  match H2.Connection.next_write_operation client with
  | Write iovecs ->
      write iovecs
      |> Eta.Effect.bind (fun count ->
             Eta.Effect.sync (fun () ->
                 H2.Connection.report_write_result client (`Ok count)))
      |> Eta.Effect.bind (fun () -> run_client ~write client)
  | Yield -> wait_writer client |> Eta.Effect.bind (fun () -> run_client ~write client)
  | Close _ ->
      Eta.Effect.sync (fun () ->
          H2.Connection.report_write_result client `Closed)
