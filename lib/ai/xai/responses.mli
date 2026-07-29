(** xAI Responses request, resource, and HTTP SSE surface. *)

type function_tool = Eta_ai.tool

type web_search = {
  allowed_domains : string list;
  excluded_domains : string list;
  enable_image_search : bool option;
  enable_image_understanding : bool option;
}

type x_search = {
  allowed_x_handles : string list;
  excluded_x_handles : string list;
  from_date : string option;
  to_date : string option;
  enable_image_understanding : bool option;
  enable_video_understanding : bool option;
}

type file_search = {
  vector_store_ids : string list;
  max_num_results : int option;
}

type mcp = {
  server_url : string;
  server_label : string;
  server_description : string option;
  allowed_tools : string list;
  authorization : string option;
  headers : (string * string) list;
}

type image_action = Auto | Generate | Edit

type tool =
  | Function of function_tool
  | Web_search of web_search
  | X_search of x_search
  | Code_interpreter
  | File_search of file_search
  | Mcp of mcp
  | Image_generation of image_action

type role = User | Assistant | System | Developer

type input_file =
  | File_id of string
  | File_data of string
  | File_url of string

type input_content =
  | Input_text of string
  | Output_text of string
  | Input_image of { image_url : string }
  | Input_file of input_file

type annotation = {
  url : string;
  title : string option;
  start_index : int option;
  end_index : int option;
  raw : Eta_ai.Json.t;
}

type output_content =
  | Text of {
      text : string;
      annotations : annotation list;
      raw : Eta_ai.Json.t;
    }
  | Refusal of {
      refusal : string;
      raw : Eta_ai.Json.t;
    }
  | Unknown_content of Eta_ai.Json.t

type message = {
  id : string option;
  status : string option;
  role : string option;
  content : output_content list;
  raw : Eta_ai.Json.t;
}

type reasoning = {
  id : string option;
  summary : Eta_ai.Json.t list;
  content : Eta_ai.Json.t list;
  encrypted_content : string option;
  raw : Eta_ai.Json.t;
}

type function_call = {
  id : string option;
  call_id : string option;
  name : string option;
  arguments : Eta_ai.Json.t option;
  status : string option;
  raw : Eta_ai.Json.t;
}

type server_tool_call = {
  id : string option;
  status : string option;
  raw : Eta_ai.Json.t;
}

type file_search_call = {
  id : string option;
  status : string option;
  queries : string list;
  results : Eta_ai.Json.t list;
  raw : Eta_ai.Json.t;
}

type output_item =
  | Message of message
  | Reasoning of reasoning
  | Function_call of function_call
  | Web_search_call of server_tool_call
  | Code_interpreter_call of server_tool_call
  | File_search_call of file_search_call
  | Mcp_call of server_tool_call
  | Image_generation_call of server_tool_call
  | Compaction of {
      id : string option;
      encrypted_content : string;
      raw : Eta_ai.Json.t;
    }
  | Unknown of Eta_ai.Json.t

type input_item =
  | Input_message of {
      role : role;
      content : input_content list;
    }
  | Prior_output of output_item
  | Function_call_output of {
      call_id : string;
      output : input_content list;
    }
  | Compaction_input of {
      id : string option;
      encrypted_content : string;
    }

type input = Text_input of string | Input_items of input_item list

type text_format =
  | Text_format
  | Json_object
  | Json_schema of Eta_ai.Json.t

type text = { format : text_format }

type reasoning_config = {
  effort : string option;
  summary : string option;
  generate_summary : bool option;
}

type service_tier = Default | Priority

type tool_choice =
  | No_tools
  | Auto_tools
  | Required_tools
  | Function_tool of string

