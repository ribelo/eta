(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = {
  header_table_size : int;
  enable_push : bool;
  max_concurrent_streams : int;
  initial_window_size : int;
  max_frame_size : int;
  max_header_list_size : int option;
}

let default = {
  header_table_size = 4096;
  enable_push = true;
  max_concurrent_streams = Int.max_int;
  initial_window_size = 65535;
  max_frame_size = 16384;
  max_header_list_size = None;
}

let host_default = {
  default with
  enable_push = false;
  max_concurrent_streams = 100;
  initial_window_size = 65535;
  max_frame_size = 16384;
}

let create ?(header_table_size = 4096) ?(enable_push = false)
    ?(max_concurrent_streams = 100) ?(initial_window_size = 65535)
    ?(max_frame_size = 16384) ?(max_header_list_size = None) () =
  {
    header_table_size;
    enable_push;
    max_concurrent_streams;
    initial_window_size;
    max_frame_size;
    max_header_list_size;
  }

let is_valid_max_frame_size n = n >= 16384 && n <= 16777215
let is_valid_initial_window_size n = n >= 0 && n <= 0x7fffffff

let validate s =
  if not (is_valid_max_frame_size s.max_frame_size) then
    Error Error_code.Frame_size_error
  else if not (is_valid_initial_window_size s.initial_window_size) then
    Error Error_code.Flow_control_error
  else Ok ()

let[@zero_alloc] byte n = Char.chr (n land 0xff)

let uint16 n =
  if n < 0 || n > 0xffff then
    invalid_arg "Eta_http.H2.Settings.uint16: value outside uint16";
  String.init 2 @@ function
  | 0 -> byte (n lsr 8)
  | 1 -> byte n
  | _ -> assert false

let apply_setting s = function
  | Frame.Settings.Header_table_size n -> { s with header_table_size = n }
  | Enable_push b -> { s with enable_push = b }
  | Max_concurrent_streams n -> { s with max_concurrent_streams = n }
  | Initial_window_size n -> { s with initial_window_size = n }
  | Max_frame_size n -> { s with max_frame_size = n }
  | Max_header_list_size n -> { s with max_header_list_size = Some n }

let encode s =
  let max_header_list_size = Option.value s.max_header_list_size ~default:0 in
  let pairs =
    [
      (1, s.header_table_size);
      (2, if s.enable_push then 1 else 0);
      (3, s.max_concurrent_streams);
      (4, s.initial_window_size);
      (5, s.max_frame_size);
      (6, max_header_list_size);
    ]
  in
  pairs
  |> List.map (fun (id, value) -> uint16 id ^ Frame.uint32 value)
  |> String.concat ""
