type t = {
  read_buffer_size : int;
  request_body_buffer_size : int;
  response_body_buffer_size : int;
  max_concurrent_streams : int;
  initial_window_size : int;
  max_header_list_size : int option;
  max_header_count : int;
}

let default =
  {
    read_buffer_size = 0x4000;
    request_body_buffer_size = 0x4000;
    response_body_buffer_size = 0x4000;
    max_concurrent_streams = 100;
    initial_window_size = 65535;
    max_header_list_size = None;
    max_header_count = Int.max_int;
  }

let to_settings t =
  Settings.create ~max_frame_size:t.read_buffer_size
    ~max_concurrent_streams:t.max_concurrent_streams
    ~initial_window_size:t.initial_window_size
    ~max_header_list_size:t.max_header_list_size ()
