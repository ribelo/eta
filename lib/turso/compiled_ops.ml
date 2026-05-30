(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types
open Connection
open Dsl_backend

let select db (compiled : _ Compiled.select) =
  match query db compiled.sql (params_to_values compiled.params) with
  | Result.Error _ as err -> err
  | Ok rows -> (
      match List.map compiled.decode rows with
      | values -> Ok values
      | exception Decode_failure failure ->
          Result.Error
            (Decode_error
               {
                 operation = compiled.sql;
                 message = decode_failure_message failure;
               }))

let returning db (compiled : _ Compiled.returning) =
  match query db compiled.sql (params_to_values compiled.params) with
  | Result.Error _ as err -> err
  | Ok rows -> (
      match List.map compiled.decode rows with
      | values -> Ok values
      | exception Decode_failure failure ->
          Result.Error
            (Decode_error
               {
                 operation = compiled.sql;
                 message = decode_failure_message failure;
               }))

let execute_compiled db (compiled : Compiled.change) =
  execute db compiled.sql (params_to_values compiled.params)

let run_schema db (schema : Compiled.schema) = exec_script db schema.sql