type request = {
  model : Eta_ai.model;
  input : input;
  instructions : string option;
  previous_response_id : string option;
  store : bool option;
  include_ : string list;
  stream : bool;
  tools : tool list;
  tool_choice : tool_choice option;
  parallel_tool_calls : bool option;
  max_turns : int option;
  max_output_tokens : int option;
  temperature : float option;
  top_p : float option;
  top_k : int option;
  min_p : float option;
  text : text option;
  reasoning : reasoning_config option;
  reasoning_effort : string option;
  search_parameters : Eta_ai.Json.t option;
  service_tier : service_tier option;
  user : string option;
  prompt_cache_key : string option;
}

val of_eta_ai :
  tool Eta_ai.Responses.request -> (request, Xai_error.t) result
(** Convert the provider-neutral Responses subset. Provider replay items become
    typed prior output items. *)

val encode_request : request -> (Eta_ai.raw_json, Xai_error.t) result

type usage = {
  input_tokens : int option;
  output_tokens : int option;
  total_tokens : int option;
  cached_tokens : int option;
  reasoning_tokens : int option;
  num_sources_used : int option;
  num_server_side_tools_used : int option;
  server_side_tool_usage_details : Eta_ai.Json.t option;
  cost_in_usd_ticks : int64 option;
  cost_in_nano_usd : int64 option;
  context_details : Eta_ai.Json.t option;
  raw : Eta_ai.Json.t;
}

type response = {
  id : string;
  object_ : string option;
  created_at : int64 option;
  completed_at : int64 option;
  model : string option;
  status : string option;
  store : bool option;
  previous_response_id : string option;
  output : output_item list;
  tools : Eta_ai.Json.t list;
  tool_choice : Eta_ai.Json.t option;
  parallel_tool_calls : bool option;
  text : Eta_ai.Json.t option;
  reasoning : Eta_ai.Json.t option;
  service_tier : string option;
  incomplete_details : Eta_ai.Json.t option;
  usage : usage option;
  raw : Eta_ai.raw_json;
}

val decode_response : Eta_ai.raw_json -> (response, Xai_error.t) result
val to_eta_ai_response : response -> Eta_ai.response

type deleted = {
  id : string;
  object_ : string option;
  deleted : bool;
  raw : Eta_ai.raw_json;
}

type input_items_page = {
  data : Eta_ai.Json.t list;
  has_more : bool;
  last_id : string option;
  continuation : string option;
  raw : Eta_ai.raw_json;
}

type compacted = {
  id : string option;
  object_ : string option;
  output : output_item list;
  raw : Eta_ai.raw_json;
}

val create_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  request ->
  (Eta_http.Request.t, Xai_error.t) result

val retrieve_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  response_id:string ->
  unit ->
  Eta_http.Request.t

val delete_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  response_id:string ->
  unit ->
  Eta_http.Request.t

val list_input_items_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  response_id:string ->
  ?limit:int ->
  ?order:[ `Asc | `Desc ] ->
  ?after:string ->
  unit ->
  (Eta_http.Request.t, Xai_error.t) result

val compact_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  request ->
  (Eta_http.Request.t, Xai_error.t) result

val create :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  request ->
  (response, Xai_error.t) Eta.Effect.t

val retrieve :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  response_id:string ->
  (response, Xai_error.t) Eta.Effect.t

val delete :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  response_id:string ->
  (deleted, Xai_error.t) Eta.Effect.t

val list_input_items :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  response_id:string ->
  ?limit:int ->
  ?order:[ `Asc | `Desc ] ->
  ?after:string ->
  unit ->
  (input_items_page, Xai_error.t) Eta.Effect.t

val compact :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  request ->
  (compacted, Xai_error.t) Eta.Effect.t

type stream_event =
  | Done
  | Unknown_event of {
      type_ : string option;
      raw : Eta_ai.raw_json;
    }

val decode_stream_event : Eta_ai.sse_event -> (stream_event, Xai_error.t) result
val to_eta_ai_stream_events : stream_event -> Eta_ai.stream_event list

type stream

val stream :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  request ->
  (stream, Xai_error.t) Eta.Effect.t

val read_stream_event :
  stream -> (stream_event option, Xai_error.t) Eta.Effect.t

val close_stream : stream -> (unit, Xai_error.t) Eta.Effect.t
