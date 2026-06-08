type error_code = Cancel | Refused_stream | Flow_control_error

type t =
  | Headers of { stream_id : int; tag : int; end_stream : bool }
  | Data of {
      stream_id : int;
      tag : int;
      bytes : int;
      end_stream : bool;
    }
  | Window_update of { stream_id : int; bytes : int }
  | Rst_stream of { stream_id : int; error : error_code }
  | Ping of int

let stream_id = function
  | Headers { stream_id; _ }
  | Data { stream_id; _ }
  | Window_update { stream_id; _ }
  | Rst_stream { stream_id; _ } ->
      Some stream_id
  | Ping _ -> None

let is_rst = function Rst_stream _ -> true | _ -> false
let is_data = function Data _ -> true | _ -> false
let is_ping = function Ping _ -> true | _ -> false
