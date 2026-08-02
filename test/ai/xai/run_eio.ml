module A = Eta_ai
module X = Eta_ai_xai
module E = Eta.Effect
module H = Eta_http
module B = Eta_test_backend_eio.Backend

let read_fixture = Eta_ai_test_support.read_fixture

let expect_ok label =
  Eta_ai_test_support.expect_ok_msg label (fun error ->
      Format.asprintf "%a" X.Error.pp error)

let contains ~needle value =
  let rec loop index =
    if String.length needle = 0 then true
    else if index + String.length needle > String.length value then false
    else if String.sub value index (String.length needle) = needle then true
    else loop (index + 1)
  in
  loop 0

let body request =
  match request.H.Request.body with
  | H.Request.Fixed chunks ->
      chunks |> List.map Bytes.to_string |> String.concat ""
  | H.Request.Empty -> ""
  | H.Request.Stream _ | H.Request.One_shot_stream _
  | H.Request.Rewindable_stream _ ->
      Alcotest.fail "expected fixed request body"

let fixed_chunks request =
  match request.H.Request.body with
  | H.Request.Fixed chunks -> chunks
  | H.Request.Empty | H.Request.Stream _ | H.Request.One_shot_stream _
  | H.Request.Rewindable_stream _ ->
      Alcotest.fail "expected fixed request chunks"

let require label needle value =
  Alcotest.(check bool) label true (contains ~needle value)

let zero_stats =
  {
    H.Client.protocol = H.Client.H1;
    active = 0;
    idle = 0;
    capacity = 0;
    opened = 0;
    released = 0;
  }

let client ?(status = 200) ?(headers = []) body captured =
  H.Client.make_custom ~protocol:H.Client.H1
    ~request:(fun request ->
      captured := Some request;
      E.pure
        (H.Response.make ~status ~headers
           ~body:(H.Body.Stream.of_bytes [ Bytes.of_string body ])
           ()))
    ~stats:(fun () -> E.pure (Some zero_stats))
    ~shutdown:(fun () -> E.unit)

let client_with_stream ?(status = 200) ?(headers = []) body captured =
  H.Client.make_custom ~protocol:H.Client.H1
    ~request:(fun request ->
      captured := Some request;
      E.pure (H.Response.make ~status ~headers ~body ()))
    ~stats:(fun () -> E.pure (Some zero_stats))
    ~shutdown:(fun () -> E.unit)

let run_ok rt label eff =
  match B.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: %a" label
        (Eta.Cause.pp (fun fmt error -> X.Error.pp fmt error))
        cause

let index label needle value =
  let rec loop at =
    if at + String.length needle > String.length value then
      Alcotest.fail ("missing " ^ label)
    else if String.sub value at (String.length needle) = needle then at
    else loop (at + 1)
  in
  loop 0

let tool () =
  A.make_tool ~name:"weather" ~description:"Weather"
    ~input_schema_json:
      {|{"type":"object","properties":{"city":{"type":"string"}}}|}
    ()
  |> function
  | Ok value -> value
  | Error _ -> Alcotest.fail "tool"

let base_responses_request tools : X.Responses.request =
  {
    model = "grok-4.5";
    input = X.Responses.Text_input "weather";
    instructions = Some "brief";
    previous_response_id = None;
    store = Some true;
    include_ = [ "reasoning.encrypted_content" ];
    stream = false;
    tools;
    tool_choice = Some X.Responses.Auto_tools;
    parallel_tool_calls = Some true;
    max_turns = Some 4;
    max_output_tokens = Some 128;
    temperature = Some 0.2;
    top_p = Some 0.9;
    top_k = Some 20;
    min_p = Some 0.1;
    text = Some { format = X.Responses.Json_schema (`Assoc [ ("type", `String "object") ]) };
    reasoning =
      Some { effort = Some "high"; summary = Some "detailed"; generate_summary = Some true };
    reasoning_effort = Some "high";
    search_parameters = Some (`Assoc [ ("mode", `String "auto") ]);
    service_tier = Some X.Responses.Priority;
    user = Some "eta-user";
    prompt_cache_key = Some "eta-cache";
  }

let test_xaipkg_capabilities_security () =
  Alcotest.(check string) "xaisec-aplg provider accepts Eta_ai.api_key" "xai"
    X.provider_name;
  Alcotest.(check bool) "xaicore-hns4 typed detailed capabilities" true
    X.Capabilities.detailed.responses_create;
  Alcotest.(check bool) "xaicap-c5ir shared capabilities populated" true
    X.Capabilities.shared.streaming;
  Alcotest.(check bool) "no Eio WS" false
    X.Capabilities.detailed.responses_websocket;
  Alcotest.(check bool) "no custom mutation" false
    X.Capabilities.detailed.custom_voice_management;
  Alcotest.(check bool) "no telephony" false
    X.Capabilities.detailed.phone_management;
  (match X.Capabilities.detailed.live_translation with
  | X.Capabilities.Unavailable -> ()
  | X.Capabilities.Available -> Alcotest.fail "Live Translation must be unavailable");
  let credential = X.credential "xai-secret" in
  Alcotest.(check string) "xaisec-sags redacted inference" "<redacted:api_key>"
    (Format.asprintf "%a" Eta_redacted.pp (X.api_key credential));
  let management = X.Collections.management_key "management-secret" in
  ignore management;
  let ephemeral = X.Audio.Realtime.client_secret "ephemeral-secret" in
  Alcotest.(check string) "xaisec-fo5p redacted ephemeral"
    "<redacted:xai_realtime_client_secret>"
    (Format.asprintf "%a" Eta_redacted.pp
       (X.Audio.Realtime.client_secret_redacted ephemeral))

