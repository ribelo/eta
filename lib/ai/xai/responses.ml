module A = Eta_ai
module E = Eta.Effect
module H = Eta_http
module Json = A.Json
module C = Common
module Error = Xai_error

let ( let* ) = Result.bind

type function_tool = A.tool

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
  raw : A.Json.t;
}

type output_content =
  | Text of {
      text : string;
      annotations : annotation list;
      raw : A.Json.t;
    }
  | Refusal of {
      refusal : string;
      raw : A.Json.t;
    }
  | Unknown_content of A.Json.t

type message = {
  id : string option;
  status : string option;
  role : string option;
  content : output_content list;
  raw : A.Json.t;
}

type reasoning = {
  id : string option;
  summary : A.Json.t list;
  content : A.Json.t list;
  encrypted_content : string option;
  raw : A.Json.t;
}

type function_call = {
  id : string option;
  call_id : string option;
  name : string option;
  arguments : A.Json.t option;
  status : string option;
  raw : A.Json.t;
}

type server_tool_call = {
  id : string option;
  status : string option;
  raw : A.Json.t;
}

type file_search_call = {
  id : string option;
  status : string option;
  queries : string list;
  results : A.Json.t list;
  raw : A.Json.t;
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
      raw : A.Json.t;
    }
  | Unknown of A.Json.t

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
  | Json_schema of A.Json.t

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
  model : A.model;
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
  search_parameters : A.Json.t option;
  service_tier : service_tier option;
  user : string option;
  prompt_cache_key : string option;
}

let role_string = function
  | User -> "user"
  | Assistant -> "assistant"
  | System -> "system"
  | Developer -> "developer"

let input_content_json = function
  | Input_text text ->
      Json.object_
        [
          ("type", Some (Json.string "input_text"));
          ("text", Some (Json.string text));
        ]
  | Output_text text ->
      Json.object_
        [
          ("type", Some (Json.string "output_text"));
          ("text", Some (Json.string text));
        ]
  | Input_image { image_url } ->
      Json.object_
        [
          ("type", Some (Json.string "input_image"));
          ("image_url", Some (Json.string image_url));
        ]
  | Input_file source ->
      Json.object_
        (("type", Some (Json.string "input_file"))
        ::
        match source with
        | File_id value -> [ ("file_id", Some (Json.string value)) ]
        | File_data value -> [ ("file_data", Some (Json.string value)) ]
        | File_url value -> [ ("file_url", Some (Json.string value)) ])

let output_item_raw = function
  | Message item -> item.raw
  | Reasoning item -> item.raw
  | Function_call item -> item.raw
  | Web_search_call item
  | Code_interpreter_call item
  | Mcp_call item
  | Image_generation_call item ->
      item.raw
  | File_search_call item -> item.raw
  | Compaction { raw; _ } | Unknown raw -> raw

let input_item_json = function
  | Input_message { role; content } ->
      Json.object_
        [
          ("type", Some (Json.string "message"));
          ("role", Some (Json.string (role_string role)));
          ("content", Some (Json.array (List.map input_content_json content)));
        ]
  | Prior_output item -> output_item_raw item
  | Function_call_output { call_id; output } ->
      Json.object_
        [
          ("type", Some (Json.string "function_call_output"));
          ("call_id", Some (Json.string call_id));
          ("output", Some (Json.array (List.map input_content_json output)));
        ]
  | Compaction_input { id; encrypted_content } ->
      Json.object_
        [
          ("type", Some (Json.string "compaction"));
          ("id", Option.map Json.string id);
          ("encrypted_content", Some (Json.string encrypted_content));
        ]

let schema_json tool =
  match Json.parse tool.A.input_schema_json with
  | Ok schema -> Ok schema
  | Error message ->
      C.invalid ("function tool " ^ tool.name ^ " parameters: " ^ message)

let list_json values =
  if values = [] then None else Some (C.json_string_list values)

