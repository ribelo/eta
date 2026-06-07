module Version = struct
  type t = int64

  type error =
    | Not_positive of int64
    | Invalid_integer of string
    | Expected_integer_value

  let from_int64 value =
    if Int64.compare value 0L <= 0 then
      Result.Error (Not_positive value)
    else
      Ok value

  let from_int value = from_int64 (Int64.of_int value)

  let from_string value =
    if String.equal value "" then
      Result.Error Expected_integer_value
    else
      match Int64.of_string value with
      | parsed -> from_int64 parsed
      | exception Failure _ -> Result.Error (Invalid_integer value)

  let from_int64_unchecked value = value
  let to_int64 value = value
  let to_string = Int64.to_string
  let equal = Int64.equal
  let compare = Int64.compare

  let error_to_string = function
    | Not_positive value -> "migration version must be positive: " ^ Int64.to_string value
    | Invalid_integer value -> "invalid migration version: " ^ value
    | Expected_integer_value -> "expected integer migration version"
end

module Table_name = struct
  type t = string

  type error =
    | Empty
    | Invalid_identifier of string

  let is_ident_start = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false

  let is_ident_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false

  let valid_part value start stop =
    start < stop && is_ident_start (String.unsafe_get value start)
    &&
    let rec loop index =
      index = stop
      || (is_ident_char (String.unsafe_get value index) && loop (index + 1))
    in
    loop (start + 1)

  let valid_parts value start stop =
    let rec loop part_start index =
      if index = stop then valid_part value part_start stop
      else if Char.equal (String.unsafe_get value index) '.' then
        valid_part value part_start index && loop (index + 1) (index + 1)
      else loop part_start (index + 1)
    in
    loop start start

  let from_string value =
    let start, stop = Eta.String_helpers.trim_bounds value in
    if start = stop then
      Result.Error Empty
    else if valid_parts value start stop then
      Ok
        (if start = 0 && stop = String.length value then value
         else String.sub value start (stop - start))
    else
      Result.Error
        (Invalid_identifier
           (if start = 0 && stop = String.length value then value
            else String.sub value start (stop - start)))

  let from_string_unchecked value = value
  let default = "__eta_migrations"
  let to_string value = value

  let error_to_string = function
    | Empty -> "migration table name must not be empty"
    | Invalid_identifier value -> "invalid migration table name: " ^ value
end

type migration_type =
  | Simple
  | Reversible_up
  | Reversible_down

let migration_type_to_string = function
  | Simple -> "simple"
  | Reversible_up -> "up"
  | Reversible_down -> "down"

let no_transaction_directive = "-- no-transaction"

let starts_with value prefix = Eta.String_helpers.starts_with value ~prefix

(* The directive only applies when it stands alone on the first line: the
   prefix must be followed by a newline, a CRLF, or end-of-string. Otherwise
   "-- no-transactional" would be mistaken for "-- no-transaction". *)
let has_no_transaction_directive sql =
  starts_with sql no_transaction_directive
  &&
  let offset = String.length no_transaction_directive in
  offset = String.length sql
  || Eta.String_helpers.starts_with_at sql ~offset "\n"
  || Eta.String_helpers.starts_with_at sql ~offset "\r\n"

let strip_no_transaction_directive sql =
  if has_no_transaction_directive sql then
    let offset = String.length no_transaction_directive in
    let len = String.length sql in
    if Eta.String_helpers.starts_with_at sql ~offset "\r\n" then
      String.sub sql (offset + 2) (len - offset - 2)
    else if Eta.String_helpers.starts_with_at sql ~offset "\n" then
      String.sub sql (offset + 1) (len - offset - 1)
    else
      String.sub sql offset (len - offset)
  else
    sql

let checksum_sql sql =
  Digest.to_hex (Digest.string (strip_no_transaction_directive sql))

module Migration = struct
  type t = {
    version : Version.t;
    description : string;
    migration_type : migration_type;
    sql : string;
    checksum : string;
    no_tx : bool;
  }

  let make ?(no_tx = false) ?checksum ~version ~description ~migration_type ~sql () =
    {
      version;
      description;
      migration_type;
      sql;
      checksum =
        (match checksum with
         | Some checksum -> checksum
         | None -> checksum_sql sql);
      no_tx;
    }
end

module Applied_migration = struct
  type t = {
    version : Version.t;
    checksum : string;
  }
end

module Config = struct
  type t = {
    table_name : Table_name.t;
    ignore_missing : bool;
  }

  let default = { table_name = Table_name.default; ignore_missing = false }