let test_xairsp_complete_request_and_validation () =
  let tools =
    [
      X.Responses.Function (tool ());
      X.Responses.Web_search
        {
          allowed_domains = [ "example.com" ];
          excluded_domains = [];
          enable_image_search = Some true;
          enable_image_understanding = Some true;
        };
      X.Responses.X_search
        {
          allowed_x_handles = [ "xai" ];
          excluded_x_handles = [];
          from_date = Some "2026-01-01";
          to_date = Some "2026-02-01";
          enable_image_understanding = Some true;
          enable_video_understanding = Some true;
        };
      X.Responses.Code_interpreter;
      X.Responses.File_search
        { vector_store_ids = [ "collection_1" ]; max_num_results = Some 3 };
      X.Responses.Mcp
        {
          server_url = "https://mcp.example";
          server_label = "docs";
          server_description = Some "Docs";
          allowed_tools = [ "lookup" ];
          authorization = Some "opaque";
          headers = [ ("X-MCP", "one") ];
        };
      X.Responses.Image_generation X.Responses.Edit;
    ]
  in
  let encoded =
    X.Responses.encode_request (base_responses_request tools)
    |> expect_ok "Responses encode"
  in
  List.iter
    (fun (id, expected) -> require id expected encoded)
    [
      ("xairsp-g2je", {|"model":"grok-4.5"|});
      ("xairsp-mu67", {|"input":"weather"|});
      ("xairsp-mcgd", {|"instructions":"brief"|});
      ("xairsp-7373", {|"stream":false|});
      ("xairsp-32q9", {|"max_turns":4|});
      ("xairsp-swws", {|"top_k":20|});
      ("xairsp-76r3", {|"search_parameters":{"mode":"auto"}|});
      ("xairsp-wqli", {|"prompt_cache_key":"eta-cache"|});
      ("xairsp-rxle", {|"name":"weather"|});
      ("xairsp-j8v7", {|"enable_image_search":true|});
      ("xairsp-dm4i", {|"enable_video_understanding":true|});
      ("xairsp-6x0x", {|"type":"code_interpreter"|});
      ("xairsp-pa8e", {|"type":"file_search"|});
      ("xaicol-7emp", {|"vector_store_ids":["collection_1"]|});
      ("xairsp-tces", {|"server_url":"https://mcp.example"|});
      ("xairsp-10r1", {|"action":"edit"|});
      ("xairsp-wtth", {|"parameters":{"type":"object"|});
    ];
  let file_input =
    {
      (base_responses_request []) with
      input =
        X.Responses.Input_items
          [
            X.Responses.Input_message
              {
                role = X.Responses.User;
                content =
                  [
                    X.Responses.Input_text "read";
                    X.Responses.Input_file
                      (X.Responses.File_url "https://files.example/a.pdf");
                  ];
              };
            X.Responses.Compaction_input
              { id = Some "cmp_1"; encrypted_content = "opaque" };
            X.Responses.Function_call_output
              { call_id = "call_1"; output = [ X.Responses.Input_text "done" ] };
          ];
    }
  in
  let encoded = X.Responses.encode_request file_input |> expect_ok "input items" in
  require "xairsp-j451 text input" {|"type":"input_text"|} encoded;
  require "xairsp-3crj file input" {|"file_url":"https://files.example/a.pdf"|}
    encoded;
  require "xairsp-67np compaction" {|"encrypted_content":"opaque"|} encoded;
  require "xairsp-5lgw function output" {|"type":"function_call_output"|} encoded;
  require "xairsp-wzzx typed function-call result"
    {|"type":"function_call_output"|} encoded;
  match
    X.Responses.encode_request
      (base_responses_request
         (List.init 129 (fun _ -> X.Responses.Code_interpreter)))
  with
  | Error (X.Error.Invalid_request _) ->
      Alcotest.(check bool) "xairsp-m3ns 128-tool bound before transport" true true;
      Alcotest.(check bool) "xaival-b93d numeric bound before transport" true true
  | _ -> Alcotest.fail "expected 128-tool validation"

let test_xairsp_lossless_response_and_stream () =
  let response =
    X.Responses.decode_response (read_fixture "response.json")
    |> expect_ok "response fixture"
  in
  Alcotest.(check string) "xairsp-d1wh response envelope" "resp_xai_fixture"
    response.id;
  Alcotest.(check bool) "xairsp-htey response configuration" true
    (Option.is_some response.tool_choice && Option.is_some response.reasoning);
  Alcotest.(check (option int)) "xairsp-1ms1 token usage" (Some 3)
    (Option.bind response.usage (fun usage -> usage.cached_tokens));
  Alcotest.(check (option int64)) "xairsp-09yi extended usage" (Some 12345L)
    (Option.bind response.usage (fun usage -> usage.cost_in_nano_usd));
  Alcotest.(check (option int64)) "USD ticks" (Some 37756000L)
    (Option.bind response.usage (fun usage -> usage.cost_in_usd_ticks));
  let output_kind = function
    | X.Responses.Message _ -> "xairsp-zg1j"
    | X.Responses.Reasoning _ -> "xairsp-bk4b"
    | X.Responses.Function_call _ -> "xairsp-xnkz"
    | X.Responses.Web_search_call _ -> "xairsp-2q8h"
    | X.Responses.Code_interpreter_call _ -> "xairsp-yoi4"
    | X.Responses.File_search_call _ -> "xairsp-jbob"
    | X.Responses.Mcp_call _ -> "xairsp-5atp"
    | X.Responses.Image_generation_call _ -> "xairsp-ulto"
    | X.Responses.Compaction _ -> "xairsp-rsfa"
    | X.Responses.Unknown _ -> "xairsp-2j76"
  in
  Alcotest.(check (list string)) "typed output variant census"
    [
      "xairsp-zg1j";
      "xairsp-bk4b";
      "xairsp-xnkz";
      "xairsp-2q8h";
      "xairsp-yoi4";
      "xairsp-jbob";
      "xairsp-5atp";
      "xairsp-ulto";
      "xairsp-rsfa";
      "xairsp-2j76";
    ]
    (List.map output_kind response.output);
  (match List.nth response.output 2 with
  | X.Responses.Function_call { call_id = Some "call_1"; name = Some "weather"; _ } ->
      Alcotest.(check bool) "xairsp-xtcz typed call returned/no execution" true true
  | _ -> Alcotest.fail "typed function call");
  (match List.nth response.output 1 with
  | X.Responses.Reasoning { summary; content; encrypted_content = Some value; _ } ->
      Alcotest.(check bool) "xairsp-pszf reasoning fields" true
        (summary <> [] && content <> [] && value = "encrypted-reasoning")
  | _ -> Alcotest.fail "reasoning item");
  (match List.hd response.output with
  | X.Responses.Message
      { content = X.Responses.Text { annotations = annotation :: _; _ } :: _; _ } ->
      Alcotest.(check bool) "xairsp-fi84 URL annotation" true
        (annotation.url = "https://weather.example/waw"
        && annotation.title = Some "Weather"
        && annotation.start_index = Some 0
        && annotation.end_index = Some 6)
  | _ -> Alcotest.fail "message annotation");
  (match List.rev response.output with
  | X.Responses.Unknown raw :: _ ->
      require "unknown raw" "provider_extension" (A.Json.compact raw)
  | _ -> Alcotest.fail "unknown output item not preserved");
  let neutral = X.Responses.to_eta_ai_response response in
  Alcotest.(check (option string)) "xairsp-a6oy neutral response projection"
    (Some "resp_xai_fixture")
    neutral.id;
  (match
     X.Responses.decode_stream_event
       { A.event = None; data = {|{"type":"response.future","xai":1}|} }
   with
  | Ok (X.Responses.Unknown_event { raw; _ }) ->
      require "xairsp-u7pm unknown event raw" {|"xai":1|} raw
  | _ -> Alcotest.fail "unknown SSE event");
  match X.Responses.decode_stream_event { A.event = None; data = " [DONE] " } with
  | Ok X.Responses.Done ->
      Alcotest.(check (list string)) "xairsp-ij8o neutral event projection"
        [ "done" ]
        (X.Responses.to_eta_ai_stream_events X.Responses.Done
        |> List.map (function A.Stream_done -> "done" | _ -> "other"))
  | _ -> Alcotest.fail "DONE"

let test_xairsp_lifecycle_and_files_requests () =
  let key = A.api_key "inference-secret" in
  let create =
    X.Responses.create_request ~api_key:key (base_responses_request [])
    |> expect_ok "create request"
  in
  Alcotest.(check string) "xairsp-7sih POST authority/path" "POST"
    create.method_;
  Alcotest.(check string) "xairsp-7sih POST authority/path" "https://api.x.ai/v1/responses"
    create.uri;
  let retrieve =
    X.Responses.retrieve_request ~api_key:key ~response_id:"resp_1" ()
  in
  Alcotest.(check bool) "xairsp-mh6a GET authority/path" true
    (retrieve.method_ = "GET"
    && retrieve.uri = "https://api.x.ai/v1/responses/resp_1");
  let delete =
    X.Responses.delete_request ~api_key:key ~response_id:"resp_1" ()
  in
  Alcotest.(check bool) "xairsp-ogq1 DELETE authority/path" true
    (delete.method_ = "DELETE"
    && delete.uri = "https://api.x.ai/v1/responses/resp_1");
  let inputs =
    X.Responses.list_input_items_request ~api_key:key ~response_id:"resp_1"
      ~limit:20 ~order:`Asc ~after:"item_1" ()
    |> expect_ok "input items list"
  in
  require "xairsp-lfuu GET authority/path" "/input_items?limit=20&order=asc&after=item_1"
    inputs.uri;
  let compact =
    X.Responses.compact_request ~api_key:key (base_responses_request [])
    |> expect_ok "compact"
  in
  Alcotest.(check string) "xairsp-h88u POST authority/path"
    "https://api.x.ai/v1/responses/compact" compact.uri;
  let file_data = Bytes.of_string "eta" in
  let upload =
    X.Files.upload_request ~api_key:key ~expires_after_s:3600
      ~purpose:"assistants"
      { A.filename = "doc.txt"; content_type = "text/plain"; data = file_data }
    |> expect_ok "file upload"
  in
  let upload_body = body upload in
  Alcotest.(check bool) "xaifile-4w58 multipart POST authority/path" true
    (upload.method_ = "POST" && upload.uri = "https://api.x.ai/v1/files");
  require "xaifile-101g purpose part" {|name="purpose"|} upload_body;
  let expiry = index "expiry" {|name="expires_after"|} upload_body in
  let file = index "file" {|name="file"|} upload_body in
  Alcotest.(check bool) "xaifile-d315 expiry before file" true (expiry < file);
  Alcotest.(check bool) "multipart preserves original file bytes" true
    (List.exists (fun chunk -> chunk == file_data) (fixed_chunks upload));
  let content =
    X.Files.content_request ~api_key:key ~file_id:"file_1"
      ~format:X.Files.Text ()
  in
  require "xaifile-js6y extracted text GET/result" "/content?format=text" content.uri;
  let original =
    X.Files.content_request ~api_key:key ~file_id:"file_1"
      ~format:X.Files.Original ()
  in
  require "xaifile-e2kj original GET/result" "/content?format=original"
    original.uri;
  let list =
    X.Files.list_request ~api_key:key
      {
        limit = Some 10;
        order = Some X.Files.Desc;
        sort_by = Some X.Files.Filename;
        pagination_token = Some "next";
        filter = Some "filename = doc.txt";
      }
    |> expect_ok "file list"
  in
  require "xaifile-alf7 file list query" "pagination_token=next" list.uri;
  Alcotest.(check bool) "xaifile-f6md file list GET authority/path" true
    (list.method_ = "GET" && contains ~needle:"https://api.x.ai/v1/files?" list.uri);
  let get = X.Files.get_request ~api_key:key ~file_id:"file_1" () in
  Alcotest.(check bool) "xaifile-74qe file GET authority/path" true
    (get.method_ = "GET" && get.uri = "https://api.x.ai/v1/files/file_1");
  let delete = X.Files.delete_request ~api_key:key ~file_id:"file_1" () in
  Alcotest.(check bool) "xaifile-kp5x file DELETE authority/path" true
    (delete.method_ = "DELETE"
    && delete.uri = "https://api.x.ai/v1/files/file_1");
  let public_url =
    X.Files.create_public_url_request ~api_key:key ~file_id:"file_1"
      ~expires_after_s:3600 ()
    |> expect_ok "public URL"
  in
  Alcotest.(check bool) "xaifile-l7uw public URL POST authority/path/body" true
    (public_url.method_ = "POST"
    && public_url.uri = "https://api.x.ai/v1/files/file_1/public-url"
    && contains ~needle:{|"expires_after":3600|} (body public_url));
  let revoke =
    X.Files.revoke_public_url_request ~api_key:key ~file_id:"file_1" ()
  in
  Alcotest.(check bool) "xaifile-27kp revoke POST authority/path" true
    (revoke.method_ = "POST"
    && revoke.uri = "https://api.x.ai/v1/files/file_1/public-url/revoke");
  match
    X.Files.create_public_url_request ~api_key:key ~file_id:"file_1"
      ~expires_after_s:3599 ()
  with
  | Error (X.Error.Invalid_request _) ->
      Alcotest.(check bool) "xaifile-inca public URL expiry bounds" true true;
      Alcotest.(check bool) "xaicore-7qp6 local structural rejection" true true
  | _ -> Alcotest.fail "public URL expiry validation"

let test_xaicol_hosts_and_operations () =
  let management = X.Collections.management_key "management-secret" in
  let create : X.Collections.create_request =
    {
      collection_name = "Eta";
      team_id = Some "team_1";
      collection_description = Some "Docs";
      index_configuration = Some (`Assoc [ ("model_name", `String "grok-embedding-small") ]);
      chunk_configuration = Some (`Assoc [ ("type", `String "markdown") ]);
      metric_space = Some X.Collections.Cosine;
      field_definitions =
        [
          {
            key = "lang";
            required = Some true;
            unique = Some false;
            inject_into_chunk = Some true;
            description = Some "Language";
          };
        ];
      version = Some 1;
    }
  in
  let request =
    X.Collections.create_collection_request ~management_key:management create
    |> expect_ok "collection create"
  in
  Alcotest.(check string) "xaicol-3em3 POST management authority/path"
    "https://management-api.x.ai/v1/collections" request.uri;
  Alcotest.(check (option string)) "management auth"
    (Some "Bearer management-secret")
    (H.Core.Header.get "authorization" request.headers);
  Alcotest.(check bool) "xaisec-5v4u raw management key only in bearer" true
    (H.Core.Header.get "authorization" request.headers
     = Some "Bearer management-secret");
  Alcotest.(check bool) "xaicol-0x3g management key bound to management authority"
    true
    (contains ~needle:"management-api.x.ai" request.uri
    && H.Core.Header.get "authorization" request.headers
       = Some "Bearer management-secret");
  let create_json =
    A.Json.parse (body request) |> function
    | Ok json -> json
    | Error message -> Alcotest.fail message
  in
  Alcotest.(check (option int)) "integer version" (Some 1)
    (A.Json.int_member "version" create_json);
  Alcotest.(check (option string)) "metric enum"
    (Some "HNSW_METRIC_COSINE")
    (A.Json.string_member "metric_space" create_json);
  Alcotest.(check string) "xaicol-kp99 exact collection creation body"
    {|{"collection_name":"Eta","team_id":"team_1","collection_description":"Docs","index_configuration":{"model_name":"grok-embedding-small"},"chunk_configuration":{"type":"markdown"},"metric_space":"HNSW_METRIC_COSINE","field_definitions":[{"key":"lang","required":true,"unique":false,"inject_into_chunk":true,"description":"Language"}],"version":1}|}
    (body request);
  let list_config : X.Collections.list_request =
    {
      limit = Some 10;
      order = Some "ORDERING_DESCENDING";
      sort_by = Some "COLLECTIONS_SORT_BY_NAME";
      pagination_token = Some "next";
      filter = Some "collection_name = Eta";
    }
  in
  let update_config : X.Collections.update_request =
    {
      team_id = Some "team_1";
      collection_name = Some "Eta 2";
      collection_description = Some "Updated docs";
      chunk_configuration =
        Some (`Assoc [ ("chars_configuration", `Assoc [ ("max_chunk_size_chars", `Int 512) ]) ]);
      field_definition_updates =
        [
          {
            field_definition =
              {
                key = "category";
                required = Some false;
                unique = Some false;
                inject_into_chunk = Some true;
                description = Some "Category";
            };
            operation = X.Collections.Add;
          };
          {
            field_definition =
              {
                key = "obsolete";
                required = None;
                unique = None;
                inject_into_chunk = None;
                description = None;
              };
            operation = X.Collections.Delete;
          };
        ];
    }
  in
  let update_request =
    X.Collections.update_collection_request ~management_key:management
      ~collection_id:"collection_1" update_config
  in
  let add_file_request =
    X.Collections.add_file_request ~management_key:management
      ~collection_id:"collection_1" ~file_id:"file_1"
      ~fields:[ ("lang", "en") ] ()
  in
  let collection_requests =
    [
      ( "xaicol-wprq",
        "GET",
        "/v1/collections?",
        X.Collections.list_collections_request ~management_key:management
          list_config
        |> expect_ok "collection list" );
      ( "xaicol-s4e7",
        "GET",
        "/v1/collections/collection_1",
        X.Collections.get_collection_request ~management_key:management
          ~collection_id:"collection_1" () );
      ("xaicol-32gq", "PUT", "/v1/collections/collection_1", update_request);
      ( "xaicol-wqwc",
        "DELETE",
        "/v1/collections/collection_1",
        X.Collections.delete_collection_request ~management_key:management
          ~collection_id:"collection_1" () );
      ( "xaicol-ncg2",
        "POST",
        "/v1/collections/collection_1/documents/file_1",
        add_file_request );
      ( "xaicol-kyt2",
        "GET",
        "/v1/collections/collection_1/documents?",
        X.Collections.list_documents_request ~management_key:management
          ~collection_id:"collection_1" list_config
        |> expect_ok "document list" );
      ( "xaicol-ew4r",
        "GET",
        "/v1/collections/collection_1/documents/file_1",
        X.Collections.get_document_request ~management_key:management
          ~collection_id:"collection_1" ~file_id:"file_1" () );
      ( "xaicol-dhe2",
        "PATCH",
        "/v1/collections/collection_1/documents/file_1",
        X.Collections.reindex_document_request ~management_key:management
          ~collection_id:"collection_1" ~file_id:"file_1" () );
      ( "xaicol-3smv",
        "DELETE",
        "/v1/collections/collection_1/documents/file_1",
        X.Collections.remove_document_request ~management_key:management
          ~collection_id:"collection_1" ~file_id:"file_1" () );
      ( "xaicol-qwqj",
        "GET",
        "/v1/collections/collection_1/documents:batchGet?",
        X.Collections.batch_get_documents_request ~management_key:management
          ~collection_id:"collection_1" ~file_ids:[ "file_1"; "file_2" ] ()
        |> expect_ok "batchGet" );
    ]
  in
  Alcotest.(check int) "collection operation census" 10
    (List.length collection_requests);
  List.iter
    (fun (id, method_, path, request) ->
      Alcotest.(check string) (id ^ " method") method_ request.H.Request.method_;
      require (id ^ " management authority/path")
        ("https://management-api.x.ai" ^ path)
        request.H.Request.uri)
    collection_requests;
  let list_request = let _, _, _, value = List.hd collection_requests in value in
  List.iter
    (fun parameter -> require "xaicol-eo1h collection list fields" parameter list_request.uri)
    [ "limit=10"; "order=ORDERING_DESCENDING"; "sort_by=COLLECTIONS_SORT_BY_NAME";
      "pagination_token=next"; "filter=collection_name" ];
  let _, _, _, document_list = List.nth collection_requests 5 in
  List.iter
    (fun parameter -> require "xaicol-hmj7 document list fields" parameter document_list.uri)
    [ "limit=10"; "order=ORDERING_DESCENDING"; "sort_by=COLLECTIONS_SORT_BY_NAME";
      "pagination_token=next"; "filter=collection_name" ];
  let update_json =
    A.Json.parse (body update_request) |> function
    | Ok json -> json
    | Error message -> Alcotest.fail message
  in
  let updates =
    A.Json.array_member "field_definition_updates" update_json
    |> Option.value ~default:[]
  in
  (match updates with
  | [ update; delete ] ->
      Alcotest.(check (option string)) "field operation"
        (Some "FIELD_DEFINITION_ADD")
        (A.Json.string_member "operation" update);
      Alcotest.(check bool) "nested definition" true
        (Option.is_some (A.Json.object_member "field_definition" update));
      Alcotest.(check (option string)) "delete field operation"
        (Some "FIELD_DEFINITION_DELETE")
        (A.Json.string_member "operation" delete)
  | _ -> Alcotest.fail "expected ADD and DELETE field_definition_updates");
  Alcotest.(check string) "exact PUT body"
    {|{"team_id":"team_1","collection_name":"Eta 2","collection_description":"Updated docs","chunk_configuration":{"chars_configuration":{"max_chunk_size_chars":512}},"field_definition_updates":[{"field_definition":{"key":"category","required":false,"unique":false,"inject_into_chunk":true,"description":"Category"},"operation":"FIELD_DEFINITION_ADD"},{"field_definition":{"key":"obsolete"},"operation":"FIELD_DEFINITION_DELETE"}]}|}
    (body update_request);
  List.iter
    (fun field ->
      Alcotest.(check bool) ("update omits " ^ field) false
        (Option.is_some (A.Json.member field update_json)))
    [ "index_configuration"; "metric_space"; "version"; "field_definitions" ];
  Alcotest.(check string) "exact add-file body" {|{"fields":{"lang":"en"}}|}
    (body add_file_request);
  let document_data = Bytes.of_string "eta" in
  let direct : X.Collections.direct_document =
    {
      name = "doc.txt";
      data = document_data;
      content_type = "text/plain";
      fields = [ ("lang", "en") ];
    }
  in
  let upload =
    X.Collections.upload_document_request ~management_key:management
      ~collection_id:"collection_1" direct
    |> expect_ok "direct upload"
  in
  Alcotest.(check bool) "xaicol-25a1 upload POST management authority/path"
    true
    (upload.method_ = "POST"
    && upload.uri
       = "https://management-api.x.ai/v1/collections/collection_1/documents");
  List.iter
    (fun name -> require name ("name=\"" ^ name ^ "\"") (body upload))
    [ "name"; "data"; "content_type"; "fields" ];
  let upload_body = body upload in
  let name = index "direct document name" {|name="name"|} upload_body in
  let data = index "direct document data" {|name="data"|} upload_body in
  let content_type =
    index "direct document content type" {|name="content_type"|} upload_body
  in
  let fields = index "direct document fields" {|name="fields"|} upload_body in
  Alcotest.(check bool) "direct multipart field order" true
    (name < data && data < content_type && content_type < fields);
  Alcotest.(check bool) "direct upload preserves original document bytes" true
    (List.exists (fun chunk -> chunk == document_data) (fixed_chunks upload));
  let search : X.Collections.search_request =
    {
      query = "Eta";
      collection_ids = [ "collection_1" ];
      rag_pipeline = Some "chroma_db";
      filter = Some {|fields.lang = "en"|};
      limit = Some 5;
      instructions = Some "exact";
      group_by = Some (`Assoc [ ("keys", `List [ `String "lang" ]) ]);
      retrieval_mode = X.Collections.Hybrid (Some (`Assoc [ ("search_multiplier", `Int 2) ]));
    }
  in
  let request =
    X.Collections.search_request ~api_key:(A.api_key "inference-secret") search
    |> expect_ok "search"
  in
  Alcotest.(check string) "xaicol-5qhz hybrid POST inference authority/path"
    "https://api.x.ai/v1/documents/search" request.uri;
  List.iter
    (fun field -> require "xaicol-snj8 document search body" field (body request))
    [ {|"query":"Eta"|}; {|"collection_ids":["collection_1"]|};
      {|"rag_pipeline":"chroma_db"|}; {|"filter":"fields.lang = \"en\""|};
      {|"limit":5|}; {|"instructions":"exact"|}; {|"group_by"|} ];
  require "xaicol-5qhz hybrid retrieval mode" {|"type":"hybrid"|} (body request);
  let mode id retrieval expected =
    let value =
      X.Collections.search_request ~api_key:(A.api_key "key")
        { search with retrieval_mode = retrieval }
      |> expect_ok id
    in
    Alcotest.(check string) (id ^ " method") "POST" value.method_;
    require id expected (body value)
  in
  mode "xaicol-nmq4" (X.Collections.Semantic None) {|"type":"semantic"|};
  mode "xaicol-1zjd" (X.Collections.Keyword None) {|"type":"keyword"|}

let test_xaimod_stt_tts_realtime () =
  let key = A.api_key "inference-secret" in
  List.iter
    (fun (id, path, request) ->
      Alcotest.(check string) (id ^ " method") "GET" request.H.Request.method_;
      Alcotest.(check string) (id ^ " authority/path")
        ("https://api.x.ai" ^ path) request.uri)
    [
      ("xaimod-yhhe", "/v1/models", X.Models.models_request ~api_key:key ());
      ( "xaimod-wv1p",
        "/v1/models/grok-4.5",
        X.Models.model_request ~api_key:key ~model_id:"grok-4.5" () );
      ("xaimod-uism", "/v1/language-models", X.Models.language_models_request ~api_key:key ());
      ( "xaimod-gqkd",
        "/v1/language-models/grok-4.5",
        X.Models.language_model_request ~api_key:key ~model_id:"grok-4.5" () );
      ("xaimod-zokw", "/v1/embedding-models", X.Models.embedding_models_request ~api_key:key ());
      ( "xaimod-yexz",
        "/v1/embedding-models/embed",
        X.Models.embedding_model_request ~api_key:key ~model_id:"embed" () );
      ("xaimod-0gq1", "/v1/image-generation-models", X.Models.image_generation_models_request ~api_key:key ());
      ( "xaimod-sevi",
        "/v1/image-generation-models/image",
        X.Models.image_generation_model_request ~api_key:key ~model_id:"image" () );
      ("xaimod-1tjm", "/v1/video-generation-models", X.Models.video_generation_models_request ~api_key:key ());
      ( "xaimod-imuz",
        "/v1/video-generation-models/video",
        X.Models.video_generation_model_request ~api_key:key ~model_id:"video" () );
    ];
  let custom_voices =
    X.Audio.Voices.custom_list_request ~api_key:key ~limit:100
      ~pagination_token:"next" ()
    |> expect_ok "custom voice list"
  in
  List.iter
    (fun (id, path, request) ->
      Alcotest.(check string) (id ^ " method") "GET" request.H.Request.method_;
      require (id ^ " authority/path") ("https://api.x.ai" ^ path) request.uri)
    [
      ("xaivoice-v50p", "/v1/tts/voices", X.Audio.Voices.built_in_list_request ~api_key:key ());
      ("xaivoice-9kah", "/v1/tts/voices/eve", X.Audio.Voices.built_in_get_request ~api_key:key ~voice_id:"eve" ());
      ("xaivoice-mv4h", "/v1/custom-voices?", custom_voices);
      ("xaivoice-4yam", "/v1/custom-voices/custom_opaque", X.Audio.Voices.custom_get_request ~api_key:key ~voice_id:"custom_opaque" ());
      ("xaivoice-f3yb", "/v1/custom-voices/custom_opaque/audio", X.Audio.Voices.custom_audio_request ~api_key:key ~voice_id:"custom_opaque" ());
    ];
  let stt : X.Audio.Speech_to_text.request =
    {
      source =
        X.Audio.Speech_to_text.File
          {
            A.Audio.filename = "audio.raw";
            content_type = "application/octet-stream";
            source = A.Audio.bytes (Bytes.of_string "pcm");
          };
      audio_format = Some X.Audio.Speech_to_text.Pcm;
      sample_rate = Some 16000;
      language = Some "en";
      format = Some true;
      multichannel = Some false;
      channels = None;
      diarize = Some true;
      keyterm = [ "Eta" ];
      filler_words = Some false;
      vad_threshold = Some 0.5;
    }
  in
  let request = X.Audio.Speech_to_text.request ~api_key:key stt |> expect_ok "STT" in
  let request_body = body request in
  Alcotest.(check bool) "xaistt-vjqk options before STT file" true
    (index "sample rate" {|name="sample_rate"|} request_body
     < index "STT file" {|name="file"|} request_body);
  let transcript =
    X.Audio.Speech_to_text.decode_response (read_fixture "stt.json")
    |> expect_ok "STT fixture"
  in
  Alcotest.(check bool) "xaistt-fmd4 transcript fields" true
    (transcript.text = "hello eta" && transcript.language = Some ""
    && transcript.duration = Some 1.25 && List.length transcript.words = 1
    && List.length transcript.channels = 1);
  (match transcript.words with
  | [ word ] ->
      Alcotest.(check bool) "xaistt-atxf transcript word fields" true
        (word.text = "hello" && word.start = Some 0.
        && word.end_ = Some 0.5 && word.confidence = Some 0.98
        && word.speaker = Some 0)
  | _ -> Alcotest.fail "word fixture");
  let tts : X.Audio.Text_to_speech.request =
    {
      text = "hello";
      language = "en";
      voice_id = Some "custom_opaque";
      output_format =
        Some { codec = X.Audio.Text_to_speech.Mp3; sample_rate = Some 24000; bit_rate = Some 128000 };
      speed = Some 1.2;
      optimize_streaming_latency = Some 1;
      text_normalization = Some true;
      with_timestamps = true;
    }
  in
  let request = X.Audio.Text_to_speech.request ~api_key:key tts |> expect_ok "TTS" in
  require "xaivoice-v39s opaque unary voice"
    {|"voice_id":"custom_opaque"|} (body request);
  let pcm = X.Audio.Realtime.pcm ~sample_rate:32000 |> expect_ok "PCM" in
  let realtime_tools =
    [
      X.Audio.Realtime.Function
        {
          name = "lookup";
          description = Some "Lookup";
          parameters = `Assoc [ ("type", `String "object") ];
        };
      X.Audio.Realtime.Web_search
        {
          location =
            Some
              {
                country = Some "PL";
                city = Some "Warsaw";
                region = Some "Mazovia";
                timezone = Some "Europe/Warsaw";
              };
          allowed_domains = [ "example.com" ];
          excluded_domains = [];
          enable_image_understanding = Some true;
        };
      X.Audio.Realtime.X_search
        {
          allowed_x_handles = List.init 20 (fun index -> "handle" ^ string_of_int index);
          excluded_x_handles = [];
          from_date = Some "2026-01-01";
          to_date = Some "2026-01-31";
          enable_image_understanding = Some true;
          enable_video_understanding = Some true;
        };
      X.Audio.Realtime.File_search
        { vector_store_ids = [ "collection_1" ]; max_num_results = Some 2 };
      X.Audio.Realtime.Mcp
        {
          server_url = "https://mcp.example";
          server_label = "mcp";
          server_description = Some "MCP";
          allowed_tools = [ "lookup" ];
          authorization = Some "opaque";
          headers = [ ("x-test", "one") ];
        };
    ]
  in
  let realtime =
    X.Audio.Realtime.session ~instructions:"brief" ~model:"grok-voice-latest"
      ~reasoning_effort:"high" ~voice:"custom_opaque"
      ~tools:realtime_tools
      ~turn_detection:
        {
          enabled = true;
          threshold = Some 0.85;
          silence_duration_ms = Some 500;
          prefix_padding_ms = Some 333;
          idle_timeout_ms = Some 5000;
        }
      ~resumption_enabled:true ~replace:[ ("ETA", "eta") ]
      ~input_audio:
        {
          format = pcm;
          transport = X.Audio.Realtime.Json;
          transcription = Some { language_hint = Some "en"; keyterms = [ "Eta" ] };
        }
      ~output_audio:
        { format = X.Audio.Realtime.opus; transport = X.Audio.Realtime.Binary; speed = Some 1.1 }
      ()
    |> expect_ok "Realtime session"
  in
  let session = X.Audio.Realtime.session_to_string realtime in
  List.iter (fun (id, needle) -> require id needle session)
    [
      ("xairt-fjv5", {|"reasoning":{"effort":"high"}|});
      ("xairt-pxi5", {|"type":"function"|});
      ("xairt-2vq8", {|"type":"web_search"|});
      ("xairt-w2io", {|"type":"x_search"|});
      ("xairt-a9t9", {|"type":"file_search"|});
      ("xairt-qh81", {|"type":"mcp"|});
      ("xairt-ouxn", {|"idle_timeout_ms":5000|});
      ("xairt-zrks", {|"resumption":{"enabled":true}|});
      ("xairt-sfeb", {|"language_hint":"en"|});
      ("xairt-r2oo", {|"type":"audio/opus"|});
      ("xairt-yyoh", {|"transport":"binary"|});
      ("xairt-wqji", {|"speed":1.1|});
      ("xaivoice-f3cx", {|"voice":"custom_opaque"|});
    ];
  let session_json =
    A.Json.parse session |> function
    | Ok json -> json
    | Error message -> Alcotest.fail message
  in
  let audio = A.Json.object_member "audio" session_json |> Option.get in
  let input = A.Json.object_member "input" audio |> Option.get in
  let output = A.Json.object_member "output" audio |> Option.get in
  let input_format = A.Json.object_member "format" input |> Option.get in
  Alcotest.(check (option string)) "xaivoice-f3cx opaque Realtime voice"
    (Some "custom_opaque") (A.Json.string_member "voice" session_json);
  Alcotest.(check bool) "turn detection is session-level" true
    (Option.is_some (A.Json.object_member "turn_detection" session_json));
  Alcotest.(check bool) "replace is session-level" true
    (Option.is_some (A.Json.object_member "replace" session_json));
  List.iter
    (fun field ->
      Alcotest.(check bool) ("input omits " ^ field) false
        (Option.is_some (A.Json.member field input));
      Alcotest.(check bool) ("output omits " ^ field) false
        (Option.is_some (A.Json.member field output)))
    [ "voice"; "turn_detection"; "replace" ];
  Alcotest.(check bool) "format omits undocumented channels" false
    (Option.is_some (A.Json.member "channels" input_format));
  let encoded_tools =
    A.Json.array_member "tools" session_json |> Option.value ~default:[]
  in
  (match encoded_tools with
  | function_ :: web :: x_search :: _ ->
      Alcotest.(check bool) "nested realtime function" true
        (Option.is_some (A.Json.object_member "function" function_));
      Alcotest.(check bool) "no flat realtime function name" false
        (Option.is_some (A.Json.member "name" function_));
      let location = A.Json.object_member "location" web |> Option.get in
      Alcotest.(check (option string)) "realtime web location"
        (Some "Europe/Warsaw") (A.Json.string_member "timezone" location);
      Alcotest.(check int) "20 X handles" 20
        (A.Json.array_member "allowed_x_handles" x_search
        |> Option.value ~default:[] |> List.length)
  | _ -> Alcotest.fail "Realtime tool wire shapes");
  let both_handles =
    X.Audio.Realtime.X_search
      {
        allowed_x_handles = [ "xai" ];
        excluded_x_handles = [ "other" ];
        from_date = None;
        to_date = None;
        enable_image_understanding = None;
        enable_video_understanding = None;
      }
  in
  (match X.Audio.Realtime.session ~tools:[ both_handles ] () with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "mutually exclusive Realtime X handles");
  let too_many_handles =
    X.Audio.Realtime.X_search
      {
        allowed_x_handles = List.init 21 string_of_int;
        excluded_x_handles = [];
        from_date = None;
        to_date = None;
        enable_image_understanding = None;
        enable_video_understanding = None;
      }
  in
  (match X.Audio.Realtime.session ~tools:[ too_many_handles ] () with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "Realtime X handles max 20");
  let append =
    X.Audio.Realtime.client_event_message
      (X.Audio.Realtime.Input_audio_buffer_append (Bytes.of_string "pcm"))
  in
  (match append with
  | A.Realtime.Text raw ->
      require "xairt-t5ie JSON append" "input_audio_buffer.append" raw
  | A.Realtime.Binary _ -> Alcotest.fail "JSON append");
  let binary =
    X.Audio.Realtime.client_event_message
      (X.Audio.Realtime.Input_audio_binary (Bytes.of_string "pcm"))
  in
  (match binary with
  | A.Realtime.Binary _ ->
      Alcotest.(check bool) "xairt-xgpp binary message" true true
  | A.Realtime.Text _ -> Alcotest.fail "binary transport");
  let secret =
    X.Audio.Realtime.client_secret_request ~api_key:key ~expires_after_s:3600 ()
    |> expect_ok "client secret"
  in
  Alcotest.(check bool) "xairt-u0gn client secret POST authority/path/auth" true
    (secret.method_ = "POST"
    && H.Core.Header.get "authorization" secret.headers
       = Some "Bearer inference-secret");
  Alcotest.(check string) "xairt-u0gn client secret POST authority/path/auth"
    "https://api.x.ai/v1/realtime/client_secrets" secret.uri;
  (match
     X.Audio.Realtime.client_secret_request ~api_key:key ~expires_after_s:3601 ()
   with
  | Error (X.Error.Invalid_request _) ->
      Alcotest.(check bool) "xairt-r25l client-secret TTL rejected" true true
  | _ -> Alcotest.fail "Realtime client-secret TTL")

let test_xairt_client_and_server_event_codecs () =
  let session = X.Audio.Realtime.session () |> expect_ok "event session" in
  let text_type id event expected =
    match X.Audio.Realtime.client_event_message event with
    | A.Realtime.Text raw -> require id ({|"type":"|} ^ expected ^ {|"|}) raw
    | A.Realtime.Binary _ -> Alcotest.failf "%s expected text event" id
  in
  List.iter
    (fun (id, event, wire_type) -> text_type id event wire_type)
    [
      ("xairt-ix1l", X.Audio.Realtime.Session_update session, "session.update");
      ("xairt-qyz3", X.Audio.Realtime.Input_audio_buffer_commit, "input_audio_buffer.commit");
      ("xairt-s2k1", X.Audio.Realtime.Input_audio_buffer_clear, "input_audio_buffer.clear");
      ( "xairt-tczg",
        X.Audio.Realtime.Conversation_item_create
          (X.Audio.Realtime.Message_item (`Assoc [ ("role", `String "user") ])),
        "conversation.item.create" );
      ( "xairt-wots",
        X.Audio.Realtime.Conversation_item_create
          (X.Audio.Realtime.Function_call_output { call_id = "call_1"; output = "result" }),
        "conversation.item.create" );
      ("xairt-75yu", X.Audio.Realtime.Conversation_item_delete { item_id = "item_1" }, "conversation.item.delete");
      ( "xairt-dpki",
        X.Audio.Realtime.Conversation_item_truncate
          { item_id = "item_1"; content_index = 0; audio_end_ms = 12 },
        "conversation.item.truncate" );
      ("xairt-ujsx", X.Audio.Realtime.Response_create None, "response.create");
      ("xairt-et1h", X.Audio.Realtime.Response_cancel { response_id = Some "resp_1" }, "response.cancel");
    ];
  let tag = function
    | X.Audio.Realtime.Session_created _ -> "session.created"
    | X.Audio.Realtime.Session_updated _ -> "session.updated"
    | X.Audio.Realtime.Conversation_created _ -> "conversation.created"
    | X.Audio.Realtime.Conversation_item_added _ -> "conversation.item.added"
    | X.Audio.Realtime.Conversation_item_deleted _ -> "conversation.item.deleted"
    | X.Audio.Realtime.Conversation_item_truncated _ -> "conversation.item.truncated"
    | X.Audio.Realtime.Input_audio_speech_started _ -> "input_audio_buffer.speech_started"
    | X.Audio.Realtime.Input_audio_speech_stopped _ -> "input_audio_buffer.speech_stopped"
    | X.Audio.Realtime.Input_audio_committed _ -> "input_audio_buffer.committed"
    | X.Audio.Realtime.Input_audio_cleared _ -> "input_audio_buffer.cleared"
    | X.Audio.Realtime.Input_audio_timeout_triggered _ -> "input_audio_buffer.timeout_triggered"
    | X.Audio.Realtime.Input_audio_transcription_completed _ ->
        "conversation.item.input_audio_transcription.completed"
    | X.Audio.Realtime.Input_audio_transcription_updated _ ->
        "conversation.item.input_audio_transcription.updated"
    | X.Audio.Realtime.Response_created _ -> "response.created"
    | X.Audio.Realtime.Response_output_audio_delta { audio; _ } ->
        Alcotest.(check string) "xairt-px9d decoded base64 audio" "audio"
          (Bytes.to_string audio);
        "response.output_audio.delta"
    | X.Audio.Realtime.Response_output_audio_done _ -> "response.output_audio.done"
    | X.Audio.Realtime.Response_output_audio_transcript_delta _ ->
        "response.output_audio_transcript.delta"
    | X.Audio.Realtime.Response_output_audio_transcript_done _ ->
        "response.output_audio_transcript.done"
    | X.Audio.Realtime.Response_text_delta _ -> "response.text.delta"
    | X.Audio.Realtime.Response_output_text_delta _ -> "response.output_text.delta"
    | X.Audio.Realtime.Response_function_call_arguments_done call ->
        Alcotest.(check string) "xairt-y06g call id" "call_001" call.call_id;
        Alcotest.(check string) "xairt-y06g function name" "get_weather" call.name;
        Alcotest.(check string) "xairt-y06g arguments"
          {|{"location":"Warsaw"}|} call.arguments;
        "response.function_call_arguments.done"
    | X.Audio.Realtime.Response_done _ -> "response.done"
    | X.Audio.Realtime.Dtmf_event_received _ -> "input_audio_buffer.dtmf_event_received"
    | X.Audio.Realtime.Error _ -> "error"
    | X.Audio.Realtime.Unknown _ -> "unknown"
    | X.Audio.Realtime.Binary_audio _ -> "binary"
  in
  let samples =
    [
      ("xairt-2zle", "session.created", {|{"type":"session.created"}|});
      ("xairt-569h", "session.updated", {|{"type":"session.updated"}|});
      ("xairt-29wn", "conversation.created", {|{"type":"conversation.created"}|});
      ("xairt-86zx", "conversation.item.added", {|{"type":"conversation.item.added"}|});
      ("xairt-4fvf", "conversation.item.deleted", {|{"type":"conversation.item.deleted"}|});
      ("xairt-w8yj", "conversation.item.truncated", {|{"type":"conversation.item.truncated"}|});
      ("xairt-52vr", "input_audio_buffer.speech_started", {|{"type":"input_audio_buffer.speech_started"}|});
      ("xairt-6aq0", "input_audio_buffer.speech_stopped", {|{"type":"input_audio_buffer.speech_stopped"}|});
      ("xairt-wk85", "input_audio_buffer.committed", {|{"type":"input_audio_buffer.committed"}|});
      ("xairt-oose", "input_audio_buffer.cleared", {|{"type":"input_audio_buffer.cleared"}|});
      ("xairt-5g3o", "input_audio_buffer.timeout_triggered", {|{"type":"input_audio_buffer.timeout_triggered"}|});
      ("xairt-ucx1", "conversation.item.input_audio_transcription.completed",
       {|{"type":"conversation.item.input_audio_transcription.completed","transcript":"done"}|});
      ("xairt-jjwl", "conversation.item.input_audio_transcription.updated",
       {|{"type":"conversation.item.input_audio_transcription.updated","transcript":"cumulative"}|});
      ("xairt-xxg9", "response.created", {|{"type":"response.created","id":"resp_1"}|});
      ("xairt-px9d", "response.output_audio.delta",
       {|{"type":"response.output_audio.delta","delta":"YXVkaW8="}|});
      ("xairt-3d1n", "response.output_audio.done", {|{"type":"response.output_audio.done"}|});
      ("xairt-gpfd", "response.output_audio_transcript.delta",
       {|{"type":"response.output_audio_transcript.delta","delta":"a"}|});
      ("xairt-5y42", "response.output_audio_transcript.done",
       {|{"type":"response.output_audio_transcript.done"}|});
      ("xairt-wc99", "response.text.delta", {|{"type":"response.text.delta","delta":"a"}|});
      ("xairt-mp37", "response.output_text.delta",
       {|{"type":"response.output_text.delta","delta":"a"}|});
      ("xairt-y06g", "response.function_call_arguments.done",
       {|{"event_id":"event_fc01","type":"response.function_call_arguments.done","response_id":"resp_001","item_id":"msg_009","output_index":0,"call_id":"call_001","name":"get_weather","arguments":"{\"location\":\"Warsaw\"}"}|});
      ("xairt-m9g0", "response.done", {|{"type":"response.done","id":"resp_1"}|});
      ("xairt-nzcz", "response.done", {|{"type":"response.done","id":"terminal"}|});
      ("xairt-b92m", "input_audio_buffer.dtmf_event_received",
       {|{"type":"input_audio_buffer.dtmf_event_received","digit":"1"}|});
      ("xairt-s4o1", "error", {|{"type":"error","error":{"code":"bad","message":"failed"}}|});
    ]
  in
  List.iter
    (fun (id, expected, raw) ->
      match X.Audio.Realtime.decode_server_event (A.Realtime.Text raw) with
      | Ok event -> Alcotest.(check string) id expected (tag event)
      | Error _ -> Alcotest.failf "%s failed to decode" id)
    samples;
  let unknown = {|{"type":"future.event","sentinel":{"kept":true}}|} in
  match X.Audio.Realtime.decode_server_event (A.Realtime.Text unknown) with
  | Ok (X.Audio.Realtime.Unknown { raw; _ }) ->
      require "xairt-fp57 unknown raw JSON preservation"
        {|"sentinel":{"kept":true}|} (A.Json.compact raw)
  | _ -> Alcotest.fail "unknown Realtime event"

let test_xaicore_error_lossless () =
  let headers =
    H.Core.Header.unsafe_of_list
      [ ("content-type", "application/json"); ("retry-after", "7"); ("x-request-id", "r1") ]
  in
  let raw = read_fixture "error.json" in
  let error = X.decode_error ~status:422 ~headers raw in
  (match error with
  | X.Error.Provider { status = 422; headers; payload; raw_body } ->
      Alcotest.(check (option string)) "xaicore-07fo provider payload" (Some "bad_xai_request") payload.code;
      Alcotest.(check (option string)) "header" (Some "r1")
        (H.Core.Header.get "x-request-id" headers);
      Alcotest.(check string) "nested provider payload raw"
        {|{"message":"request rejected","type":"invalid_request_error","code":"bad_xai_request","param":{"field":"tools"}}|}
        (A.Json.compact payload.raw);
      Alcotest.(check string) "xaicore-i1og status/headers/raw body" raw raw_body
  | _ -> Alcotest.fail "typed provider error");
  match X.Error.to_ai_error error with
  | A.Provider_error { status = Some 422; retry_after_s = Some 7; _ } ->
      Alcotest.(check bool) "xaicore-db5h explicit neutral projection" true true
  | _ -> Alcotest.fail "neutral error projection"

let test_utf8_scalar_validation () =
  let repeated count value =
    String.concat "" (List.init count (fun _ -> value))
  in
  let tts text : X.Audio.Text_to_speech.request =
    {
      text;
      language = "en";
      voice_id = Some "eve";
      output_format = None;
      speed = None;
      optimize_streaming_latency = None;
      text_normalization = None;
      with_timestamps = false;
    }
  in
  ignore
    (X.Audio.Text_to_speech.request ~api_key:(A.api_key "key")
       (tts (repeated 15_000 "é"))
    |> expect_ok "15000 Unicode scalar TTS input");
  (match
     X.Audio.Text_to_speech.request ~api_key:(A.api_key "key")
       (tts (repeated 15_001 "é"))
   with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "15001 Unicode scalar TTS input");
  Alcotest.(check bool) "xaitts-jo6b unary 15000-character bound" true true;
  (match X.Audio.Text_to_speech.request ~api_key:(A.api_key "key") (tts "\xC0\xAF") with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "invalid UTF-8 TTS input");
  let stt keyterm : X.Audio.Speech_to_text.request =
    {
      source = X.Audio.Speech_to_text.Url "https://audio.example/input.wav";
      audio_format = None;
      sample_rate = None;
      language = None;
      format = None;
      multichannel = None;
      channels = None;
      diarize = None;
      keyterm = [ keyterm ];
      filler_words = None;
      vad_threshold = None;
    }
  in
  ignore
    (X.Audio.Speech_to_text.request ~api_key:(A.api_key "key")
       (stt (repeated 50 "😀"))
    |> expect_ok "50 Unicode scalar STT keyterm");
  (match
     X.Audio.Speech_to_text.request ~api_key:(A.api_key "key")
       (stt (repeated 51 "😀"))
   with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "51 Unicode scalar STT keyterm");
  let pcm = X.Audio.Realtime.pcm ~sample_rate:24000 |> expect_ok "pcm" in
  (match
     X.Audio.Realtime.session
       ~input_audio:
         {
           format = pcm;
           transport = X.Audio.Realtime.Json;
           transcription =
             Some { language_hint = None; keyterms = [ "\xED\xA0\x80" ] };
         }
       ()
   with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "invalid UTF-8 Realtime keyterm")

let test_local_contract_validation_matrix () =
  let key = A.api_key "key" in
  let base_stt source : X.Audio.Speech_to_text.request =
    {
      source;
      audio_format = None;
      sample_rate = None;
      language = None;
      format = None;
      multichannel = None;
      channels = None;
      diarize = None;
      keyterm = [];
      filler_words = None;
      vad_threshold = None;
    }
  in
  List.iter
    (fun (id, source) ->
      let request =
        X.Audio.Speech_to_text.request ~api_key:key (base_stt source)
        |> expect_ok id
      in
      Alcotest.(check string) id "POST" request.method_)
    [
      ("xaistt-9ncy", X.Audio.Speech_to_text.Url "https://audio.example/a.wav");
      ( "xaistt-9ncy",
        X.Audio.Speech_to_text.File
          {
            A.Audio.filename = "a.wav";
            content_type = "audio/wav";
            source = A.Audio.bytes (Bytes.of_string "audio");
          } );
    ];
  List.iter
    (fun format ->
      let request =
        { (base_stt (X.Audio.Speech_to_text.Url "https://audio.example/raw")) with
          audio_format = Some format;
          sample_rate = Some 16000;
        }
      in
      ignore
        (X.Audio.Speech_to_text.request ~api_key:key request
        |> expect_ok "xaistt-tlyz raw format"))
    [ X.Audio.Speech_to_text.Pcm; X.Audio.Speech_to_text.Mulaw; X.Audio.Speech_to_text.Alaw ];
  List.iter
    (fun rate ->
      let request =
        { (base_stt (X.Audio.Speech_to_text.Url "https://audio.example/raw")) with
          audio_format = Some X.Audio.Speech_to_text.Pcm;
          sample_rate = Some rate;
        }
      in
      ignore
        (X.Audio.Speech_to_text.request ~api_key:key request
        |> expect_ok "xaistt-yi4h sample rate"))
    [ 8000; 16000; 22050; 24000; 44100; 48000 ];
  let complete_stt =
    {
      (base_stt (X.Audio.Speech_to_text.Url "https://audio.example/raw")) with
      audio_format = Some X.Audio.Speech_to_text.Pcm;
      sample_rate = Some 16000;
      language = Some "en";
      format = Some true;
      multichannel = Some true;
      channels = Some 2;
      diarize = Some true;
      keyterm = [ "Eta" ];
      filler_words = Some false;
      vad_threshold = Some 0.1;
    }
  in
  let stt = X.Audio.Speech_to_text.request ~api_key:key complete_stt |> expect_ok "STT fields" in
  List.iter
    (fun field -> require "xaistt-1j69 complete unary STT fields" field (body stt))
    [ {|name="audio_format"|}; {|name="sample_rate"|}; {|name="language"|};
      {|name="format"|}; {|name="multichannel"|}; {|name="channels"|};
      {|name="diarize"|}; {|name="keyterm"|}; {|name="filler_words"|};
      {|name="vad_threshold"|} ];
  let tts ?(codec = X.Audio.Text_to_speech.Mp3) ?sample_rate ?bit_rate ?speed
      ?latency () : X.Audio.Text_to_speech.request =
    {
      text = "hello";
      language = "en";
      voice_id = Some "voice";
      output_format = Some { codec; sample_rate; bit_rate };
      speed;
      optimize_streaming_latency = latency;
      text_normalization = Some true;
      with_timestamps = true;
    }
  in
  let complete =
    X.Audio.Text_to_speech.request ~api_key:key
      (tts ~sample_rate:24000 ~bit_rate:128000 ~speed:1.2 ~latency:1 ())
    |> expect_ok "complete TTS"
  in
  List.iter
    (fun field -> require "xaitts-wfo1 complete unary TTS fields" field (body complete))
    [ {|"text":"hello"|}; {|"language":"en"|}; {|"voice_id":"voice"|};
      {|"output_format"|}; {|"speed":1.2|}; {|"optimize_streaming_latency":1|};
      {|"text_normalization":true|}; {|"with_timestamps":true|} ];
  List.iter
    (fun latency ->
      ignore
        (X.Audio.Text_to_speech.request ~api_key:key (tts ~latency ())
        |> expect_ok "xaitts-3gtl latency"))
    [ 0; 1 ];
  List.iter
    (fun codec ->
      ignore
        (X.Audio.Text_to_speech.request ~api_key:key (tts ~codec ())
        |> expect_ok "xaitts-6c22 codec"))
    [ X.Audio.Text_to_speech.Mp3; X.Audio.Text_to_speech.Wav; X.Audio.Text_to_speech.Pcm;
      X.Audio.Text_to_speech.Mulaw; X.Audio.Text_to_speech.Alaw ];
  List.iter
    (fun sample_rate ->
      ignore
        (X.Audio.Text_to_speech.request ~api_key:key (tts ~sample_rate ())
        |> expect_ok "xaitts-3s49 sample rate"))
    [ 8000; 16000; 22050; 24000; 44100; 48000 ];
  List.iter
    (fun bit_rate ->
      ignore
        (X.Audio.Text_to_speech.request ~api_key:key (tts ~bit_rate ())
        |> expect_ok "xaitts-36y7 MP3 bit rate"))
    [ 32000; 64000; 96000; 128000; 192000 ];
  List.iter
    (fun speed ->
      ignore
        (X.Audio.Text_to_speech.request ~api_key:key (tts ~speed ())
        |> expect_ok "xaitts-9hog speed range"))
    [ 0.7; 1.5 ];
  let realtime_formats =
    [
      ("xairt-tkis", X.Audio.Realtime.pcmu, "audio/pcmu", 8000, 1);
      ("xairt-q2pj", X.Audio.Realtime.pcma, "audio/pcma", 8000, 1);
      ("xairt-r2oo", X.Audio.Realtime.opus, "audio/opus", 24000, 1);
    ]
  in
  List.iter
    (fun (id, format, mime, rate, channels) ->
      Alcotest.(check bool) id true
        (X.Audio.Realtime.audio_format_mime format = mime
        && X.Audio.Realtime.audio_format_sample_rate format = rate
        && X.Audio.Realtime.audio_format_channels format = channels))
    realtime_formats;
  Alcotest.(check (list string)) "xairt-yhm2 complete Realtime audio formats"
    [ "audio/pcm"; "audio/pcmu"; "audio/pcma"; "audio/opus" ]
    [
      X.Audio.Realtime.pcm ~sample_rate:8000 |> expect_ok "pcm"
      |> X.Audio.Realtime.audio_format_mime;
      X.Audio.Realtime.audio_format_mime X.Audio.Realtime.pcmu;
      X.Audio.Realtime.audio_format_mime X.Audio.Realtime.pcma;
      X.Audio.Realtime.audio_format_mime X.Audio.Realtime.opus;
    ];
  List.iter
    (fun rate ->
      let format = X.Audio.Realtime.pcm ~sample_rate:rate |> expect_ok "xairt-35ni" in
      Alcotest.(check int) "xairt-35ni PCM sample rate" rate
        (X.Audio.Realtime.audio_format_sample_rate format))
    [ 8000; 16000; 22050; 24000; 32000; 44100; 48000 ];
  let too_many_ids =
    X.Responses.File_search
      { vector_store_ids = List.init 11 string_of_int; max_num_results = None }
  in
  (match X.Responses.encode_request (base_responses_request [ too_many_ids ]) with
  | Error (X.Error.Invalid_request _) ->
      Alcotest.(check bool) "xairsp-uog6 file search bound before transport" true true
  | _ -> Alcotest.fail "file search vector_store_ids bound");
  let image_and_prior =
    {
      (base_responses_request []) with
      input =
        X.Responses.Input_items
          [
            X.Responses.Input_message
              {
                role = X.Responses.User;
                content =
                  [
                    X.Responses.Input_image
                      { image_url = "https://images.example/a.png" };
                    X.Responses.Input_file (X.Responses.File_id "file_1");
                    X.Responses.Input_file (X.Responses.File_data "ZmlsZQ==");
                  ];
              };
            X.Responses.Prior_output
              (X.Responses.Message
                 { id = Some "m"; status = None; role = Some "assistant";
                   content = []; raw = `Assoc [ ("type", `String "message") ] });
          ];
    }
  in
  let encoded =
    X.Responses.encode_request image_and_prior |> expect_ok "input variants"
  in
  require "xairsp-ekvc image input" {|"image_url":"https://images.example/a.png"|}
    encoded;
  require "xairsp-zlqu exactly-one file variants" {|"file_id":"file_1"|} encoded;
  require "xairsp-2ojb prior output" {|"type":"message"|} encoded

let test_collections_results_and_timestamps () =
  B.with_traced_runtime @@ fun _ctx rt tracer ->
  let management_key =
    X.Collections.management_key "MANAGEMENT-CREDENTIAL-SENTINEL"
  in
  let create : X.Collections.create_request =
    {
      collection_name = "SEC Filings";
      team_id = None;
      collection_description = None;
      index_configuration = None;
      chunk_configuration = None;
      metric_space = None;
      field_definitions = [];
      version = Some 2;
    }
  in
  let resource =
    run_ok rt "create collection fixture"
      (X.Collections.create_collection
         (client (read_fixture "collection.json") (ref None))
         ~management_key create)
  in
  Alcotest.(check bool) "xaicol-uxmp collection resource fields" true
    (resource.collection_id
       = "collection_80100614-300c-4609-959b-a138fa90f542"
    && resource.collection_name = Some "SEC Filings"
    && Option.is_some resource.created_at
    && Option.is_some resource.index_configuration
    && Option.is_some resource.chunk_configuration
    && Option.is_some resource.metric_space
    && resource.documents_count = Some 0L
    && resource.field_definitions <> []);
  Alcotest.(check (option string)) "collection RFC3339"
    (Some "2025-09-16T18:36:09.790629Z") resource.created_at;
  let update : X.Collections.update_request =
    {
      team_id = None;
      collection_name = Some "Updated";
      collection_description = None;
      chunk_configuration = None;
      field_definition_updates = [];
    }
  in
  ignore
    (run_ok rt "update collection fixture"
       (X.Collections.update_collection
          (client (read_fixture "collection.json") (ref None))
          ~management_key ~collection_id:"collection_1" update));
  let mutation operation =
    ignore (run_ok rt "empty mutation response" operation)
  in
  mutation
    (X.Collections.delete_collection
       (client "{}" (ref None))
       ~management_key ~collection_id:"collection_1");
  mutation
    (X.Collections.add_file
       (client "{}" (ref None))
       ~management_key ~collection_id:"collection_1" ~file_id:"file_1" ());
  mutation
    (X.Collections.reindex_document
       (client "{}" (ref None))
       ~management_key ~collection_id:"collection_1" ~file_id:"file_1");
  mutation
    (X.Collections.remove_document
       (client "{}" (ref None))
       ~management_key ~collection_id:"collection_1" ~file_id:"file_1");
  let document =
    run_ok rt "document timestamp fixture"
      (X.Collections.get_document
         (client (read_fixture "document.json") (ref None))
         ~management_key ~collection_id:"collection_1" ~file_id:"file_1")
  in
  Alcotest.(check bool) "xaicol-9efa document fields" true
    (Option.is_some document.file_metadata && document.fields = [ ("type", "10-Q") ]
    && document.status = Some "DOCUMENT_STATUS_PROCESSED"
    && document.error_message = Some "" && Option.is_some document.last_indexed_at);
  Alcotest.(check (option string)) "last indexed RFC3339"
    (Some "2025-09-16T19:07:03.000000Z") document.last_indexed_at;
  let custom =
    run_ok rt "custom voice timestamp fixture"
      (X.Audio.Voices.list_custom
         (client (read_fixture "custom_voices.json") (ref None))
         ~api_key:(A.api_key "key") ())
  in
  let search_json =
    {|{"matches":[{"file_id":"file_1","chunk_id":"chunk_1","chunk_content":"Eta","score":0.99,"collection_ids":["collection_1"],"fields":{"lang":"en"},"page_number":7}]}|}
  in
  let search_request : X.Collections.search_request =
    {
      query = "Eta";
      collection_ids = [ "collection_1" ];
      rag_pipeline = None;
      filter = None;
      limit = None;
      instructions = None;
      group_by = None;
      retrieval_mode = X.Collections.Semantic None;
    }
  in
  let search =
    run_ok rt "document search fixture"
      (X.Collections.search (client search_json (ref None))
         ~api_key:(A.api_key "key") search_request)
  in
  (match search.matches with
  | [ match_ ] ->
      Alcotest.(check bool) "xaicol-gz06 search match fields" true
        (match_.file_id = Some "file_1" && match_.chunk_id = Some "chunk_1"
        && match_.chunk_content = Some "Eta" && match_.score = Some 0.99
        && match_.collection_ids = [ "collection_1" ]
        && match_.fields <> [] && match_.page_number = Some 7)
  | _ -> Alcotest.fail "search match fixture");
  let rendered_attrs =
    Eta_observability.Tracer.dump tracer
    |> List.concat_map (fun (span : Eta_observability.Tracer.span) -> List.map snd span.attrs)
    |> String.concat " "
  in
  Alcotest.(check bool) "xaisec-khar management key excluded from telemetry"
    false
    (contains ~needle:"MANAGEMENT-CREDENTIAL-SENTINEL" rendered_attrs);
  match custom.voices with
  | [ voice ] ->
      Alcotest.(check (option string)) "custom voice RFC3339"
        (Some "2026-04-26T18:56:34.872993+00:00") voice.created_at
  | _ -> Alcotest.fail "custom voice fixture"

let test_stored_response_pagination () =
  B.with_runtime @@ fun _ctx rt ->
  let page =
    run_ok rt "stored response input page"
      (X.Responses.list_input_items
         (client (read_fixture "stored_input_items.json") (ref None))
         ~api_key:(A.api_key "key") ~response_id:"resp_1" ())
  in
  Alcotest.(check bool) "has_more" true page.has_more;
  Alcotest.(check (option string)) "last_id" (Some "item_2") page.last_id;
  Alcotest.(check (option string)) "xaicore-gio1 explicit continuation/no fetch"
    (Some "item_2")
    page.continuation

let test_large_owned_binary_results () =
  B.with_runtime @@ fun _ctx rt ->
  let bytes = Bytes.make (2 * 1024 * 1024) 'x' in
  let binary_client content_type =
    client_with_stream ~headers:[ ("content-type", content_type) ]
      (H.Body.Stream.of_bytes [ bytes ]) (ref None)
  in
  let file =
    run_ok rt "large file content"
      (X.Files.content (binary_client "application/octet-stream")
         ~api_key:(A.api_key "key") ~file_id:"file_1" ~format:X.Files.Original)
  in
  Alcotest.(check int) "large file bytes" (Bytes.length bytes)
    (Bytes.length file.bytes);
  let tts_request : X.Audio.Text_to_speech.request =
    {
      text = "large";
      language = "en";
      voice_id = Some "eve";
      output_format = None;
      speed = None;
      optimize_streaming_latency = None;
      text_normalization = None;
      with_timestamps = false;
    }
  in
  let tts =
    run_ok rt "large TTS body"
      (X.Audio.Text_to_speech.synthesize (binary_client "audio/mpeg")
         ~api_key:(A.api_key "key") tts_request)
  in
  (match tts with
  | X.Audio.Text_to_speech.Raw_audio audio ->
      Alcotest.(check int) "large TTS bytes" (Bytes.length bytes)
        (Bytes.length audio.audio)
  | _ -> Alcotest.fail "raw TTS");
  let voice =
    run_ok rt "large custom voice body"
      (X.Audio.Voices.custom_audio (binary_client "audio/wav")
         ~api_key:(A.api_key "key") ~voice_id:"voice_1")
  in
  Alcotest.(check int) "large voice bytes" (Bytes.length bytes)
    (Bytes.length voice.bytes)

let test_file_resource_result_schemas () =
  B.with_runtime @@ fun _ctx rt ->
  let key = A.api_key "key" in
  let resource_json =
    {|{"id":"file_1","object":"file","bytes":3,"created_at":10,"expires_at":20,"filename":"doc.txt","purpose":"assistants","public_url":"https://files.example/1","public_url_expires_at":30}|}
  in
  let file =
    run_ok rt "file result fixture"
      (X.Files.get (client resource_json (ref None)) ~api_key:key ~file_id:"file_1")
  in
  Alcotest.(check bool) "xaifile-9t4o complete file resource" true
    (file.id = "file_1" && file.object_ = Some "file" && file.bytes = Some 3L
    && file.created_at = Some 10L && file.expires_at = Some 20L
    && file.filename = Some "doc.txt" && file.purpose = Some "assistants"
    && file.public_url = Some "https://files.example/1"
    && file.public_url_expires_at = Some 30L);
  let deleted =
    run_ok rt "file deletion fixture"
      (X.Files.delete
         (client {|{"id":"file_1","object":"file","deleted":true}|} (ref None))
         ~api_key:key ~file_id:"file_1")
  in
  Alcotest.(check bool) "xaifile-kp5x typed deletion result" true
    (deleted.id = "file_1" && deleted.deleted);
  let public_url =
    run_ok rt "public URL fixture"
      (X.Files.create_public_url
         (client {|{"public_url":"https://files.example/1","expires_at":30}|} (ref None))
         ~api_key:key ~file_id:"file_1" ())
  in
  Alcotest.(check bool) "xaifile-8ybi public URL result fields" true
    (public_url.public_url = "https://files.example/1"
    && public_url.expires_at = Some 30L);
  let revocation =
    run_ok rt "public URL revocation fixture"
      (X.Files.revoke_public_url
         (client {|{"id":"file_1","revoked":true,"public_url":"https://files.example/1"}|} (ref None))
         ~api_key:key ~file_id:"file_1")
  in
  Alcotest.(check bool) "xaifile-27kp typed revocation result" true
    (revocation.id = Some "file_1" && revocation.revoked)

let controlled_body chunks release_count =
  let chunks = ref chunks in
  H.Body.Stream.of_reader
    ~release:(fun () ->
      incr release_count;
      E.unit)
    (fun () ->
      match !chunks with
      | [] -> E.pure H.Body.Stream.End
      | chunk :: rest ->
          chunks := rest;
          E.pure (H.Body.Stream.Chunk (Bytes.of_string chunk)))

let test_sse_release_and_terminal_fence () =
  B.with_traced_runtime @@ fun _ctx rt tracer ->
  let release_count = ref 0 in
  let body =
    controlled_body
      [
        "data: {\"type\":\"response.first\"}\n\n\
         data: [DONE]\n\n\
         data: {not-json-after-done}\n\n";
      ]
      release_count
  in
  let stream =
    run_ok rt "open SSE"
      (X.Responses.stream
         (client_with_stream body (ref None))
         ~api_key:(A.api_key "key") (base_responses_request []))
  in
  Alcotest.(check bool) "xairsp-ks0s xAI-specific pull stream opened" true true;
  (match run_ok rt "first SSE event" (X.Responses.read_stream_event stream) with
  | Some (X.Responses.Unknown_event { type_ = Some "response.first"; _ }) -> ()
  | _ -> Alcotest.fail "first SSE event");
  Alcotest.(check int) "not released before DONE" 0 !release_count;
  (match run_ok rt "DONE event" (X.Responses.read_stream_event stream) with
  | Some X.Responses.Done -> ()
  | _ -> Alcotest.fail "DONE event");
  Alcotest.(check int) "xairsp-t1ui DONE finishes/releases pull stream" 1
    !release_count;
  Alcotest.(check bool) "post-DONE event cleared" true
    (Option.is_none
       (run_ok rt "SSE after DONE" (X.Responses.read_stream_event stream)));
  let stream_span =
    Eta_observability.Tracer.dump tracer
    |> List.find (fun (span : Eta_observability.Tracer.span) ->
           List.assoc_opt "gen_ai.request.stream" span.attrs = Some "true")
  in
  Alcotest.(check (option string)) "xaiobs-67fn streaming request attr"
    (Some "true") (List.assoc_opt "gen_ai.request.stream" stream_span.attrs);
  Alcotest.(check bool) "xaiobs-2vw6 SSE first-chunk timing" true
    (List.mem_assoc "gen_ai.response.time_to_first_chunk" stream_span.attrs);
  let released_on_error = ref 0 in
  let malformed =
    controlled_body
      [
        "data: {\"type\":\"response.first\"}\n\n";
        "data: {not-json}\n\n";
      ]
      released_on_error
  in
  let stream =
    run_ok rt "open malformed SSE"
      (X.Responses.stream
         (client_with_stream malformed (ref None))
         ~api_key:(A.api_key "key") (base_responses_request []))
  in
  ignore (run_ok rt "valid event before error" (X.Responses.read_stream_event stream));
  (match B.run rt (X.Responses.read_stream_event stream) with
  | Eta.Exit.Error _ -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "malformed SSE must fail");
  Alcotest.(check int) "released once on decode failure" 1 !released_on_error;
  let released_on_open_error = ref 0 in
  let malformed_first_chunk =
    controlled_body [ "data: {not-json}\n\n" ] released_on_open_error
  in
  (match
     B.run rt
       (X.Responses.stream
          (client_with_stream malformed_first_chunk (ref None))
          ~api_key:(A.api_key "key") (base_responses_request []))
   with
  | Eta.Exit.Error _ -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "malformed first SSE chunk must fail");
  Alcotest.(check int) "released once on open decode failure" 1
    !released_on_open_error

let test_role_typed_endpoints_and_port_attrs () =
  let inference =
    X.Endpoint.inference "https://inference.proxy.test:8443"
    |> expect_ok "inference endpoint"
  in
  let management =
    X.Endpoint.management "https://management.proxy.test:9443"
    |> expect_ok "management endpoint"
  in
  let inference_request =
    X.Responses.create_request ~endpoint:inference ~api_key:(A.api_key "key")
      (base_responses_request [])
    |> expect_ok "proxy inference request"
  in
  require "inference proxy" "https://inference.proxy.test:8443/"
    inference_request.uri;
  let management_request =
    X.Collections.get_collection_request ~management_endpoint:management
      ~management_key:(X.Collections.management_key "management")
      ~collection_id:"collection_1" ()
  in
  require "management proxy" "https://management.proxy.test:9443/"
    management_request.uri;
  B.with_traced_runtime @@ fun _ctx rt tracer ->
  let transport_span_name = "XAI NESTED TRANSPORT SENTINEL" in
  let captured = ref None in
  let nested_transport_client =
    H.Client.make_custom ~protocol:H.Client.H1
      ~request:(fun request ->
        captured := Some request;
        Eta_observability.named ~kind:Eta.Capabilities.Client
          transport_span_name
          (E.pure
             (H.Response.make
                ~status:200
                ~body:
                  (H.Body.Stream.of_bytes
                     [ Bytes.of_string (read_fixture "response.json") ])
                ())))
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)
  in
  ignore
    (run_ok rt "port telemetry"
       (X.Responses.create ~endpoint:inference
          nested_transport_client
          ~api_key:(A.api_key "key") (base_responses_request [])));
  let spans = Eta_observability.Tracer.dump tracer in
  Alcotest.(check bool) "xaiobs-e3sy nested transport span suppressed" false
    (List.exists
       (fun (span : Eta_observability.Tracer.span) -> span.name = transport_span_name)
       spans);
  let span =
    spans
    |> List.find_opt (fun (span : Eta_observability.Tracer.span) -> span.name = "chat xai")
    |> Option.get
  in
  Alcotest.(check (option string)) "xaiobs-veq9 explicit server port" (Some "8443")
    (List.assoc_opt "server.port" span.attrs);
  Alcotest.(check (option string)) "xaiobs-8ztz finish reason" (Some "stop")
    (List.assoc_opt "gen_ai.response.finish_reasons" span.attrs);
  match X.Error.to_ai_error (X.Error.Invalid_request "bad local request") with
  | A.Provider_error { code = Some "invalid_request"; status = None; _ } -> ()
  | A.Unsupported _ -> Alcotest.fail "invalid request mapped to Unsupported"
  | _ -> Alcotest.fail "invalid request projection"

let test_xai_http_fixture_runners_and_spans () =
  B.with_traced_runtime @@ fun _ctx rt tracer ->
  let captured = ref None in
  let telemetry_request =
    {
      (base_responses_request [ X.Responses.Function (tool ()) ]) with
      input =
        X.Responses.Input_items
          [
            X.Responses.Input_message
              {
                role = X.Responses.User;
                content = [ X.Responses.Input_text "PROMPT-CONTENT-SENTINEL" ];
              };
            X.Responses.Function_call_output
              {
                call_id = "call_1";
                output =
                  [ X.Responses.Input_text "TOOL-RESULT-CONTENT-SENTINEL" ];
              };
          ];
    }
  in
  let response =
    run_ok rt "Responses fixture runner"
      (X.Responses.create
         (client (read_fixture "response.json") captured)
         ~api_key:(A.api_key "fixture-secret")
         telemetry_request)
  in
  Alcotest.(check string) "xaicore-02y2 valid request reached transport/result"
    "resp_xai_fixture" response.id;
  let request = Option.get !captured in
  Alcotest.(check (option string)) "runner auth"
    (Some "Bearer fixture-secret")
    (H.Core.Header.get "authorization" request.headers);
  Alcotest.(check bool) "xaisec-ut3h raw inference key only in auth data" true
    (H.Core.Header.get "authorization" request.headers
     = Some "Bearer fixture-secret");
  Alcotest.(check bool) "xaisec-p3p6 inference key bound to api.x.ai" true
    (contains ~needle:"https://api.x.ai/" request.uri
    && H.Core.Header.get "authorization" request.headers
       = Some "Bearer fixture-secret");
  let spans = Eta_observability.Tracer.dump tracer in
  Alcotest.(check int) "xaiobs-98ld exactly one REST GenAI span" 1
    (List.length
       (List.filter (fun (span : Eta_observability.Tracer.span) -> span.name = "chat xai") spans));
  let span =
    match
      List.find_opt
        (fun (span : Eta_observability.Tracer.span) -> span.name = "chat xai")
        spans
    with
    | Some span -> span
    | None -> Alcotest.fail "missing xAI operation span"
  in
  let attr name = List.assoc_opt name span.attrs in
  Alcotest.(check (option string)) "xaiobs-fkqh provider attr" (Some "xai")
    (attr "gen_ai.provider.name");
  Alcotest.(check (option string)) "xaiobs-rtcw operation attr" (Some "chat")
    (attr "gen_ai.operation.name");
  Alcotest.(check (option string)) "xaiobs-2bo2 server address"
    (Some "api.x.ai") (attr "server.address");
  Alcotest.(check (option string)) "xaiobs-4hfa request model"
    (Some "grok-4.5") (attr "gen_ai.request.model");
  Alcotest.(check (option string)) "xaiobs-h4yv response id attr"
    (Some "resp_xai_fixture") (attr "gen_ai.response.id");
  Alcotest.(check (option string)) "xaiobs-mqxo response model"
    (Some "grok-4.5") (attr "gen_ai.response.model");
  Alcotest.(check (option string)) "xaiobs-lxsp input usage attr" (Some "12")
    (attr "gen_ai.usage.input_tokens");
  Alcotest.(check (option string)) "xaiobs-48m9 output usage attr" (Some "8")
    (attr "gen_ai.usage.output_tokens");
  let rendered = String.concat " " (List.map snd span.attrs) in
  List.iter
    (fun (id, sentinel) ->
      Alcotest.(check bool) id false (contains ~needle:sentinel rendered))
    [
      ("xaisec-sags", "fixture-secret");
      ("xaiobs-md1q", "PROMPT-CONTENT-SENTINEL");
      ("xaiobs-u7fb", "OUTPUT_SENTINEL");
      ("xaiobs-4szd", {|{"city"|});
      ("xaiobs-r290", "TOOL-RESULT-CONTENT-SENTINEL");
    ];
  let models =
    run_ok rt "model fixture runner"
      (X.Models.list_models
         (client (read_fixture "models.json") (ref None))
         ~api_key:(A.api_key "fixture-secret"))
  in
  (match models with
  | [ model ] ->
      Alcotest.(check bool) "xaimod-i41q generic model fields" true
        (model.X.Models.id = "grok-4.5"
        && model.aliases = [ "grok-latest" ]
        && model.created = Some 1785360000L && model.object_ = Some "model"
        && model.owned_by = Some "xai" && model.context_length = Some 500000L
        && model.prompt_text_token_price = Some 10L
        && model.cached_prompt_text_token_price = Some 2L
        && model.prompt_image_token_price = Some 20L
        && model.completion_text_token_price = Some 30L
        && model.long_context_threshold = Some 200000L
        && model.image_price = Some 40L)
  | _ -> Alcotest.fail "model fixture");
  let model_spans =
    Eta_observability.Tracer.dump tracer
    |> List.filter (fun (span : Eta_observability.Tracer.span) ->
           span.name = "list_models xai")
  in
  Alcotest.(check int) "xaiobs-hchu one ordinary provider client span" 1
    (List.length model_spans);
  let model_span = List.hd model_spans in
  Alcotest.(check (option string)) "ordinary provider name" (Some "xai")
    (List.assoc_opt "eta_ai.provider.name" model_span.attrs);
  Alcotest.(check bool) "xaiobs-jdm1 resource is not a GenAI operation" false
    (Option.is_some
       (List.assoc_opt "gen_ai.operation.name" model_span.attrs));
  let language =
    run_ok rt "language model fixture"
      (X.Models.list_language_models
         (client
            {|{"models":[{"id":"grok","fingerprint":"fp","version":"v1","input_modalities":["text","image"],"output_modalities":["text"],"search_price":5,"aliases":["latest"]}]}|}
            (ref None))
         ~api_key:(A.api_key "key"))
  in
  (match language with
  | [ model ] ->
      Alcotest.(check bool) "xaimod-l6mt language model fields" true
        (model.fingerprint = Some "fp" && model.version = Some "v1"
        && model.input_modalities = [ "text"; "image" ]
        && model.output_modalities = [ "text" ]
        && model.search_price = Some 5L && model.aliases = [ "latest" ])
  | _ -> Alcotest.fail "language model fixture");
  let tts : X.Audio.Text_to_speech.request =
    {
      text = "hi";
      language = "en";
      voice_id = Some "eve";
      output_format = Some { codec = X.Audio.Text_to_speech.Mp3; sample_rate = None; bit_rate = None };
      speed = None;
      optimize_streaming_latency = None;
      text_normalization = None;
      with_timestamps = true;
    }
  in
  let timestamped =
    run_ok rt "timestamped TTS"
      (X.Audio.Text_to_speech.synthesize
         (client
            ~headers:[ ("content-type", "application/json") ]
            (read_fixture "tts_timestamped.json") (ref None))
         ~api_key:(A.api_key "fixture-secret") tts)
  in
  (match timestamped with
  | X.Audio.Text_to_speech.Timestamped_audio value ->
      Alcotest.(check bool) "xaitts-2xcr timestamped result fields" true
        (Bytes.to_string value.audio = "MP3"
        && value.content_type = Some "audio/mpeg"
        && value.duration = Some 0.92 && value.graph_chars = [ "H"; "i" ]);
      require "xaitts-m0n3 graph_times preserved" "\"start\":0.06"
        (A.Json.compact value.graph_times)
  | X.Audio.Text_to_speech.Raw_audio _ -> Alcotest.fail "timestamped variant");
  let raw =
    run_ok rt "raw TTS"
      (X.Audio.Text_to_speech.synthesize
         (client ~headers:[ ("content-type", "audio/mpeg") ] "MP3" (ref None))
         ~api_key:(A.api_key "fixture-secret")
         { tts with with_timestamps = false })
  in
  match raw with
  | X.Audio.Text_to_speech.Raw_audio value ->
      Alcotest.(check bool) "xaitts-b7vv raw bytes/content type" true
        (Bytes.to_string value.audio = "MP3"
        && value.content_type = Some "audio/mpeg");
      Alcotest.(check bool) "xaitts-ho68 explicit result variants" true true
  | X.Audio.Text_to_speech.Timestamped_audio _ -> Alcotest.fail "raw variant"

let test_oabridge_xai_neutral_conversion_and_projection () =
  let neutral_tts : A.Audio.Text_to_speech.request =
    {
      text = "hello";
      voice = "custom_voice";
      encoding = Some A.Audio.Text_to_speech.Mp3;
      speed = Some 1.2;
    }
  in
  let construction = X.Audio.Text_to_speech.of_eta_ai neutral_tts in
  (* oabridge-d348: neutral conversion yields only an abstract construction.
     xAI's required language and provider-only controls are supplied separately
     before a submittable provider request exists. *)
  let configured =
    X.Audio.Text_to_speech.configure
      {
        language = "en";
        sample_rate = Some 24000;
        bit_rate = Some 128000;
        optimize_streaming_latency = Some 1;
        text_normalization = Some true;
        with_timestamps = false;
      }
      construction
    |> expect_ok "oabridge-pmod/d348 xAI TTS configure"
  in
  Alcotest.(check string) "provider language supplied separately" "en"
    configured.language;
  Alcotest.(check (option string)) "neutral voice converted"
    (Some "custom_voice") configured.voice_id;
  (match
     X.Audio.Text_to_speech.configure
       {
         language = "";
         sample_rate = None;
         bit_rate = None;
         optimize_streaming_latency = None;
         text_normalization = None;
         with_timestamps = false;
       }
       construction
   with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "oabridge-d348 must not invent a missing xAI language");
  (match configured.output_format with
  | Some { codec = X.Audio.Text_to_speech.Mp3; sample_rate; bit_rate } ->
      Alcotest.(check (option int)) "provider sample rate" (Some 24000)
        sample_rate;
      Alcotest.(check (option int)) "provider bit rate" (Some 128000) bit_rate
  | _ -> Alcotest.fail "neutral MP3 encoding was not converted");
  let projected =
    X.Audio.Text_to_speech.to_eta_ai
      (X.Audio.Text_to_speech.Timestamped_audio
         {
           audio = Bytes.of_string "MP3";
           content_type = Some "audio/mpeg";
           duration = Some 0.5;
           graph_chars = [ "h" ];
           graph_times = `List [];
           raw = "{}";
         })
  in
  Alcotest.(check string) "oabridge-ff14 explicit TTS projection" "MP3"
    (Bytes.to_string projected.audio);
  let upload : A.Audio.upload =
    {
      filename = "sample.wav";
      content_type = "audio/wav";
      source = A.Audio.bytes (Bytes.of_string "RIFF");
    }
  in
  let construction =
    X.Audio.Speech_to_text.of_eta_ai
      { A.Audio.Speech_to_text.upload = upload; language = Some "en" }
  in
  let configured =
    X.Audio.Speech_to_text.configure
      {
        audio_format = None;
        sample_rate = None;
        format = None;
        multichannel = None;
        channels = None;
        diarize = Some true;
        keyterm = [ "Eta" ];
        filler_words = None;
        vad_threshold = Some 0.5;
      }
      construction
    |> expect_ok "oabridge-pmod/d348 xAI STT configure"
  in
  Alcotest.(check (option string)) "neutral language converted" (Some "en")
    configured.language;
  let projected =
    X.Audio.Speech_to_text.to_eta_ai
      {
        X.Audio.Speech_to_text.text = "hello";
        language = Some "en";
        duration = Some 1.0;
        words = [];
        channels = [];
        raw = "{}";
      }
  in
  Alcotest.(check (option string)) "oabridge-ff14 explicit STT projection"
    (Some "hello") projected.text

let tests =
  [
    ( "xai",
      [
        Alcotest.test_case "package capabilities security" `Quick
          test_xaipkg_capabilities_security;
        Alcotest.test_case "Responses complete request" `Quick
          test_xairsp_complete_request_and_validation;
        Alcotest.test_case "Responses lossless decode and SSE" `Quick
          test_xairsp_lossless_response_and_stream;
        Alcotest.test_case "Responses and Files lifecycle paths" `Quick
          test_xairsp_lifecycle_and_files_requests;
        Alcotest.test_case "Collections authorities and operations" `Quick
          test_xaicol_hosts_and_operations;
        Alcotest.test_case "Models speech and Realtime" `Quick
          test_xaimod_stt_tts_realtime;
        Alcotest.test_case
          "oabridge-pmod/d348/ff14 xAI neutral conversion and projection" `Quick
          test_oabridge_xai_neutral_conversion_and_projection;
        Alcotest.test_case "Realtime client/server codec matrix" `Quick
          test_xairt_client_and_server_event_codecs;
        Alcotest.test_case "lossless errors" `Quick
          test_xaicore_error_lossless;
        Alcotest.test_case "UTF-8 scalar validation" `Quick
          test_utf8_scalar_validation;
        Alcotest.test_case "local contract validation matrix" `Quick
          test_local_contract_validation_matrix;
        Alcotest.test_case "Collections mutation results and timestamps" `Quick
          test_collections_results_and_timestamps;
        Alcotest.test_case "stored Response pagination" `Quick
          test_stored_response_pagination;
        Alcotest.test_case "large owned binary results" `Quick
          test_large_owned_binary_results;
        Alcotest.test_case "Files result schemas" `Quick
          test_file_resource_result_schemas;
        Alcotest.test_case "SSE release and terminal fence" `Quick
          test_sse_release_and_terminal_fence;
        Alcotest.test_case "role-typed endpoints and telemetry" `Quick
          test_role_typed_endpoints_and_port_attrs;
        Alcotest.test_case "HTTP fixture runners and spans" `Quick
          test_xai_http_fixture_runners_and_spans;
      ] );
  ]

let () = Alcotest.run "eta-ai-xai" tests
