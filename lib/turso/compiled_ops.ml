(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types
open Connection
open Dsl_backend

let select db (compiled : _ Compiled.select) =
  match
    query db (Compiled.select_sql compiled) (Compiled.select_params compiled)
  with
  | Result.Error _ as err -> err
  | Ok rows -> (
      match List.map (Compiled.select_decode compiled) rows with
      | values -> Ok values
      | exception Decode_failure failure ->
          Result.Error
            (Decode_error
               {
                 operation = Compiled.select_sql compiled;
                 message = decode_failure_message failure;
               }))

let returning db (compiled : _ Compiled.returning) =
  match
    query db (Compiled.returning_sql compiled)
      (Compiled.returning_params compiled)
  with
  | Result.Error _ as err -> err
  | Ok rows -> (
      match List.map (Compiled.returning_decode compiled) rows with
      | values -> Ok values
      | exception Decode_failure failure ->
          Result.Error
            (Decode_error
               {
                 operation = Compiled.returning_sql compiled;
                 message = decode_failure_message failure;
               }))

let execute_compiled db (compiled : Compiled.change) =
  execute db (Compiled.change_sql compiled) (Compiled.change_params compiled)

let run_schema db (schema : Compiled.schema) =
  exec_script db (Compiled.schema_sql schema)