let tool_json = function
  | Function tool ->
      if Option.is_some tool.strict then
        C.invalid "xAI Responses function tools do not support strict"
      else
        let* parameters = schema_json tool in
        Ok
          (Json.object_
             [
               ("type", Some (Json.string "function"));
               ("name", Some (Json.string tool.name));
               ("parameters", Some parameters);
               ("description", Option.map Json.string tool.description);
             ])
  | Web_search tool ->
      if
        tool.allowed_domains <> [] && tool.excluded_domains <> []
      then C.invalid "web_search allowed_domains and excluded_domains are exclusive"
      else if
        List.length tool.allowed_domains > 5
        || List.length tool.excluded_domains > 5
      then C.invalid "web_search domain lists accept at most 5 domains"
      else
        Ok
          (Json.object_
             [
               ("type", Some (Json.string "web_search"));
               ("allowed_domains", list_json tool.allowed_domains);
               ("excluded_domains", list_json tool.excluded_domains);
               ("enable_image_search", Option.map Json.bool tool.enable_image_search);
               ( "enable_image_understanding",
                 Option.map Json.bool tool.enable_image_understanding );
             ])
  | X_search tool ->
      if
        List.length tool.allowed_x_handles > 10
        || List.length tool.excluded_x_handles > 10
      then C.invalid "x_search handle lists accept at most 10 handles"
      else
        Ok
          (Json.object_
             [
               ("type", Some (Json.string "x_search"));
               ("allowed_x_handles", list_json tool.allowed_x_handles);
               ("excluded_x_handles", list_json tool.excluded_x_handles);
               ("from_date", Option.map Json.string tool.from_date);
               ("to_date", Option.map Json.string tool.to_date);
               ( "enable_image_understanding",
                 Option.map Json.bool tool.enable_image_understanding );
               ( "enable_video_understanding",
                 Option.map Json.bool tool.enable_video_understanding );
             ])
  | Code_interpreter ->
      Ok (Json.object_ [ ("type", Some (Json.string "code_interpreter")) ])
  | File_search tool ->
      if List.length tool.vector_store_ids > 10 then
        C.invalid "file_search accepts at most 10 collection IDs"
      else
        Ok
          (Json.object_
             [
               ("type", Some (Json.string "file_search"));
               ( "vector_store_ids",
                 Some (C.json_string_list tool.vector_store_ids) );
               ("max_num_results", Option.map Json.int tool.max_num_results);
             ])
  | Mcp tool ->
      let headers =
        tool.headers
        |> List.map (fun (name, value) -> (name, Some (Json.string value)))
        |> Json.object_
      in
      Ok
        (Json.object_
           [
             ("type", Some (Json.string "mcp"));
             ("server_url", Some (Json.string tool.server_url));
             ("server_label", Some (Json.string tool.server_label));
             ("server_description", Option.map Json.string tool.server_description);
             ("allowed_tools", list_json tool.allowed_tools);
             ("authorization", Option.map Json.string tool.authorization);
             ("headers", if tool.headers = [] then None else Some headers);
           ])
  | Image_generation action ->
      let action =
        match action with Auto -> "auto" | Generate -> "generate" | Edit -> "edit"
      in
      Ok
        (Json.object_
           [
             ("type", Some (Json.string "image_generation"));
             ("action", Some (Json.string action));
           ])

let text_json { format } =
  let format =
    match format with
    | Text_format -> Json.object_ [ ("type", Some (Json.string "text")) ]
    | Json_object ->
        Json.object_ [ ("type", Some (Json.string "json_object")) ]
    | Json_schema schema ->
        Json.object_
          [
            ("type", Some (Json.string "json_schema"));
            ("schema", Some schema);
          ]
  in
  Json.object_ [ ("format", Some format) ]

let tool_choice_json = function
  | No_tools -> Json.string "none"
  | Auto_tools -> Json.string "auto"
  | Required_tools -> Json.string "required"
  | Function_tool name ->
      Json.object_
        [
          ("type", Some (Json.string "function"));
          ("name", Some (Json.string name));
        ]

let validate_optional_positive name = function
  | Some value when value < 0 -> C.invalid (name ^ " must not be negative")
  | _ -> Ok ()