end

type applied = {
  migration : Migration.t;
  elapsed_ms : int;
}

type run_report = {
  applied : applied list;
  already_applied : Applied_migration.t list;
}

type source_error =
  | Read_migration_file_failed of {
      path : string;
      reason : string;
    }
  | Read_migration_directory_failed of {
      path : string;
      reason : string;
    }
  | Inspect_migration_path_failed of {
      path : string;
      reason : string;
    }

type error =
  | Source_error of source_error
  | Invalid_version of Version.error
  | Invalid_table_name of Table_name.error
  | Sql_error of Types.sql_error
  | Dirty of Version.t
  | Version_missing of Version.t
  | Version_mismatch of Version.t
  | Version_not_present of Version.t
  | Duplicate_migration_version of {
      version : Version.t;
      migration_type : migration_type;
    }
  | Migration_execution_error of {
      version : Version.t;
      error : Types.sql_error;
    }

module Source = struct
  type resolve_config = { ignored_checksum_chars : char list }
  [@@unboxed]

  let default_resolve_config = { ignored_checksum_chars = [] }

  type t =
    | Directory of string
    | Migrations of Migration.t list

  exception Read_file_failed of string * string

  let from_directory path = Directory path
  let from_migrations migrations = Migrations migrations

  let sort_migrations migrations =
    List.sort
      (fun left right -> Version.compare left.Migration.version right.version)
      migrations

  let rec version_mem version = function
    | [] -> false
    | candidate :: rest ->
        Version.equal version candidate || version_mem version rest

  let validate_unique_versions migrations =
    let rec loop executable_versions down_versions = function
      | [] -> Ok ()
      | migration :: rest -> (
          let version = migration.Migration.version in
          match migration.Migration.migration_type with
          | Simple | Reversible_up ->
              if version_mem version executable_versions then
                Result.Error
                  (Duplicate_migration_version
                     {
                       version;
                       migration_type = migration.Migration.migration_type;
                     })
              else loop (version :: executable_versions) down_versions rest
          | Reversible_down ->
              if version_mem version down_versions then
                Result.Error
                  (Duplicate_migration_version
                     { version; migration_type = Reversible_down })
              else loop executable_versions (version :: down_versions) rest)
    in
    loop [] [] migrations

  let resolve_migrations migrations =
    let migrations = sort_migrations migrations in
    match validate_unique_versions migrations with
    | Ok () -> Ok migrations
    | Result.Error _ as err -> err

  let has_suffix value suffix = Eta.String_helpers.ends_with value ~suffix

  let strip_suffix value suffix =
    if has_suffix value suffix then
      String.sub value 0 (String.length value - String.length suffix)
    else
      value

  let normalize_checksum_sql config sql =
    let sql = strip_no_transaction_directive sql in
    match config.ignored_checksum_chars with
    | [] -> sql
    | ignored ->
        let is_ignored char = List.exists (Char.equal char) ignored in
        let len = String.length sql in
        let index = ref 0 in
        let first_ignored = ref (-1) in
        while !first_ignored < 0 && !index < len do
          if is_ignored (String.unsafe_get sql !index) then
            first_ignored := !index
          else
            incr index
        done;
        if !first_ignored < 0 then
          sql
        else
          let buf = Buffer.create len in
          Buffer.add_substring buf sql 0 !first_ignored;
          for index = !first_ignored to len - 1 do
            let char = String.unsafe_get sql index in
            if not (is_ignored char) then Buffer.add_char buf char
          done;
          Buffer.contents buf

  let read_file path =
    match open_in_bin path with
    | input ->
        Fun.protect
          ~finally:(fun () -> close_in_noerr input)
          (fun () -> really_input_string input (in_channel_length input))
    | exception Sys_error reason ->
        raise (Sys_error reason)

  let is_regular_file path =
    match Unix.lstat path with
    | stats -> Ok (stats.Unix.st_kind = Unix.S_REG)
    | exception Unix.Unix_error (err, _, _) ->
        Result.Error (Unix.error_message err)
    | exception Sys_error reason -> Result.Error reason

  let parse_name name =
    if not (has_suffix name ".sql") then
      Ok None
    else
      match String.index_opt name '_' with
      | None -> Result.Error (Invalid_version Version.Expected_integer_value)
      | Some split -> (
          let version_text = String.sub name 0 split in
          match Version.from_string version_text with
          | Result.Error err -> Result.Error (Invalid_version err)
          | Ok version ->
              let rest =
                String.sub name (split + 1) (String.length name - split - 1)
              in
              let migration_type, raw_description =
                if has_suffix rest ".up.sql" then
                  (Reversible_up, strip_suffix rest ".up.sql")
                else if has_suffix rest ".down.sql" then
                  (Reversible_down, strip_suffix rest ".down.sql")
                else
                  (Simple, strip_suffix rest ".sql")
              in
              let description =
                String.map (fun c -> if Char.equal c '_' then ' ' else c) raw_description
              in
              Ok (Some (version, description, migration_type)))

  let resolve ?(config = default_resolve_config) = function
    | Migrations migrations ->
        resolve_migrations migrations
    | Directory dir -> (
        let entries =
          match Sys.readdir dir with
          | entries -> Array.to_list entries
          | exception Sys_error reason ->
              raise (Sys_error reason)
        in
        let rec loop acc = function
          | [] ->
              resolve_migrations acc
          | name :: rest -> (
              let path = Filename.concat dir name in
              match is_regular_file path with
              | Result.Error reason ->
                  Result.Error
                    (Source_error
                       (Inspect_migration_path_failed { path; reason }))
              | Ok false -> loop acc rest
              | Ok true -> (
                  match parse_name name with
                  | Result.Error _ as err -> err
                  | Ok None -> loop acc rest
                  | Ok (Some (version, description, migration_type)) ->
                      let sql =
                        match read_file path with
                        | sql -> sql
                        | exception Sys_error reason ->
                            raise (Read_file_failed (path, reason))
                      in
                      let no_tx = has_no_transaction_directive sql in
                      let checksum =
                        checksum_sql (normalize_checksum_sql config sql)
                      in
                      let migration =
                        Migration.make ~no_tx ~checksum ~version ~description
                          ~migration_type ~sql ()
                      in
                      loop (migration :: acc) rest))
        in
        match loop [] entries with
        | Ok _ as ok -> ok
        | Result.Error _ as err -> err
        | exception Read_file_failed (path, reason) ->
            Result.Error
              (Source_error
                 (Read_migration_file_failed { path; reason }))
        | exception Sys_error reason ->
            Result.Error
              (Source_error
                 (Read_migration_directory_failed { path = dir; reason })))
