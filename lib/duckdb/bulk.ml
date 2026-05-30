(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Dsl_backend

type 'table t = Appender.t

  let create ?schema connection table =
    Appender.create ?schema connection ~table:(Table.name table)

  let append_row appender row = Appender.append_row appender row
  let flush = Appender.flush
  let close = Appender.close

  let with_appender ?schema connection table f =
    match create ?schema connection table with
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