let encode_request_json request =
  if String.trim request.model = "" then C.invalid "model must not be empty"
  else if
    Option.is_some request.instructions
    && Option.is_some request.previous_response_id
  then
    C.invalid
      "instructions cannot be combined with previous_response_id"
  else if List.length request.tools > 128 then
    C.invalid "Responses accepts at most 128 tools"
  else
    let* () = validate_optional_positive "max_turns" request.max_turns in
    let* () =
      validate_optional_positive "max_output_tokens" request.max_output_tokens
    in
    let* () = validate_optional_positive "top_k" request.top_k in
    let* temperature =
      match request.temperature with
      | None -> Ok None
      | Some value ->
          let* value = C.finite_float "temperature" value in
          if value < 0. || value > 2. then
            C.invalid "temperature must be between 0 and 2"
          else Ok (Json.float value)
    in
    let* top_p =
      match request.top_p with
      | None -> Ok None
      | Some value ->
          let* value = C.finite_float "top_p" value in
          if value <= 0. || value > 1. then
            C.invalid "top_p must be greater than 0 and at most 1"
          else Ok (Json.float value)
    in
    let* min_p =
      match request.min_p with
      | None -> Ok None
      | Some value ->
          let* value = C.finite_float "min_p" value in
          if value < 0. || value > 1. then
            C.invalid "min_p must be between 0 and 1"
          else Ok (Json.float value)
    in
    let* tools = C.result_map_all tool_json request.tools in
    let input =
      match request.input with
      | Text_input text -> Json.string text
      | Input_items items -> Json.array (List.map input_item_json items)
    in
    let reasoning =
      Option.map
        (fun value ->
          Json.object_
            [
              ("effort", Option.map Json.string value.effort);
              ("summary", Option.map Json.string value.summary);
              ("generate_summary", Option.map Json.bool value.generate_summary);
            ])
        request.reasoning
    in
    Ok
      (Json.object_
         [
           ("model", Some (Json.string request.model));
           ("input", Some input);
           ("instructions", Option.map Json.string request.instructions);
           ( "previous_response_id",
             Option.map Json.string request.previous_response_id );
           ("store", Option.map Json.bool request.store);
           ( "include",
             if request.include_ = [] then None
             else Some (C.json_string_list request.include_) );
           ("stream", Some (Json.bool request.stream));
           ("tools", if tools = [] then None else Some (Json.array tools));
           ("tool_choice", Option.map tool_choice_json request.tool_choice);
           ("parallel_tool_calls", Option.map Json.bool request.parallel_tool_calls);
           ("max_turns", Option.map Json.int request.max_turns);
           ("max_output_tokens", Option.map Json.int request.max_output_tokens);
           ("temperature", temperature);
           ("top_p", top_p);
           ("top_k", Option.map Json.int request.top_k);
           ("min_p", min_p);
           ("text", Option.map text_json request.text);
           ("reasoning", reasoning);
           ("reasoning_effort", Option.map Json.string request.reasoning_effort);
           ("search_parameters", request.search_parameters);
           ( "service_tier",
             Option.map
               (function Default -> Json.string "default" | Priority -> Json.string "priority")
               request.service_tier );
           ("user", Option.map Json.string request.user);
           ("prompt_cache_key", Option.map Json.string request.prompt_cache_key);
         ])

let encode_request request =
  encode_request_json request |> Result.map Json.to_string

let encode_websocket_create ?generate request =
  let* request_json = encode_request_json request in
  match request_json with
  | `Assoc fields ->
      let fields = List.remove_assoc "stream" fields in
      Ok
        (Json.to_string
           (`Assoc
             (("type", `String "response.create")
             :: (match generate with
                | None -> fields
                | Some value -> ("generate", `Bool value) :: fields))))
  | _ -> assert false

let content_of_eta_ai = function
  | A.Text text -> Ok (Input_text text)
  | A.Image { detail = None; url } -> Ok (Input_image { image_url = url })
  | A.Image { detail = Some _; _ } ->
      C.invalid "xAI Responses image detail has no settled wire contract"
  | A.Json _ ->
      C.invalid "provider-neutral JSON content has no xAI Responses input mapping"
  | A.Audio _ -> C.invalid "Responses input_audio is unavailable on xAI"
  | A.Video _ -> C.invalid "Responses video input is unavailable on xAI"

let input_items_of_prompt prompt =
  let message = function
    | A.System text ->
        Ok (Input_message { role = System; content = [ Input_text text ] })
    | A.User content ->
        let* content = C.result_map_all content_of_eta_ai content in
        Ok (Input_message { role = User; content })
    | A.Assistant { content; tool_calls = [] } ->
        let* content = C.result_map_all content_of_eta_ai content in
        Ok (Input_message { role = Assistant; content })
    | A.Assistant { tool_calls = _ :: _; _ } ->
        C.invalid
          "provider-neutral assistant tool calls cannot represent lossless xAI prior outputs"
    | A.Tool { tool_call_id; content } ->
        let* output = C.result_map_all content_of_eta_ai content in
        Ok (Function_call_output { call_id = tool_call_id; output })
  in
  C.result_map_all message prompt

let output_item_of_raw raw =
  let* json = C.parse_json raw in
  Ok (Prior_output (Unknown json))

