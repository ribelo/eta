module Value = Value
module Row = Row

type database = Types.database
type connection = Types.connection
type appender = Types.appender

type config = Types.config = {
  path : string option;
  threads : int option;
}

type error = Types.error =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      message : string;
    }
  | Decode_error of {
      operation : string;
      message : string;
    }
  | Invalid_value of string
  | Closed

exception Error = Types.Error

type 'a typ = 'a Types.typ = {
  value : ('a -> Value.t);
  decode : (Row.t -> int -> 'a);
  sql_type : string;
}

let int = Types.int
let int64 = Types.int64
let bool = Types.bool
let float = Types.float
let text = Types.text
let blob = Types.blob
let decimal = Types.decimal
let date = Types.date
let time = Types.time
let timestamp = Types.timestamp
let uuid = Types.uuid
let json = Types.json
let enum = Types.enum
let list = Types.list
let value = Types.value
let nullable = Types.nullable

let pp_error = Types.pp_error
let show_error = Types.show_error
let available = Types.available
let version = Types.version

include Dsl_backend

module Database = Database
module Connection = Connection
module Appender = Appender
module Bulk_row = Bulk_row
module Bulk = Bulk
module Pool = Pool
