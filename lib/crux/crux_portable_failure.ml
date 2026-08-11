module Failure = Crux_failure.Failure

module Writer = struct
  type t = Buffer.t

  let create () = Buffer.create 128
  let byte writer value = Buffer.add_char writer (Char.chr value)

  let int32 writer value =
    let bytes = Bytes.create 4 in
    Bytes.set_int32_be bytes 0 value;
    Buffer.add_bytes writer bytes

  let int64 writer value =
    let bytes = Bytes.create 8 in
    Bytes.set_int64_be bytes 0 value;
    Buffer.add_bytes writer bytes

  let length writer value =
    if value < 0 || value > Int32.to_int Int32.max_int then
      invalid_arg "Eta_crux.Failure.encode_portable: value too large";
    int32 writer (Int32.of_int value)

  let string writer value =
    length writer (String.length value);
    Buffer.add_string writer value

  let option write writer = function
    | None -> byte writer 0
    | Some value ->
        byte writer 1;
        write writer value

  let list write writer values =
    length writer (List.length values);
    List.iter (write writer) values

  let contents writer = Buffer.to_bytes writer
end

module Reader = struct
  exception Invalid of string

  type t = {
    bytes : bytes;
    mutable position : int;
  }

  let create bytes = { bytes; position = 0 }
  let remaining reader = Bytes.length reader.bytes - reader.position

  let require reader count =
    if count < 0 || count > remaining reader then
      raise (Invalid "truncated portable failure")

  let byte reader =
    require reader 1;
    let value = Char.code (Bytes.get reader.bytes reader.position) in
    reader.position <- reader.position + 1;
    value

  let int32 reader =
    require reader 4;
    let value = Bytes.get_int32_be reader.bytes reader.position in
    reader.position <- reader.position + 4;
    value

  let int64 reader =
    require reader 8;
    let value = Bytes.get_int64_be reader.bytes reader.position in
    reader.position <- reader.position + 8;
    value

  let length reader =
    let value = int32 reader in
    if Int32.compare value 0l < 0 then
      raise (Invalid "negative portable failure length");
    Int32.to_int value

  let string reader =
    let length = length reader in
    require reader length;
    let value =
      Bytes.sub_string reader.bytes reader.position length
    in
    reader.position <- reader.position + length;
    value

  let option read reader =
    match byte reader with
    | 0 -> None
    | 1 -> Some (read reader)
    | _ -> raise (Invalid "invalid portable failure option")

  let list read reader =
    let count = length reader in
    if count > remaining reader then
      raise (Invalid "invalid portable failure list length");
    List.init count (fun _ -> read reader)

  let finish reader =
    if remaining reader <> 0 then
      raise (Invalid "trailing portable failure bytes")
end

let write_interrupt writer interrupt =
  Writer.int64 writer
    (Int64.of_int (Eta.Cause.interrupt_id_to_int interrupt))

let read_interrupt reader =
  let value = Reader.int64 reader in
  if
    Int64.compare value 0L <= 0
    || Int64.compare value (Int64.of_int max_int) > 0
  then
    raise (Reader.Invalid "invalid interruption identity");
  Eta.Cause.interrupt_id_of_int (Int64.to_int value)

let write_die writer (die : Eta.Cause.Portable.die) =
  Writer.string writer die.kind;
  Writer.string writer die.message;
  Writer.option Writer.string writer die.backtrace;
  Writer.option Writer.string writer die.span_name;
  Writer.list
    (fun writer (key, value) ->
      Writer.string writer key;
      Writer.string writer value)
    writer die.annotations

let read_die reader : Eta.Cause.Portable.die =
  let kind = Reader.string reader in
  let message = Reader.string reader in
  let backtrace = Reader.option Reader.string reader in
  let span_name = Reader.option Reader.string reader in
  let annotations =
    Reader.list
      (fun reader ->
        let key = Reader.string reader in
        let value = Reader.string reader in
        (key, value))
      reader
  in
  { kind; message; backtrace; span_name; annotations }

let rec write_finalizer writer = function
  | Eta.Cause.Portable.Finalizer.Fail error ->
      Writer.byte writer 0;
      Writer.string writer error
  | Die die ->
      Writer.byte writer 1;
      write_die writer die
  | Interrupt interrupt ->
      Writer.byte writer 2;
      Writer.option write_interrupt writer interrupt
  | Sequential causes ->
      Writer.byte writer 3;
      Writer.list write_finalizer writer causes
  | Concurrent causes ->
      Writer.byte writer 4;
      Writer.list write_finalizer writer causes
  | Finalizer cause ->
      Writer.byte writer 5;
      write_finalizer writer cause
  | Suppressed { primary; finalizer } ->
      Writer.byte writer 6;
      write_finalizer writer primary;
      write_finalizer writer finalizer

let rec read_finalizer reader =
  match Reader.byte reader with
  | 0 -> Eta.Cause.Portable.Finalizer.Fail (Reader.string reader)
  | 1 -> Die (read_die reader)
  | 2 -> Interrupt (Reader.option read_interrupt reader)
  | 3 -> Sequential (Reader.list read_finalizer reader)
  | 4 -> Concurrent (Reader.list read_finalizer reader)
  | 5 -> Finalizer (read_finalizer reader)
  | 6 ->
      let primary = read_finalizer reader in
      let finalizer = read_finalizer reader in
      Suppressed { primary; finalizer }
  | _ -> raise (Reader.Invalid "invalid portable finalizer tag")