let of_eta_ai request =
  let* () =
    match request.A.Responses.service_tier with
    | None | Some "default" | Some "priority" -> Ok ()
    | Some value -> C.invalid ("unsupported xAI service_tier " ^ value)
  in
  let* () =
    match request.text with
    | Some { A.Responses.format = A.Responses.Json_schema _ } ->
        C.invalid
          "provider-neutral JSON schema name/strict fields do not match xAI Responses"
    | _ -> Ok ()
  in
  let* input =
    match request.A.Responses.input with
    | A.Responses.Text text -> Ok (Text_input text)
    | A.Responses.Messages prompt ->
        input_items_of_prompt prompt |> Result.map (fun items -> Input_items items)
  in
  let* replay = C.result_map_all output_item_of_raw request.replay_items in
  let input =
    match (input, replay) with
    | Text_input _, _ :: _ ->
        (* This is rejected rather than assigning undocumented ordering. *)
        input
    | Text_input _, [] -> input
    | Input_items items, replay -> Input_items (replay @ items)
  in
  if replay <> [] && match input with Text_input _ -> true | _ -> false then
    C.invalid "provider replay items require item-array input"
  else
    Ok
      {
        model = request.model;
        input;
        instructions = request.instructions;
        previous_response_id = request.previous_response_id;
        store = request.store;
        include_ = request.include_;
        stream = request.stream;
        tools = request.tools;
        tool_choice =
          Option.map
            (function
              | A.Responses.None_ -> No_tools
              | A.Responses.Auto -> Auto_tools
              | A.Responses.Required -> Required_tools
              | A.Responses.Function name -> Function_tool name)
            request.tool_choice;
        parallel_tool_calls = request.parallel_tool_calls;
        max_turns = request.max_turns;
        max_output_tokens = request.max_output_tokens;
        temperature = request.temperature;
        top_p = request.top_p;
        top_k = request.top_k;
        min_p = request.min_p;
        text =
          Option.map
            (fun value ->
              {
                format =
                  (match value.A.Responses.format with
                  | A.Responses.Text -> Text_format
                  | A.Responses.Json_object -> Json_object
                  | A.Responses.Json_schema { schema; _ } -> Json_schema schema);
              })
            request.text;
        reasoning =
          Option.map
            (fun value ->
              {
                effort = value.A.Responses.effort;
                summary = value.summary;
                generate_summary = value.generate_summary;
              })
            request.reasoning;
        reasoning_effort = request.reasoning_effort;
        search_parameters = None;
        service_tier =
          (match request.service_tier with
          | None -> None
          | Some "default" -> Some Default
          | Some "priority" -> Some Priority
          | Some _ -> None);
        user = request.user;
        prompt_cache_key = request.prompt_cache_key;
      }

let annotation json =
  match (Json.string_member "type" json, Json.string_member "url" json) with
  | (Some "url_citation" | None), Some url ->
      Some
        {
          url;
          title = Json.string_member "title" json;
          start_index = Json.int_member "start_index" json;
          end_index = Json.int_member "end_index" json;
          raw = json;
        }
  | _ -> None

let output_content json =
  match Json.string_member "type" json with
  | Some "output_text" -> (
      match Json.string_member "text" json with
      | Some text ->
          let annotations =
            Json.array_member "annotations" json |> Option.value ~default:[]
            |> List.filter_map annotation
          in
          Text { text; annotations; raw = json }
      | None -> Unknown_content json)
  | Some "refusal" -> (
      match Json.string_member "refusal" json with
      | Some refusal -> Refusal { refusal; raw = json }
      | None -> Unknown_content json)
  | _ -> Unknown_content json

let server_tool_call json =
  {
    id = Json.string_member "id" json;
    status = Json.string_member "status" json;
    raw = json;
  }