end

let error_to_string = function
  | Source_error (Read_migration_file_failed { path; reason }) ->
      "read migration file failed: " ^ path ^ ": " ^ reason
  | Source_error (Read_migration_directory_failed { path; reason }) ->
      "read migration directory failed: " ^ path ^ ": " ^ reason
  | Source_error (Inspect_migration_path_failed { path; reason }) ->
      "inspect migration path failed: " ^ path ^ ": " ^ reason
  | Invalid_version err -> Version.error_to_string err
  | Invalid_table_name err -> Table_name.error_to_string err
  | Sql_error err -> Types.show_error err
  | Dirty version -> "dirty migration version: " ^ Version.to_string version
  | Version_missing version -> "migration version missing: " ^ Version.to_string version
  | Version_mismatch version -> "migration checksum mismatch: " ^ Version.to_string version
  | Version_not_present version -> "migration version not present: " ^ Version.to_string version
  | Duplicate_migration_version { version; migration_type } ->
      "duplicate migration version: " ^ Version.to_string version ^ " ("
      ^ migration_type_to_string migration_type
      ^ ")"
  | Migration_execution_error { version; error } ->
      "migration " ^ Version.to_string version ^ " failed: " ^ Types.show_error error

let sql_error_of_pool_error = function
  | `Eta_sql err -> err
  | `Pool_shutdown -> Types.Pool_error "pool is shut down"
  | `Pool_shutdown_timeout -> Types.Pool_error "pool shutdown timed out"
  | `Timeout -> Types.Pool_error "operation timed out"

let effect_of_result = function
  | Ok value -> Eta.Effect.pure value
  | Result.Error err -> Eta.Effect.fail err

let with_pool_connection pool run =
  Pool.Raw.with_connection pool (fun conn ->
      Eta.Effect.sync (fun () -> run conn))
  |> Eta.Effect.catch (fun err ->
         Eta.Effect.pure
           (Result.Error (Sql_error (sql_error_of_pool_error err))))
  |> Eta.Effect.bind effect_of_result

type applied_state = {
  applied_version : Version.t;
  applied_checksum : string;
  applied_success : bool;
}

let table_name config = Dsl.quote_ident (Table_name.to_string config.Config.table_name)

