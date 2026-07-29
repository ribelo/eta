module A = Eta_ai
module X = Eta_ai_xai
module E = Eta.Effect
module H = Eta_http
module B = Eta_test_backend_eio.Backend

let read_fixture name =
  let input = open_in (Filename.concat "fixtures" name) in
  Fun.protect ~finally:(fun () -> close_in_noerr input) (fun () ->
      really_input_string input (in_channel_length input))

let expect_ok label = function
  | Ok value -> value
  | Error error ->
      Alcotest.failf "%s: %a" label X.Error.pp error

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
  | H.Request.Stream _ | H.Request.Rewindable_stream _ ->
      Alcotest.fail "expected fixed request body"

let fixed_chunks request =
  match request.H.Request.body with
  | H.Request.Fixed chunks -> chunks
  | H.Request.Empty | H.Request.Stream _ | H.Request.Rewindable_stream _ ->
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
  Alcotest.(check string) "provider" "xai" X.provider_name;
  Alcotest.(check bool) "Responses" true X.Capabilities.detailed.responses_create;
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
  Alcotest.(check string) "redacted inference" "<redacted:api_key>"
    (Format.asprintf "%a" Eta_redacted.pp (X.api_key credential));
  ignore (X.Collections.management_key "management-secret")

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
    (fun expected -> require expected expected encoded)
    [
      {|"max_turns":4|};
      {|"top_k":20|};
      {|"min_p":0.1|};
      {|"search_parameters":{"mode":"auto"}|};
      {|"type":"file_search"|};
      {|"vector_store_ids":["collection_1"]|};
      {|"type":"mcp"|};
      {|"action":"edit"|};
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
  require "file URL" {|"file_url":"https://files.example/a.pdf"|} encoded;
  require "compaction" {|"encrypted_content":"opaque"|} encoded;
  match
    X.Responses.encode_request
      (base_responses_request
         (List.init 129 (fun _ -> X.Responses.Code_interpreter)))
  with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "expected 128-tool validation"

let test_xairsp_lossless_response_and_stream () =
  let response =
    X.Responses.decode_response (read_fixture "response.json")
    |> expect_ok "response fixture"
  in
  Alcotest.(check string) "id" "resp_xai_fixture" response.id;
  Alcotest.(check (option int)) "cached" (Some 3)
    (Option.bind response.usage (fun usage -> usage.cached_tokens));
  Alcotest.(check (option int64)) "nano USD" (Some 12345L)
    (Option.bind response.usage (fun usage -> usage.cost_in_nano_usd));
  Alcotest.(check (option int64)) "USD ticks" (Some 37756000L)
    (Option.bind response.usage (fun usage -> usage.cost_in_usd_ticks));
  (match List.rev response.output with
  | X.Responses.Unknown raw :: _ ->
      require "unknown raw" "provider_extension" (A.Json.compact raw)
  | _ -> Alcotest.fail "unknown output item not preserved");
  let neutral = X.Responses.to_eta_ai_response response in
  Alcotest.(check (option string)) "neutral id" (Some "resp_xai_fixture")
    neutral.id;
  (match
     X.Responses.decode_stream_event
       { A.event = None; data = {|{"type":"response.future","xai":1}|} }
   with
  | Ok (X.Responses.Unknown_event { raw; _ }) ->
      require "unknown event raw" {|"xai":1|} raw
  | _ -> Alcotest.fail "unknown SSE event");
  match X.Responses.decode_stream_event { A.event = None; data = " [DONE] " } with
  | Ok X.Responses.Done -> ()
  | _ -> Alcotest.fail "DONE"

let test_xairsp_lifecycle_and_files_requests () =
  let key = A.api_key "inference-secret" in
  let create =
    X.Responses.create_request ~api_key:key (base_responses_request [])
    |> expect_ok "create request"
  in
  Alcotest.(check string) "create path" "https://api.x.ai/v1/responses"
    create.uri;
  let retrieve =
    X.Responses.retrieve_request ~api_key:key ~response_id:"resp_1" ()
  in
  Alcotest.(check string) "retrieve" "GET" retrieve.method_;
  let delete =
    X.Responses.delete_request ~api_key:key ~response_id:"resp_1" ()
  in
  Alcotest.(check string) "delete" "DELETE" delete.method_;
  let inputs =
    X.Responses.list_input_items_request ~api_key:key ~response_id:"resp_1"
      ~limit:20 ~order:`Asc ~after:"item_1" ()
    |> expect_ok "input items list"
  in
  require "input items path" "/input_items?limit=20&order=asc&after=item_1"
    inputs.uri;
  let compact =
    X.Responses.compact_request ~api_key:key (base_responses_request [])
    |> expect_ok "compact"
  in
  Alcotest.(check string) "compact path"
    "https://api.x.ai/v1/responses/compact" compact.uri;
  let file_data = Bytes.of_string "eta" in
  let upload =
    X.Files.upload_request ~api_key:key ~expires_after_s:3600
      ~purpose:"assistants"
      { A.filename = "doc.txt"; content_type = "text/plain"; data = file_data }
    |> expect_ok "file upload"
  in
  let upload_body = body upload in
  let expiry = index "expiry" {|name="expires_after"|} upload_body in
  let file = index "file" {|name="file"|} upload_body in
  Alcotest.(check bool) "expiry before file" true (expiry < file);
  Alcotest.(check bool) "multipart preserves original file bytes" true
    (List.exists (fun chunk -> chunk == file_data) (fixed_chunks upload));
  let content =
    X.Files.content_request ~api_key:key ~file_id:"file_1"
      ~format:X.Files.Text ()
  in
  require "text content path" "format=text" content.uri;
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
  require "file list query" "pagination_token=next" list.uri;
  Alcotest.(check string) "file get" "GET"
    (X.Files.get_request ~api_key:key ~file_id:"file_1" ()).method_;
  Alcotest.(check string) "file delete" "DELETE"
    (X.Files.delete_request ~api_key:key ~file_id:"file_1" ()).method_;
  let public_url =
    X.Files.create_public_url_request ~api_key:key ~file_id:"file_1"
      ~expires_after_s:3600 ()
    |> expect_ok "public URL"
  in
  Alcotest.(check string) "public URL method" "POST" public_url.method_;
  let revoke =
    X.Files.revoke_public_url_request ~api_key:key ~file_id:"file_1" ()
  in
  Alcotest.(check string) "public URL revoke" "POST"
    revoke.method_;
  match
    X.Files.create_public_url_request ~api_key:key ~file_id:"file_1"
      ~expires_after_s:3599 ()
  with
  | Error (X.Error.Invalid_request _) -> ()
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
  Alcotest.(check string) "management host"
    "https://management-api.x.ai/v1/collections" request.uri;
  Alcotest.(check (option string)) "management auth"
    (Some "Bearer management-secret")
    (H.Core.Header.get "authorization" request.headers);
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
  Alcotest.(check string) "exact collection creation body"
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
      X.Collections.list_collections_request ~management_key:management
        list_config
      |> expect_ok "collection list";
      X.Collections.get_collection_request ~management_key:management
        ~collection_id:"collection_1" ();
      update_request;
      X.Collections.delete_collection_request ~management_key:management
        ~collection_id:"collection_1" ();
      add_file_request;
      X.Collections.list_documents_request ~management_key:management
        ~collection_id:"collection_1" list_config
      |> expect_ok "document list";
      X.Collections.get_document_request ~management_key:management
        ~collection_id:"collection_1" ~file_id:"file_1" ();
      X.Collections.reindex_document_request ~management_key:management
        ~collection_id:"collection_1" ~file_id:"file_1" ();
      X.Collections.remove_document_request ~management_key:management
        ~collection_id:"collection_1" ~file_id:"file_1" ();
      X.Collections.batch_get_documents_request ~management_key:management
        ~collection_id:"collection_1" ~file_ids:[ "file_1"; "file_2" ] ()
      |> expect_ok "batchGet";
    ]
  in
  Alcotest.(check int) "collection operation census" 10
    (List.length collection_requests);
  List.iter
    (fun request ->
      require "management authority" "https://management-api.x.ai/"
        request.H.Request.uri)
    collection_requests;
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
  Alcotest.(check string) "search inference host"
    "https://api.x.ai/v1/documents/search" request.uri;
  require "hybrid" {|"type":"hybrid"|} (body request)

let test_xaimod_stt_tts_realtime () =
  let key = A.api_key "inference-secret" in
  List.iter
    (fun request ->
      Alcotest.(check string) "catalog GET" "GET" request.H.Request.method_)
    [
      X.Models.models_request ~api_key:key ();
      X.Models.model_request ~api_key:key ~model_id:"grok-4.5" ();
      X.Models.language_models_request ~api_key:key ();
      X.Models.language_model_request ~api_key:key ~model_id:"grok-4.5" ();
      X.Models.embedding_models_request ~api_key:key ();
      X.Models.embedding_model_request ~api_key:key ~model_id:"embed" ();
      X.Models.image_generation_models_request ~api_key:key ();
      X.Models.image_generation_model_request ~api_key:key ~model_id:"image" ();
      X.Models.video_generation_models_request ~api_key:key ();
      X.Models.video_generation_model_request ~api_key:key ~model_id:"video" ();
    ];
  let custom_voices =
    X.Voices.custom_list_request ~api_key:key ~limit:100
      ~pagination_token:"next" ()
    |> expect_ok "custom voice list"
  in
  List.iter
    (fun request ->
      Alcotest.(check string) "voice GET" "GET" request.H.Request.method_)
    [
      X.Voices.built_in_list_request ~api_key:key ();
      X.Voices.built_in_get_request ~api_key:key ~voice_id:"eve" ();
      custom_voices;
      X.Voices.custom_get_request ~api_key:key ~voice_id:"custom_opaque" ();
      X.Voices.custom_audio_request ~api_key:key ~voice_id:"custom_opaque" ();
    ];
  let stt : X.Speech_to_text.request =
    {
      source =
        X.Speech_to_text.File
          { A.filename = "audio.raw"; content_type = "application/octet-stream"; data = Bytes.of_string "pcm" };
      audio_format = Some X.Speech_to_text.Pcm;
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
  let request = X.Speech_to_text.request ~api_key:key stt |> expect_ok "STT" in
  let request_body = body request in
  Alcotest.(check bool) "options before STT file" true
    (index "sample rate" {|name="sample_rate"|} request_body
     < index "STT file" {|name="file"|} request_body);
  let transcript =
    X.Speech_to_text.decode_response (read_fixture "stt.json")
    |> expect_ok "STT fixture"
  in
  Alcotest.(check int) "word" 1 (List.length transcript.words);
  let tts : X.Text_to_speech.request =
    {
      text = "hello";
      language = "en";
      voice_id = Some "custom_opaque";
      output_format =
        Some { codec = X.Text_to_speech.Mp3; sample_rate = Some 24000; bit_rate = Some 128000 };
      speed = Some 1.2;
      optimize_streaming_latency = Some 1;
      text_normalization = Some true;
      with_timestamps = true;
    }
  in
  let request = X.Text_to_speech.request ~api_key:key tts |> expect_ok "TTS" in
  require "opaque voice" {|"voice_id":"custom_opaque"|} (body request);
  let pcm = X.Realtime.pcm ~sample_rate:32000 |> expect_ok "PCM" in
  let realtime_tools =
    [
      X.Realtime.Function
        {
          name = "lookup";
          description = Some "Lookup";
          parameters = `Assoc [ ("type", `String "object") ];
        };
      X.Realtime.Web_search
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
      X.Realtime.X_search
        {
          allowed_x_handles = List.init 20 (fun index -> "handle" ^ string_of_int index);
          excluded_x_handles = [];
          from_date = Some "2026-01-01";
          to_date = Some "2026-01-31";
          enable_image_understanding = Some true;
          enable_video_understanding = Some true;
        };
    ]
  in
  let realtime =
    X.Realtime.session ~instructions:"brief" ~model:"grok-voice-latest"
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
          transport = X.Realtime.Json;
          transcription = Some { language_hint = Some "en"; keyterms = [ "Eta" ] };
        }
      ~output_audio:
        { format = X.Realtime.opus; transport = X.Realtime.Binary; speed = Some 1.1 }
      ()
    |> expect_ok "Realtime session"
  in
  let session = X.Realtime.session_to_string realtime in
  List.iter (fun needle -> require needle needle session)
    [ {|"resumption":{"enabled":true}|}; {|"replace":{"ETA":"eta"}|}; {|"type":"audio/opus"|} ];
  let session_json =
    A.Json.parse session |> function
    | Ok json -> json
    | Error message -> Alcotest.fail message
  in
  let audio = A.Json.object_member "audio" session_json |> Option.get in
  let input = A.Json.object_member "input" audio |> Option.get in
  let output = A.Json.object_member "output" audio |> Option.get in
  let input_format = A.Json.object_member "format" input |> Option.get in
  Alcotest.(check (option string)) "voice is session-level"
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
    X.Realtime.X_search
      {
        allowed_x_handles = [ "xai" ];
        excluded_x_handles = [ "other" ];
        from_date = None;
        to_date = None;
        enable_image_understanding = None;
        enable_video_understanding = None;
      }
  in
  (match X.Realtime.session ~tools:[ both_handles ] () with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "mutually exclusive Realtime X handles");
  let too_many_handles =
    X.Realtime.X_search
      {
        allowed_x_handles = List.init 21 string_of_int;
        excluded_x_handles = [];
        from_date = None;
        to_date = None;
        enable_image_understanding = None;
        enable_video_understanding = None;
      }
  in
  (match X.Realtime.session ~tools:[ too_many_handles ] () with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "Realtime X handles max 20");
  let append =
    X.Realtime.client_event_message
      (X.Realtime.Input_audio_buffer_append (Bytes.of_string "pcm"))
  in
  (match append with
  | A.Realtime.Text raw -> require "JSON append" "input_audio_buffer.append" raw
  | A.Realtime.Binary _ -> Alcotest.fail "JSON append");
  let binary =
    X.Realtime.client_event_message
      (X.Realtime.Input_audio_binary (Bytes.of_string "pcm"))
  in
  (match binary with
  | A.Realtime.Binary _ -> ()
  | A.Realtime.Text _ -> Alcotest.fail "binary transport");
  let secret =
    X.Realtime.client_secret_request ~api_key:key ~expires_after_s:3600 ()
    |> expect_ok "client secret"
  in
  Alcotest.(check string) "client secret path"
    "https://api.x.ai/v1/realtime/client_secrets" secret.uri

let test_xaicore_error_lossless () =
  let headers =
    H.Core.Header.unsafe_of_list
      [ ("content-type", "application/json"); ("retry-after", "7"); ("x-request-id", "r1") ]
  in
  let raw = read_fixture "error.json" in
  let error = X.decode_error ~status:422 ~headers raw in
  (match error with
  | X.Error.Provider { status = 422; headers; payload; raw_body } ->
      Alcotest.(check (option string)) "code" (Some "bad_xai_request") payload.code;
      Alcotest.(check (option string)) "header" (Some "r1")
        (H.Core.Header.get "x-request-id" headers);
      Alcotest.(check string) "nested provider payload raw"
        {|{"message":"request rejected","type":"invalid_request_error","code":"bad_xai_request","param":{"field":"tools"}}|}
        (A.Json.compact payload.raw);
      Alcotest.(check string) "raw" raw raw_body
  | _ -> Alcotest.fail "typed provider error");
  match X.Error.to_ai_error error with
  | A.Provider_error { status = Some 422; retry_after_s = Some 7; _ } -> ()
  | _ -> Alcotest.fail "neutral error projection"

let test_utf8_scalar_validation () =
  let repeated count value =
    String.concat "" (List.init count (fun _ -> value))
  in
  let tts text : X.Text_to_speech.request =
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
    (X.Text_to_speech.request ~api_key:(A.api_key "key")
       (tts (repeated 15_000 "é"))
    |> expect_ok "15000 Unicode scalar TTS input");
  (match
     X.Text_to_speech.request ~api_key:(A.api_key "key")
       (tts (repeated 15_001 "é"))
   with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "15001 Unicode scalar TTS input");
  (match X.Text_to_speech.request ~api_key:(A.api_key "key") (tts "\xC0\xAF") with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "invalid UTF-8 TTS input");
  let stt keyterm : X.Speech_to_text.request =
    {
      source = X.Speech_to_text.Url "https://audio.example/input.wav";
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
    (X.Speech_to_text.request ~api_key:(A.api_key "key")
       (stt (repeated 50 "😀"))
    |> expect_ok "50 Unicode scalar STT keyterm");
  (match
     X.Speech_to_text.request ~api_key:(A.api_key "key")
       (stt (repeated 51 "😀"))
   with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "51 Unicode scalar STT keyterm");
  let pcm = X.Realtime.pcm ~sample_rate:24000 |> expect_ok "pcm" in
  (match
     X.Realtime.session
       ~input_audio:
         {
           format = pcm;
           transport = X.Realtime.Json;
           transcription =
             Some { language_hint = None; keyterms = [ "\xED\xA0\x80" ] };
         }
       ()
   with
  | Error (X.Error.Invalid_request _) -> ()
  | _ -> Alcotest.fail "invalid UTF-8 Realtime keyterm")

let test_collections_results_and_timestamps () =
  B.with_runtime @@ fun _ctx rt ->
  let management_key = X.Collections.management_key "management-key" in
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
  Alcotest.(check (option string)) "last indexed RFC3339"
    (Some "2025-09-16T19:07:03.000000Z") document.last_indexed_at;
  let custom =
    run_ok rt "custom voice timestamp fixture"
      (X.Voices.list_custom
         (client (read_fixture "custom_voices.json") (ref None))
         ~api_key:(A.api_key "key") ())
  in
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
  Alcotest.(check (option string)) "continuation" (Some "item_2")
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
  let tts_request : X.Text_to_speech.request =
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
      (X.Text_to_speech.synthesize (binary_client "audio/mpeg")
         ~api_key:(A.api_key "key") tts_request)
  in
  (match tts with
  | X.Text_to_speech.Raw_audio audio ->
      Alcotest.(check int) "large TTS bytes" (Bytes.length bytes)
        (Bytes.length audio.bytes)
  | _ -> Alcotest.fail "raw TTS");
  let voice =
    run_ok rt "large custom voice body"
      (X.Voices.custom_audio (binary_client "audio/wav")
         ~api_key:(A.api_key "key") ~voice_id:"voice_1")
  in
  Alcotest.(check int) "large voice bytes" (Bytes.length bytes)
    (Bytes.length voice.bytes)

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
  B.with_runtime @@ fun _ctx rt ->
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
  (match run_ok rt "first SSE event" (X.Responses.read_stream_event stream) with
  | Some (X.Responses.Unknown_event { type_ = Some "response.first"; _ }) -> ()
  | _ -> Alcotest.fail "first SSE event");
  Alcotest.(check int) "not released before DONE" 0 !release_count;
  (match run_ok rt "DONE event" (X.Responses.read_stream_event stream) with
  | Some X.Responses.Done -> ()
  | _ -> Alcotest.fail "DONE event");
  Alcotest.(check int) "released once at DONE" 1 !release_count;
  Alcotest.(check bool) "post-DONE event cleared" true
    (Option.is_none
       (run_ok rt "SSE after DONE" (X.Responses.read_stream_event stream)));
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
        E.named ~kind:Eta.Capabilities.Client transport_span_name
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
  let spans = Eta.Tracer.dump tracer in
  Alcotest.(check bool) "nested transport span suppressed" false
    (List.exists
       (fun (span : Eta.Tracer.span) -> span.name = transport_span_name)
       spans);
  let span =
    spans
    |> List.find_opt (fun (span : Eta.Tracer.span) -> span.name = "chat xai")
    |> Option.get
  in
  Alcotest.(check (option string)) "explicit server port" (Some "8443")
    (List.assoc_opt "server.port" span.attrs);
  Alcotest.(check bool) "status is not finish reason" false
    (List.mem_assoc "gen_ai.response.finish_reasons" span.attrs);
  match X.Error.to_ai_error (X.Error.Invalid_request "bad local request") with
  | A.Provider_error { code = Some "invalid_request"; status = None; _ } -> ()
  | A.Unsupported _ -> Alcotest.fail "invalid request mapped to Unsupported"
  | _ -> Alcotest.fail "invalid request projection"

let test_xai_http_fixture_runners_and_spans () =
  B.with_traced_runtime @@ fun _ctx rt tracer ->
  let captured = ref None in
  let response =
    run_ok rt "Responses fixture runner"
      (X.Responses.create
         (client (read_fixture "response.json") captured)
         ~api_key:(A.api_key "fixture-secret")
         (base_responses_request []))
  in
  Alcotest.(check string) "runner response" "resp_xai_fixture" response.id;
  let request = Option.get !captured in
  Alcotest.(check (option string)) "runner auth"
    (Some "Bearer fixture-secret")
    (H.Core.Header.get "authorization" request.headers);
  let spans = Eta.Tracer.dump tracer in
  let span =
    match
      List.find_opt
        (fun (span : Eta.Tracer.span) -> span.name = "chat xai")
        spans
    with
    | Some span -> span
    | None -> Alcotest.fail "missing xAI operation span"
  in
  let attr name = List.assoc_opt name span.attrs in
  Alcotest.(check (option string)) "provider attr" (Some "xai")
    (attr "gen_ai.provider.name");
  Alcotest.(check (option string)) "response id attr"
    (Some "resp_xai_fixture") (attr "gen_ai.response.id");
  Alcotest.(check (option string)) "input usage attr" (Some "12")
    (attr "gen_ai.usage.input_tokens");
  Alcotest.(check bool) "secret absent from span" false
    (contains ~needle:"fixture-secret"
       (String.concat " " (List.map snd span.attrs)));
  let models =
    run_ok rt "model fixture runner"
      (X.Models.list_models
         (client (read_fixture "models.json") (ref None))
         ~api_key:(A.api_key "fixture-secret"))
  in
  (match models with
  | [ model ] ->
      Alcotest.(check (option int64)) "model context" (Some 500000L)
        model.X.Models.context_length;
      Alcotest.(check (option int64)) "model image price" (Some 40L)
        model.image_price
  | _ -> Alcotest.fail "model fixture");
  let tts : X.Text_to_speech.request =
    {
      text = "hi";
      language = "en";
      voice_id = Some "eve";
      output_format = Some { codec = X.Text_to_speech.Mp3; sample_rate = None; bit_rate = None };
      speed = None;
      optimize_streaming_latency = None;
      text_normalization = None;
      with_timestamps = true;
    }
  in
  let timestamped =
    run_ok rt "timestamped TTS"
      (X.Text_to_speech.synthesize
         (client
            ~headers:[ ("content-type", "application/json") ]
            (read_fixture "tts_timestamped.json") (ref None))
         ~api_key:(A.api_key "fixture-secret") tts)
  in
  (match timestamped with
  | X.Text_to_speech.Timestamped_audio value ->
      Alcotest.(check string) "decoded audio" "MP3" (Bytes.to_string value.audio);
      require "mixed graph_times preserved" "\"start\":0.06"
        (A.Json.compact value.graph_times)
  | X.Text_to_speech.Raw_audio _ -> Alcotest.fail "timestamped variant");
  let raw =
    run_ok rt "raw TTS"
      (X.Text_to_speech.synthesize
         (client ~headers:[ ("content-type", "audio/mpeg") ] "MP3" (ref None))
         ~api_key:(A.api_key "fixture-secret")
         { tts with with_timestamps = false })
  in
  match raw with
  | X.Text_to_speech.Raw_audio value ->
      Alcotest.(check string) "raw bytes" "MP3" (Bytes.to_string value.bytes)
  | X.Text_to_speech.Timestamped_audio _ -> Alcotest.fail "raw variant"

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
        Alcotest.test_case "lossless errors" `Quick
          test_xaicore_error_lossless;
        Alcotest.test_case "UTF-8 scalar validation" `Quick
          test_utf8_scalar_validation;
        Alcotest.test_case "Collections mutation results and timestamps" `Quick
          test_collections_results_and_timestamps;
        Alcotest.test_case "stored Response pagination" `Quick
          test_stored_response_pagination;
        Alcotest.test_case "large owned binary results" `Quick
          test_large_owned_binary_results;
        Alcotest.test_case "SSE release and terminal fence" `Quick
          test_sse_release_and_terminal_fence;
        Alcotest.test_case "role-typed endpoints and telemetry" `Quick
          test_role_typed_endpoints_and_port_attrs;
        Alcotest.test_case "HTTP fixture runners and spans" `Quick
          test_xai_http_fixture_runners_and_spans;
      ] );
  ]

let () = Alcotest.run "eta-ai-xai" tests