let decode_output_item json =
  match Json.string_member "type" json with
  | Some "message" ->
      Message
        {
          id = Json.string_member "id" json;
          status = Json.string_member "status" json;
          role = Json.string_member "role" json;
          content =
            Json.array_member "content" json |> Option.value ~default:[]
            |> List.map output_content;
          raw = json;
        }
  | Some "reasoning" ->
      Reasoning
        {
          id = Json.string_member "id" json;
          summary = Json.array_member "summary" json |> Option.value ~default:[];
          content = Json.array_member "content" json |> Option.value ~default:[];
          encrypted_content = Json.string_member "encrypted_content" json;
          raw = json;
        }
  | Some "function_call" ->
      Function_call
        {
          id = Json.string_member "id" json;
          call_id = Json.string_member "call_id" json;
          name = Json.string_member "name" json;
          arguments = Json.member "arguments" json;
          status = Json.string_member "status" json;
          raw = json;
        }
  | Some "web_search_call" -> Web_search_call (server_tool_call json)
  | Some "code_interpreter_call" ->
      Code_interpreter_call (server_tool_call json)
  | Some "file_search_call" ->
      File_search_call
        {
          id = Json.string_member "id" json;
          status = Json.string_member "status" json;
          queries =
            Json.array_member "queries" json |> Option.value ~default:[]
            |> List.filter_map (function `String value -> Some value | _ -> None);
          results = Json.array_member "results" json |> Option.value ~default:[];
          raw = json;
        }
  | Some "mcp_call" -> Mcp_call (server_tool_call json)
  | Some "image_generation_call" ->
      Image_generation_call (server_tool_call json)
  | Some "compaction" -> (
      match Json.string_member "encrypted_content" json with
      | Some encrypted_content ->
          Compaction
            {
              id = Json.string_member "id" json;
              encrypted_content;
              raw = json;
            }
      | None -> Unknown json)
  | _ -> Unknown json

type usage = {
  input_tokens : int option;
  output_tokens : int option;
  total_tokens : int option;
  cached_tokens : int option;
  reasoning_tokens : int option;
  num_sources_used : int option;
  num_server_side_tools_used : int option;
  server_side_tool_usage_details : A.Json.t option;
  cost_in_usd_ticks : int64 option;
  cost_in_nano_usd : int64 option;
  context_details : A.Json.t option;
  raw : A.Json.t;
}

let usage json =
  let input_details = Json.object_member "input_tokens_details" json in
  let output_details = Json.object_member "output_tokens_details" json in
  {
    input_tokens = Json.int_member "input_tokens" json;
    output_tokens = Json.int_member "output_tokens" json;
    total_tokens = Json.int_member "total_tokens" json;
    cached_tokens = Option.bind input_details (Json.int_member "cached_tokens");
    reasoning_tokens =
      Option.bind output_details (Json.int_member "reasoning_tokens");
    num_sources_used = Json.int_member "num_sources_used" json;
    num_server_side_tools_used =
      Json.int_member "num_server_side_tools_used" json;
    server_side_tool_usage_details =
      Json.member "server_side_tool_usage_details" json;
    cost_in_usd_ticks = C.int64_member "cost_in_usd_ticks" json;
    cost_in_nano_usd = C.int64_member "cost_in_nano_usd" json;
    context_details = Json.member "context_details" json;
    raw = json;
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
  tools : A.Json.t list;
  tool_choice : A.Json.t option;
  parallel_tool_calls : bool option;
  text : A.Json.t option;
  reasoning : A.Json.t option;
  service_tier : string option;
  incomplete_details : A.Json.t option;
  usage : usage option;
  raw : A.raw_json;
}

let decode_response raw =
  let* json = C.parse_json raw in
  let* id = C.required_string "id" json in
  Ok
    {
      id;
      object_ = Json.string_member "object" json;
      created_at = C.int64_member "created_at" json;
      completed_at = C.int64_member "completed_at" json;
      model = Json.string_member "model" json;
      status = Json.string_member "status" json;
      store = C.bool_member "store" json;
      previous_response_id = Json.string_member "previous_response_id" json;
      output =
        Json.array_member "output" json |> Option.value ~default:[]
        |> List.map decode_output_item;
      tools = Json.array_member "tools" json |> Option.value ~default:[];
      tool_choice = Json.member "tool_choice" json;
      parallel_tool_calls = C.bool_member "parallel_tool_calls" json;
      text = Json.member "text" json;
      reasoning = Json.member "reasoning" json;
      service_tier = Json.string_member "service_tier" json;
      incomplete_details = Json.member "incomplete_details" json;
      usage = Option.map usage (Json.object_member "usage" json);
      raw;
    }

let output_texts output =
  output
  |> List.concat_map (function
       | Message item ->
           List.filter_map
             (function Text { text; _ } -> Some text | _ -> None)
             item.content
       | _ -> [])

let output_tool_calls output =
  output
  |> List.filter_map (function
       | Function_call item -> (
           match (item.call_id, item.name, item.arguments) with
           | Some id, Some name, Some (`String arguments_json) ->
               Some { A.id; name; arguments_json }
           | Some id, Some name, Some json ->
               Some { A.id; name; arguments_json = Json.compact json }
           | _ -> None)
       | _ -> None)