let rec write_cause writer = function
  | Eta.Cause.Portable.Fail error ->
      Writer.byte writer 0;
      Writer.string writer error
  | Die die ->
      Writer.byte writer 1;
      write_die writer die
  | Interrupt interrupt ->
      Writer.byte writer 2;
      Writer.option write_interrupt writer interrupt
  | Sequential causes ->
      Writer.byte writer 3;
      Writer.list write_cause writer causes
  | Concurrent causes ->
      Writer.byte writer 4;
      Writer.list write_cause writer causes
  | Finalizer cause ->
      Writer.byte writer 5;
      write_finalizer writer cause
  | Suppressed { primary; finalizer } ->
      Writer.byte writer 6;
      write_cause writer primary;
      write_finalizer writer finalizer

let rec read_cause reader =
  let tag = Reader.byte reader in
  match tag with
  | 0 -> Eta.Cause.Portable.Fail (Reader.string reader)
  | 1 -> Die (read_die reader)
  | 2 -> Interrupt (Reader.option read_interrupt reader)
  | 3 -> Sequential (Reader.list read_cause reader)
  | 4 -> Concurrent (Reader.list read_cause reader)
  | 5 -> Finalizer (read_finalizer reader)
  | 6 ->
      let primary = read_cause reader in
      let finalizer = read_finalizer reader in
      Suppressed { primary; finalizer }
  | _ ->
      raise
        (Reader.Invalid
           (Printf.sprintf "invalid portable cause tag %d at %d"
              tag (reader.Reader.position - 1)))

let write_origin writer = function
  | Failure.Transition -> Writer.byte writer 0
  | Owned_work -> Writer.byte writer 1
  | Adapter_delivery -> Writer.byte writer 2
  | Request_dispatch -> Writer.byte writer 3
  | Export_dispatch -> Writer.byte writer 4
  | Cleanup -> Writer.byte writer 5
  | Crash_handler -> Writer.byte writer 6
  | Graph_clock -> Writer.byte writer 7

let read_origin reader =
  match Reader.byte reader with
  | 0 -> Failure.Transition
  | 1 -> Owned_work
  | 2 -> Adapter_delivery
  | 3 -> Request_dispatch
  | 4 -> Export_dispatch
  | 5 -> Cleanup
  | 6 -> Crash_handler
  | 7 -> Graph_clock
  | _ -> raise (Reader.Invalid "invalid failure origin")

let write_trigger writer = function
  | Failure.Initial_start -> Writer.byte writer 0
  | Endpoint_action -> Writer.byte writer 1
  | Transition_effect -> Writer.byte writer 2
  | Lifecycle_program -> Writer.byte writer 3
  | Source_opening -> Writer.byte writer 4
  | Source_producer -> Writer.byte writer 5
  | Local_export_invocation -> Writer.byte writer 6
  | Serialized_export_invocation -> Writer.byte writer 7
  | Outbound_request -> Writer.byte writer 8
  | Inbound_response -> Writer.byte writer 9
  | Request_cancellation -> Writer.byte writer 10
  | Output_delivery -> Writer.byte writer 11
  | Stop_teardown -> Writer.byte writer 12
  | Crash_teardown -> Writer.byte writer 13
  | Application_crash_handler -> Writer.byte writer 14
  | Clock_sample -> Writer.byte writer 15
  | Clock_due -> Writer.byte writer 16
  | Structural_reset -> Writer.byte writer 17
  | Poll_effect -> Writer.byte writer 18

let read_trigger reader =
  match Reader.byte reader with
  | 0 -> Failure.Initial_start
  | 1 -> Endpoint_action
  | 2 -> Transition_effect
  | 3 -> Lifecycle_program
  | 4 -> Source_opening
  | 5 -> Source_producer
  | 6 -> Local_export_invocation
  | 7 -> Serialized_export_invocation
  | 8 -> Outbound_request
  | 9 -> Inbound_response
  | 10 -> Request_cancellation
  | 11 -> Output_delivery
  | 12 -> Stop_teardown
  | 13 -> Crash_teardown
  | 14 -> Application_crash_handler
  | 15 -> Clock_sample
  | 16 -> Clock_due
  | 17 -> Structural_reset
  | 18 -> Poll_effect
  | _ -> raise (Reader.Invalid "invalid failure trigger")

let write_record writer (record : Failure.portable_record) =
  write_cause writer record.cause;
  write_origin writer record.origin;
  write_trigger writer record.trigger;
  Writer.int64 writer record.position

let read_record reader : Failure.portable_record =
  let cause = read_cause reader in
  let origin = read_origin reader in
  let trigger = read_trigger reader in
  let position = Reader.int64 reader in
  { cause; origin; trigger; position }

let encode (failure : Failure.portable) =
  let writer = Writer.create () in
  Buffer.add_string writer "ECF1";
  write_record writer failure.primary;
  Writer.list write_record writer failure.secondary;
  Writer.contents writer

let decode bytes =
  let reader = Reader.create bytes in
  try
    if Bytes.length bytes < 4
       || Bytes.sub_string bytes 0 4 <> "ECF1"
    then Error "invalid portable failure magic"
    else (
      reader.position <- 4;
      let primary = read_record reader in
      let secondary = Reader.list read_record reader in
      Reader.finish reader;
      Ok { Failure.primary; secondary })
  with
  | Reader.Invalid message -> Error message
  | Invalid_argument message -> Error message
