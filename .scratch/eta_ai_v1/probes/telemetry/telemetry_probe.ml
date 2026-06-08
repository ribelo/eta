open Eta

let annotate attrs eff =
  List.fold_right
    (fun (key, value) acc -> Effect.annotate ~key ~value acc)
    attrs eff

let with_span ~kind ~name ~attrs eff =
  annotate attrs eff |> Effect.named_kind ~kind name

let common_attrs ~operation ~provider ~model =
  [
    ("gen_ai.operation.name", operation);
    ("gen_ai.provider.name", provider);
    ("gen_ai.request.model", model);
    ("server.address", "api.openai.com");
    ("server.port", "443");
  ]

let chat_span =
  Effect.unit
  |> with_span ~kind:Capabilities.Client ~name:"chat gpt-4o-mini"
       ~attrs:
         (common_attrs ~operation:"chat" ~provider:"openai" ~model:"gpt-4o-mini"
         @ [
             ("gen_ai.response.id", "chatcmpl_a5");
             ("gen_ai.response.model", "gpt-4o-mini-2024-07-18");
             ("gen_ai.response.finish_reasons", "stop");
             ("gen_ai.usage.input_tokens", "13");
             ("gen_ai.usage.output_tokens", "18");
             ("gen_ai.output.type", "text");
           ])

let streaming_span =
  Effect.unit
  |> with_span ~kind:Capabilities.Client ~name:"chat gpt-4o-mini"
       ~attrs:
         (common_attrs ~operation:"chat" ~provider:"openai" ~model:"gpt-4o-mini"
         @ [
             ("gen_ai.request.stream", "true");
             ("gen_ai.response.id", "chatcmpl_stream_a5");
             ("gen_ai.response.model", "gpt-4o-mini-2024-07-18");
             ("gen_ai.response.finish_reasons", "stop");
             ("gen_ai.response.time_to_first_chunk", "0.037");
             ("gen_ai.usage.input_tokens", "21");
             ("gen_ai.usage.output_tokens", "8");
           ])

let embeddings_span =
  Effect.unit
  |> with_span ~kind:Capabilities.Client ~name:"embeddings text-embedding-3-small"
       ~attrs:
         (common_attrs ~operation:"embeddings" ~provider:"openai"
            ~model:"text-embedding-3-small"
         @ [
             ("gen_ai.request.encoding_formats", "float");
             ("gen_ai.usage.input_tokens", "9");
           ])

let tool_execution_span =
  Effect.unit
  |> with_span ~kind:Capabilities.Internal ~name:"execute_tool weather"
       ~attrs:
         [
           ("gen_ai.operation.name", "execute_tool");
           ("gen_ai.tool.name", "weather");
           ("gen_ai.tool.call.id", "call_weather_a5");
           ("gen_ai.tool.type", "function");
         ]

let tool_call_parent_span =
  let parent_attrs =
    common_attrs ~operation:"chat" ~provider:"openai" ~model:"gpt-4o-mini"
    @ [
        ("gen_ai.response.id", "chatcmpl_tool_a5");
        ("gen_ai.response.model", "gpt-4o-mini-2024-07-18");
        ("gen_ai.response.finish_reasons", "tool_calls");
        ("gen_ai.usage.input_tokens", "82");
        ("gen_ai.usage.output_tokens", "17");
        ("gen_ai.tool.definitions", "weather");
      ]
  in
  Effect.bind
    (fun () -> tool_execution_span)
    (annotate parent_attrs Effect.unit)
  |> Effect.named_kind ~kind:Capabilities.Client "chat gpt-4o-mini"

let run_effect rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      failwith
        (Format.asprintf "unexpected effect failure: %a"
           (Cause.pp Format.pp_print_string) cause)

let attr span key = List.assoc_opt key span.Tracer.attrs

let check name condition =
  if condition then Printf.printf "ok %s\n" name
  else failwith ("check failed: " ^ name)

let require_attr span key expected =
  check (span.Tracer.name ^ " has " ^ key) (attr span key = Some expected)

let find_span spans name pred =
  match List.find_opt (fun span -> span.Tracer.name = name && pred span) spans with
  | Some span -> span
  | None -> failwith ("missing span: " ^ name)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Tracer.in_memory () in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Tracer.as_capability tracer) ()
  in
  run_effect rt
    (Effect.concat [ chat_span; streaming_span; embeddings_span; tool_call_parent_span ]);
  let spans = Tracer.dump tracer in
  check "span count" (List.length spans = 5);

  let chat =
    find_span spans "chat gpt-4o-mini" (fun span ->
        attr span "gen_ai.response.id" = Some "chatcmpl_a5")
  in
  require_attr chat "gen_ai.operation.name" "chat";
  require_attr chat "gen_ai.provider.name" "openai";
  require_attr chat "gen_ai.request.model" "gpt-4o-mini";
  require_attr chat "gen_ai.usage.input_tokens" "13";

  let streaming =
    find_span spans "chat gpt-4o-mini" (fun span ->
        attr span "gen_ai.request.stream" = Some "true")
  in
  require_attr streaming "gen_ai.response.time_to_first_chunk" "0.037";
  require_attr streaming "gen_ai.usage.output_tokens" "8";

  let embeddings =
    find_span spans "embeddings text-embedding-3-small" (fun _ -> true)
  in
  require_attr embeddings "gen_ai.operation.name" "embeddings";
  require_attr embeddings "gen_ai.request.encoding_formats" "float";

  let tool_parent =
    find_span spans "chat gpt-4o-mini" (fun span ->
        attr span "gen_ai.response.finish_reasons" = Some "tool_calls")
  in
  require_attr tool_parent "gen_ai.tool.definitions" "weather";

  let tool = find_span spans "execute_tool weather" (fun _ -> true) in
  require_attr tool "gen_ai.operation.name" "execute_tool";
  require_attr tool "gen_ai.tool.name" "weather";
  require_attr tool "gen_ai.tool.call.id" "call_weather_a5";
  check "tool span parent" (tool.Tracer.parent_id = Some tool_parent.span_id);

  Printf.printf "telemetry_probe=ok\n";
  Printf.printf "spans=%d\n" (List.length spans);
  Printf.printf "semconv_source=semantic-conventions-genai/model/gen-ai/spans.yaml\n";
  Printf.printf "attribute_value_encoding=stringified_eta_attrs\n"
