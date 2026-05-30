(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types

type t = appender

let create ?schema connection ~table =
  if_connection_open connection @@ fun () ->
  wrap "appender create" (fun () ->
      { connection; raw = raw_appender_create connection.raw schema table; closed = false })

let append_row appender values =
  if_appender_open appender @@ fun () ->
  wrap "appender append row" (fun () -> raw_appender_append_row appender.raw values)

let flush appender =
  if_appender_open appender @@ fun () ->
  wrap "appender flush" (fun () -> raw_appender_flush appender.raw)

let close appender =
  if_appender_open appender @@ fun () ->
  match wrap "appender close" (fun () -> raw_appender_close appender.raw) with
  | Ok () ->
      appender.closed <- true;
      Ok ()
  | Result.Error _ as err -> err

let with_appender ?schema connection ~table f =
  match create ?schema connection ~table with
  | Result.Error _ as err -> err
  | Ok appender -> (
      match f appender with
      | Ok value -> (
          match close appender with
          | Ok () -> Ok value
          | Result.Error _ as err -> err)
      | Result.Error _ as err ->
          ignore (close appender);
          err
      | exception exn ->
          ignore (close appender);
          raise exn)