let ensure_table conn config =
  let table = table_name config in
  Connection.Raw.execute_script conn
    ("CREATE TABLE IF NOT EXISTS " ^ table
   ^ " (version INTEGER PRIMARY KEY, description TEXT NOT NULL, checksum TEXT NOT NULL, success INTEGER NOT NULL, installed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, execution_time_ms INTEGER NOT NULL DEFAULT 0)")

let decode_applied_row row =
  match (Row.int64 "version" row, Row.string "checksum" row, Row.bool "success" row) with
  | Some version, Some checksum, Some success ->
      Ok { applied_version = version; applied_checksum = checksum; applied_success = success }
  | _ ->
      Result.Error
        (Sql_error
           (Types.Decode_error
              {
                operation = "migrate.list_applied";
                message = "migration table row has unexpected shape";
              }))

let load_applied_states conn config =
  match ensure_table conn config with
  | Result.Error err -> Result.Error (Sql_error err)
  | Ok () -> (
      match
        Connection.Raw.query conn
          ("SELECT version, checksum, success FROM " ^ table_name config ^ " ORDER BY version")
          []
      with
      | Result.Error err -> Result.Error (Sql_error err)
      | Ok rows ->
          let rec loop acc = function
            | [] -> Ok (List.rev acc)
            | row :: rest -> (
                match decode_applied_row row with
                | Ok applied -> loop (applied :: acc) rest
                | Result.Error _ as err -> err)
          in
          loop [] rows)

let applied_migration_of_state state =
  {
    Applied_migration.version = state.applied_version;
    checksum = state.applied_checksum;
  }

let successful_applied_migrations states =
  states
  |> List.filter (fun state -> state.applied_success)
  |> List.map applied_migration_of_state

let applied_migrations_at_or_before target states =
  states
  |> List.filter (fun state -> Version.compare state.applied_version target <= 0)
  |> List.map applied_migration_of_state

let applied_states_after target states =
  List.filter
    (fun state -> Version.compare state.applied_version target > 0)
    states

let list_applied ?(config = Config.default) pool =
  with_pool_connection pool @@ fun conn ->
    match load_applied_states conn config with
    | Result.Error _ as err -> err
    | Ok states -> Ok (successful_applied_migrations states)

let up_migrations migrations =
  migrations
  |> List.filter (fun migration ->
         match migration.Migration.migration_type with
         | Simple | Reversible_up -> true
         | Reversible_down -> false)

let migrations_at_or_before target migrations =
  List.filter
    (fun migration -> Version.compare migration.Migration.version target <= 0)
    migrations

let find_migration version migrations =
  List.find_opt (fun migration -> Version.equal migration.Migration.version version) migrations

let migration_already_applied migration states =
  List.exists
    (fun state ->
      state.applied_success
      && Version.equal state.applied_version migration.Migration.version)
    states

let migration_version_present target migrations =
  List.exists
    (fun migration -> Version.equal migration.Migration.version target)
    migrations

let validate_applied config migrations applied =
  let rec loop already = function
    | [] -> Ok (List.rev already)
    | state :: rest ->
        if not state.applied_success then
          Result.Error (Dirty state.applied_version)
        else (
          match find_migration state.applied_version migrations with
          | None when config.Config.ignore_missing ->
              loop
                ({
                   Applied_migration.version = state.applied_version;
                   checksum = state.applied_checksum;
                 }
                :: already)
                rest
          | None -> Result.Error (Version_missing state.applied_version)
          | Some migration ->
              if String.equal migration.Migration.checksum state.applied_checksum then
                loop
                  ({
                     Applied_migration.version = state.applied_version;
                     checksum = state.applied_checksum;
                   }
                  :: already)
                  rest
              else
                Result.Error (Version_mismatch state.applied_version))
  in
  loop [] applied

let elapsed_ms start =
  int_of_float ((Unix.gettimeofday () -. start) *. 1000.0)

let execute_body conn migration =
  if migration.Migration.no_tx then
    Connection.Raw.execute_script conn migration.Migration.sql
  else
    Connection.with_transaction conn (fun conn ->
        Connection.Raw.execute_script conn migration.Migration.sql)

let mark_dirty conn table migration =
  Connection.Raw.execute conn
    ("INSERT INTO " ^ table
   ^ " (version, description, checksum, success, installed_at, execution_time_ms) VALUES (?, ?, ?, 0, CURRENT_TIMESTAMP, 0)")
    [
      Value.Int64 migration.Migration.version;
      String migration.Migration.description;
      String migration.Migration.checksum;
    ]

