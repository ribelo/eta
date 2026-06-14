type t =
  | No_error
  | Protocol_error
  | Internal_error
  | Flow_control_error
  | Settings_timeout
  | Stream_closed
  | Frame_size_error
  | Refused_stream
  | Cancel
  | Compression_error
  | Connect_error
  | Enhance_your_calm
  | Inadequate_security
  | Http_1_1_required

let to_int = function
  | No_error -> 0
  | Protocol_error -> 1
  | Internal_error -> 2
  | Flow_control_error -> 3
  | Settings_timeout -> 4
  | Stream_closed -> 5
  | Frame_size_error -> 6
  | Refused_stream -> 7
  | Cancel -> 8
  | Compression_error -> 9
  | Connect_error -> 10
  | Enhance_your_calm -> 11
  | Inadequate_security -> 12
  | Http_1_1_required -> 13

let of_int = function
  | 0 -> Some No_error
  | 1 -> Some Protocol_error
  | 2 -> Some Internal_error
  | 3 -> Some Flow_control_error
  | 4 -> Some Settings_timeout
  | 5 -> Some Stream_closed
  | 6 -> Some Frame_size_error
  | 7 -> Some Refused_stream
  | 8 -> Some Cancel
  | 9 -> Some Compression_error
  | 10 -> Some Connect_error
  | 11 -> Some Enhance_your_calm
  | 12 -> Some Inadequate_security
  | 13 -> Some Http_1_1_required
  | _ -> None

let pp_hum fmt t =
  Format.pp_print_string fmt
    (match t with
    | No_error -> "NO_ERROR"
    | Protocol_error -> "PROTOCOL_ERROR"
    | Internal_error -> "INTERNAL_ERROR"
    | Flow_control_error -> "FLOW_CONTROL_ERROR"
    | Settings_timeout -> "SETTINGS_TIMEOUT"
    | Stream_closed -> "STREAM_CLOSED"
    | Frame_size_error -> "FRAME_SIZE_ERROR"
    | Refused_stream -> "REFUSED_STREAM"
    | Cancel -> "CANCEL"
    | Compression_error -> "COMPRESSION_ERROR"
    | Connect_error -> "CONNECT_ERROR"
    | Enhance_your_calm -> "ENHANCE_YOUR_CALM"
    | Inadequate_security -> "INADEQUATE_SECURITY"
    | Http_1_1_required -> "HTTP_1_1_REQUIRED")