let to_eta_ai_response response =
  let text = String.concat "" (output_texts response.output) in
  let tool_calls = output_tool_calls response.output in
  let usage =
    Option.map
      (fun usage ->
        {
          A.input_tokens =
            {
              uncached =
                (match (usage.input_tokens, usage.cached_tokens) with
                | Some total, Some cached -> Some (max 0 (total - cached))
                | _ -> usage.input_tokens);
              total = usage.input_tokens;
              cache_read = usage.cached_tokens;
              cache_write = None;
            };
          output_tokens =
            {
              total = usage.output_tokens;
              text =
                (match (usage.output_tokens, usage.reasoning_tokens) with
                | Some total, Some reasoning -> Some (max 0 (total - reasoning))
                | _ -> usage.output_tokens);
              reasoning = usage.reasoning_tokens;
            };
          raw = [];
        })
      response.usage
  in
  {
    A.id = Some response.id;
    model = response.model;
    message =
      A.Assistant
        {
          content = if text = "" then [] else [ A.Text text ];
          tool_calls;
        };
    finish_reasons =
      (match response.status with
      | Some "completed" ->
          if tool_calls = [] then [ A.Stop ] else [ A.Tool_calls ]
      | Some "incomplete" -> [ A.Length ]
      | Some status -> [ A.Other status ]
      | None -> []);
    usage;
    replay_items =
      response.output
      |> List.filter_map (function
           | Reasoning _ | Compaction _ as item ->
               Some (Json.compact (output_item_raw item))
           | _ -> None);
    raw = Some response.raw;
  }

type deleted = {
  id : string;
  object_ : string option;
  deleted : bool;
  raw : A.raw_json;
}

let decode_deleted raw =
  let* json = C.parse_json raw in
  let* id = C.required_string "id" json in
  match C.bool_member "deleted" json with
  | Some deleted ->
      Ok
        {
          id;
          object_ = Json.string_member "object" json;
          deleted;
          raw;
        }
  | None -> C.decode_error ~raw_body:raw "deleted is missing or is not boolean"

type input_items_page = {
  data : A.Json.t list;
  has_more : bool;
  last_id : string option;
  continuation : string option;
  raw : A.raw_json;
}

let decode_input_items_page raw =
  let* json = C.parse_json raw in
  let* data = C.required_array "data" json in
  match C.bool_member "has_more" json with
  | None ->
      C.decode_error ~raw_body:raw
        "has_more is missing or is not a boolean"
  | Some has_more ->
      let last_id = Json.string_member "last_id" json in
      let* () =
        if has_more && Option.is_none last_id then
          C.decode_error ~raw_body:raw
            "last_id is required when has_more is true"
        else Ok ()
      in
      Ok
        {
          data;
          has_more;
          last_id;
          continuation = if has_more then last_id else None;
          raw;
        }

type compacted = {
  id : string option;
  object_ : string option;
  output : output_item list;
  raw : A.raw_json;
}

let decode_compacted raw =
  let* json = C.parse_json raw in
  Ok
    {
      id = Json.string_member "id" json;
      object_ = Json.string_member "object" json;
      output =
        Json.array_member "output" json |> Option.value ~default:[]
        |> List.map decode_output_item;
      raw;
    }

let endpoint = Option.value ~default:Endpoint.default_inference
let base_url endpoint = Endpoint.inference_base_url endpoint

let create_request ?endpoint:custom ~api_key request =
  let base_url = base_url (endpoint custom) in
  let* json = encode_request_json request in
  Ok
    (C.json_request ~headers:(C.inference_headers api_key) ~base_url
       ~meth:"POST" ~path:"/v1/responses" ~json ())

let retrieve_request ?endpoint:custom ~api_key ~response_id () =
  let base_url = base_url (endpoint custom) in
  C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"GET"
    ~path:("/v1/responses/" ^ response_id) ()

let delete_request ?endpoint:custom ~api_key ~response_id () =
  let base_url = base_url (endpoint custom) in
  C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"DELETE"
    ~path:("/v1/responses/" ^ response_id) ()

let list_input_items_request ?endpoint:custom ~api_key ~response_id ?limit
    ?order ?after () =
  let* () =
    match limit with
    | Some value when value < 1 || value > 100 ->
        C.invalid "input item list limit must be between 1 and 100"
    | _ -> Ok ()
  in
  let base_url = base_url (endpoint custom) in
  let path =
    C.with_query ("/v1/responses/" ^ response_id ^ "/input_items")
      [
        ("limit", Option.map string_of_int limit);
        ( "order",
          Option.map (function `Asc -> "asc" | `Desc -> "desc") order );
        ("after", after);
      ]
  in
  Ok
    (C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"GET"
       ~path ())

let compact_request ?endpoint:custom ~api_key request =
  let base_url = base_url (endpoint custom) in
  let request = { request with stream = false } in
  let* json = encode_request_json request in
  Ok
    (C.json_request ~headers:(C.inference_headers api_key) ~base_url
       ~meth:"POST" ~path:"/v1/responses/compact" ~json ())