let mark_success conn table migration elapsed =
  Connection.Raw.execute conn
    ("UPDATE " ^ table
   ^ " SET checksum = ?, success = 1, execution_time_ms = ? WHERE version = ?")
    [ Value.String migration.Migration.checksum; Int elapsed; Int64 migration.Migration.version ]

let apply_one conn config migration =
  let table = table_name config in
  match mark_dirty conn table migration with
  | Result.Error err ->
      Result.Error
        (Migration_execution_error { version = migration.Migration.version; error = err })
  | Ok _ -> (
      let start = Unix.gettimeofday () in
      match execute_body conn migration with
      | Result.Error err ->
          Result.Error
            (Migration_execution_error
               { version = migration.Migration.version; error = err })
      | Ok () ->
          let elapsed = elapsed_ms start in
          match mark_success conn table migration elapsed with
          | Result.Error err ->
              Result.Error
                (Migration_execution_error
                   { version = migration.Migration.version; error = err })
          | Ok _ -> Ok { migration; elapsed_ms = elapsed })

let run_migrations config pool migrations =
  with_pool_connection pool @@ fun conn ->
      match load_applied_states conn config with
      | Result.Error _ as err -> err
      | Ok applied_states -> (
          let up = up_migrations migrations in
          match validate_applied config up applied_states with
          | Result.Error _ as err -> err
          | Ok already_applied ->
              let rec loop acc = function
                | [] -> Ok { applied = List.rev acc; already_applied }
                | migration :: rest ->
                    if migration_already_applied migration applied_states then
                      loop acc rest
                    else (
                      match apply_one conn config migration with
                      | Ok applied -> loop (applied :: acc) rest
                      | Result.Error _ as err -> err)
              in
              loop [] up)

let run ?(config = Config.default) pool source =
  match Source.resolve source with
  | Result.Error err -> Eta.Effect.fail err
  | Ok migrations -> run_migrations config pool migrations

let run_to ?(config = Config.default) pool source ~target =
  match Source.resolve source with
  | Result.Error err -> Eta.Effect.fail err
  | Ok migrations ->
      let up = up_migrations migrations in
      if not (migration_version_present target up) then
        Eta.Effect.fail (Version_not_present target)
      else
        let migrations = migrations_at_or_before target migrations in
        run_migrations config pool migrations

let down_migration_for version migrations =
  List.find_opt
    (fun migration ->
      Version.equal migration.Migration.version version
      &&
      match migration.Migration.migration_type with
      | Reversible_down -> true
      | Simple | Reversible_up -> false)
    migrations

let undo ?(config = Config.default) pool source ~target =
  match Source.resolve source with
  | Result.Error err -> Eta.Effect.fail err
  | Ok migrations ->
      with_pool_connection pool @@ fun conn ->
          match load_applied_states conn config with
          | Result.Error _ as err -> err
          | Ok applied_states -> (
              let dirty =
                List.find_opt (fun state -> not state.applied_success) applied_states
              in
              match dirty with
              | Some state -> Result.Error (Dirty state.applied_version)
              | None ->
                  let to_undo =
                    applied_states_after target applied_states
                    |> List.sort (fun left right ->
                           Version.compare right.applied_version left.applied_version)
                  in
                  let table = table_name config in
                  let rec loop acc = function
                    | [] ->
                        Ok
                          {
                            applied = List.rev acc;
                            already_applied =
                              applied_migrations_at_or_before target applied_states;
                          }
                    | state :: rest -> (
                        match down_migration_for state.applied_version migrations with
                        | None -> Result.Error (Version_not_present state.applied_version)
                        | Some migration -> (
                            let start = Unix.gettimeofday () in
                            match execute_body conn migration with
                            | Result.Error err ->
                                Result.Error
                                  (Migration_execution_error
                                     { version = migration.Migration.version; error = err })
                            | Ok () -> (
                                match
                                  Connection.Raw.execute conn
                                    ("DELETE FROM " ^ table ^ " WHERE version = ?")
                                    [ Value.Int64 state.applied_version ]
                                with
                                | Result.Error err ->
                                    Result.Error
                                      (Migration_execution_error
                                         { version = migration.Migration.version; error = err })
                                | Ok _ ->
                                    loop
                                      ({ migration; elapsed_ms = elapsed_ms start } :: acc)
                                      rest)))
                  in
                  loop [] to_undo)
