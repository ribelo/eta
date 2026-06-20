type t = {
  read_buffer_size : int;
  request_body_buffer_size : int;
  response_body_buffer_size : int;
  max_concurrent_streams : int;
  initial_window_size : int;
  max_header_list_size : int option;
  max_header_count : int;
}

val default : t
val to_settings : t -> Settings.t