let response_attrs (response : response) =
  [
    ("gen_ai.response.id", response.id);
  ]
  @
  (match response.model with
  | None -> []
  | Some model -> [ ("gen_ai.response.model", model) ])
  @
  (match response.status with
  | Some "completed" -> [ ("gen_ai.response.finish_reasons", "stop") ]
  | Some "incomplete" -> [ ("gen_ai.response.finish_reasons", "length") ]
  | Some status -> [ ("gen_ai.response.finish_reasons", status) ]
  | None -> [])
  @
  match response.usage with
  | None -> []
  | Some usage ->
      (match usage.input_tokens with
      | None -> []
      | Some value -> [ ("gen_ai.usage.input_tokens", string_of_int value) ])
      @
      match usage.output_tokens with
      | None -> []
      | Some value -> [ ("gen_ai.usage.output_tokens", string_of_int value) ]

let run_built ~base_url ~operation ?model ?result_attrs client decode request =
  match request with
  | Error error -> E.fail error
  | Ok request ->
      C.perform_json ~base_url ~operation ?model ?result_attrs client request
        decode

let create ?endpoint:custom client ~api_key (request : request) =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  create_request ~endpoint ~api_key request
  |> run_built ~base_url ~operation:"chat" ~model:request.model
       ~result_attrs:response_attrs client
       decode_response

let retrieve ?endpoint:custom client ~api_key ~response_id =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  C.perform_json ~base_url ~operation:"retrieve_response"
    ~result_attrs:response_attrs client
    (retrieve_request ~endpoint ~api_key ~response_id ())
    decode_response

let delete ?endpoint:custom client ~api_key ~response_id =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  C.perform_json ~base_url ~operation:"delete_response" client
    (delete_request ~endpoint ~api_key ~response_id ())
    decode_deleted

let list_input_items ?endpoint:custom client ~api_key ~response_id ?limit
    ?order ?after () =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  list_input_items_request ~endpoint ~api_key ~response_id ?limit ?order ?after ()
  |> run_built ~base_url ~operation:"list_response_input_items" client
       decode_input_items_page

let compact ?endpoint:custom client ~api_key (request : request) =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  compact_request ~endpoint ~api_key request
  |> run_built ~base_url ~operation:"compact_response" ~model:request.model client
       decode_compacted

type stream_event =
  | Done
  | Unknown_event of {
      type_ : string option;
      raw : A.raw_json;
    }

let trim = String.trim

let decode_stream_event event =
  if String.equal (trim event.A.data) "[DONE]" then Ok Done
  else
    let* json = C.parse_json event.data in
    Ok
      (Unknown_event
         { type_ = Json.string_member "type" json; raw = event.data })

let to_eta_ai_stream_events = function
  | Done -> [ A.Stream_done ]
  | Unknown_event _ -> []

type stream = {
  body : H.Body.Stream.t;
  buffer : Buffer.t;
  mutable pending : stream_event list;
  mutable ended : bool;
  mutable released : bool;
  active : bool Atomic.t;
}

let split_records buffer =
  let text = Buffer.contents buffer in
  let len = String.length text in
  let rec find index =
    if index + 1 >= len then None
    else if text.[index] = '\n' && text.[index + 1] = '\n' then
      Some (index, 2)
    else if
      index + 3 < len && String.sub text index 4 = "\r\n\r\n"
    then Some (index, 4)
    else find (index + 1)
  in
  let rec loop start acc =
    match find start with
    | None ->
        Buffer.clear buffer;
        Buffer.add_substring buffer text start (len - start);
        List.rev acc
    | Some (stop, separator) ->
        let record = String.sub text start (stop - start) in
        loop (stop + separator) (record :: acc)
  in
  loop 0 []

let parse_record record =
  let event = ref None and data = Buffer.create 128 in
  String.split_on_char '\n' record
  |> List.iter (fun line ->
         let line =
           if String.length line > 0 && line.[String.length line - 1] = '\r'
           then String.sub line 0 (String.length line - 1)
           else line
         in
         match String.index_opt line ':' with
         | None -> ()
         | Some index ->
             let name = String.sub line 0 index in
             let start =
               if index + 1 < String.length line && line.[index + 1] = ' '
               then index + 2
               else index + 1
             in
             let value = String.sub line start (String.length line - start) in
             if name = "event" then event := Some value
             else if name = "data" then begin
               if Buffer.length data > 0 then Buffer.add_char data '\n';
               Buffer.add_string data value
             end);
  if Buffer.length data = 0 then None
  else Some { A.event = !event; data = Buffer.contents data }

let decode_records records =
  let records = List.filter_map parse_record records in
  let rec loop decoded = function
    | [] -> Ok (List.rev decoded)
    | record :: rest -> (
        match decode_stream_event record with
        | Error _ as error -> error
        | Ok Done -> Ok (List.rev (Done :: decoded))
        | Ok event -> loop (event :: decoded) rest)
  in
  loop [] records

let release_stream stream =
  if stream.released then E.unit
  else begin
    stream.released <- true;
    H.Body.Stream.discard stream.body
    |> E.bind_error (fun error -> E.fail (Error.Http error))
  end

let close_stream_unlocked stream =
  stream.ended <- true;
  stream.pending <- [];
  Buffer.clear stream.buffer;
  release_stream stream

let fail_and_close stream error =
  stream.ended <- true;
  stream.pending <- [];
  Buffer.clear stream.buffer;
  E.fail error |> E.finally (release_stream stream)

let with_operation stream eff =
  if not (Atomic.compare_and_set stream.active false true) then
    E.fail (Error.Decode { message = "concurrent xAI SSE stream use"; raw_body = None })
  else
    eff
    |> E.finally (E.sync (fun () -> Atomic.set stream.active false))

let rec read_unlocked stream =
  match stream.pending with
  | event :: rest ->
      stream.pending <- rest;
      (match event with
      | Done ->
          stream.ended <- true;
          stream.pending <- [];
          release_stream stream
          |> E.map (fun () -> Some event)
      | Unknown_event _ -> E.pure (Some event))
  | [] when stream.ended -> E.pure None
  | [] ->
      H.Body.Stream.read stream.body
      |> E.bind_error (fun error -> fail_and_close stream (Error.Http error))
      |> E.bind (function
           | None ->
               stream.ended <- true;
               let trailing = Buffer.contents stream.buffer in
               Buffer.clear stream.buffer;
               let records = if String.trim trailing = "" then [] else [ trailing ] in
               (match decode_records records with
               | Error error -> fail_and_close stream error
               | Ok events ->
                   stream.pending <- events;
                   release_stream stream
                   |> E.bind (fun () -> read_unlocked stream))
           | Some bytes ->
               Buffer.add_bytes stream.buffer bytes;
               if Buffer.length stream.buffer > 1024 * 1024 then
                 fail_and_close stream
                   (Error.Decode
                      {
                        message = "xAI SSE buffer exceeded 1048576 bytes";
                        raw_body = None;
                      })
               else
                 match decode_records (split_records stream.buffer) with
                 | Error error -> fail_and_close stream error
                 | Ok events ->
                     stream.pending <- events;
                     read_unlocked stream)

let read_stream_event stream = with_operation stream (read_unlocked stream)
let close_stream stream = with_operation stream (close_stream_unlocked stream)

let stream ?endpoint:custom client ~api_key (request : request) =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  let model = request.model in
  let request = { request with stream = true } in
  match create_request ~endpoint ~api_key request with
  | Error error -> E.fail error
  | Ok request ->
      H.request client request
      |> A.suppress_provider_transport_observability
      |> E.bind_error (fun error -> E.fail (Error.Http error))
      |> E.bind (fun (response : H.Response.t) ->
             if response.status >= 200 && response.status < 300 then
               let stream =
                 {
                   body = response.body;
                   buffer = Buffer.create 4096;
                   pending = [];
                   ended = false;
                   released = false;
                   active = Atomic.make false;
                 }
               in
               E.timed
                 (H.Body.Stream.read stream.body
                 |> E.bind_error (fun error ->
                        fail_and_close stream (Error.Http error)))
               |> E.bind (fun (elapsed, chunk) ->
                      match chunk with
                      | None ->
                          stream.ended <- true;
                          release_stream stream |> E.map (fun () -> stream)
                      | Some bytes ->
                          Buffer.add_bytes stream.buffer bytes;
                          (match decode_records (split_records stream.buffer) with
                          | Error error -> fail_and_close stream error
                          | Ok events ->
                              stream.pending <- events;
                              E.pure stream
                              |> Eta_observability.annotate_all
                                   [
                                     ( "gen_ai.response.time_to_first_chunk",
                                       Printf.sprintf "%.3f"
                                         (Eta.Duration.to_seconds_float elapsed)
                                     );
                                   ]))
             else
               C.read_body response.body
               |> E.bind (fun body ->
                      E.fail
                        (Error.decode ~status:response.status
                           ~headers:response.headers
                           (Bytes.to_string body))))
      |> C.with_span ~base_url ~operation:"chat" ~model
           ~attrs:[ ("gen_ai.request.stream", "true") ]
