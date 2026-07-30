# eta_ai_xai

Transport-neutral xAI provider for `eta_ai`.

The package owns request construction, lossless decode, redacted credentials,
and HTTP runners for xAI Responses, Files, Collections, model catalogs, unary
speech, voice discovery, and Realtime client-secret/session codecs. It has no
xAI SDK, no Eio WebSocket connection, and no js_of_ocaml adapter.

## Why it exists

xAI's wire surface is not a thin OpenAI clone. This package keeps provider
quirks (management-plane Collections, typed Responses tools, Realtime session
codecs, STT/TTS option validation) out of `eta_ai` and out of the Eio transport
layer. Applications own conversation state and tool execution; the library only
describes and interprets provider I/O.

## Package boundary

| Package | Owns |
| --- | --- |
| `eta_ai_xai` | Codecs, redacted keys, HTTP request builders, unary runners, Realtime event codecs + client-secret REST |
| `eta_ai_xai_eio` | Native Eio WebSocket transports (`Responses_ws`, `Realtime`, `Streaming_stt`, `Streaming_tts`) |
| Application | `Eta_http.Client.t`, runtime, tool handlers, stored response IDs, audio buffers |

Depends on: `eta`, `eta_ai`, `eta_redacted`, `eta_http`, `base64`, `yojson`.

Does not depend on: `eio`, `eta_http_eio`, sibling providers, xAI SDKs, or JS
packages. There is no `eta_ai_xai_js` adapter.

Pass an explicit `Eta_http.Client.t` (for example from `Eta_http_eio.Client.make`).

## Credentials and endpoints

```ocaml
(* Either constructor works; credential is a private alias of Eta_ai.api_key. *)
let api_key =
  match Sys.getenv_opt "XAI_API_KEY" with
  | Some value -> Eta_ai.api_key value
  | None -> failwith "XAI_API_KEY is required"

let credential = Eta_ai_xai.credential "xai-secret"
let api_key_from_credential = Eta_ai_xai.api_key credential
let headers = Eta_ai_xai.authorization_headers credential

let management = Eta_ai_xai.Collections.management_key "management-secret"
let ephemeral = Eta_ai_xai.Audio.Realtime.client_secret "ephemeral-secret"

let default_inference_base = Eta_ai_xai.default_base_url
(* "https://api.x.ai" *)
let default_management_base = Eta_ai_xai.default_management_base_url
(* "https://management-api.x.ai" *)

let inference =
  match Eta_ai_xai.Endpoint.inference default_inference_base with
  | Ok endpoint -> endpoint
  | Error error -> failwith (Format.asprintf "%a" Eta_ai_xai.Error.pp error)

let management_endpoint =
  match Eta_ai_xai.Endpoint.management default_management_base with
  | Ok endpoint -> endpoint
  | Error error -> failwith (Format.asprintf "%a" Eta_ai_xai.Error.pp error)
```

- Inference API key: `Eta_ai.api_key` or `Eta_ai_xai.credential` (redacted label
  `api_key`). `Eta_ai_xai.api_key credential` projects the private credential
  alias back to `Eta_ai.api_key`.
- Management key: `Collections.management_key` (redacted label
  `xai_management_api_key`). Used only on the management plane.
- Realtime client secret: `Audio.Realtime.client_secret` (redacted label
  `xai_realtime_client_secret`). Create via REST; connect with
  `eta_ai_xai_eio`.
- `Endpoint.inference` and `Endpoint.management` are nominally distinct so an
  inference key cannot be routed through a management base URL by accident.

Do not log `Eta_redacted.value`. Printing a redacted key yields a placeholder
such as `<redacted:api_key>`.

## Responses

Typed xAI Responses request, resource CRUD, HTTP SSE stream, and projection
into `Eta_ai.response`.

```ocaml
open Eta_ai_xai

let tool =
  match
    Eta_ai.make_tool ~name:"weather" ~description:"Weather"
      ~input_schema_json:
        {|{"type":"object","properties":{"city":{"type":"string"}}}|}
      ()
  with
  | Ok tool -> tool
  | Error _ -> failwith "tool"

let request : Responses.request =
  {
    model = "grok-4.5";
    input = Responses.Text_input "weather in Warsaw";
    instructions = Some "brief";
    previous_response_id = None;
    store = Some true;
    include_ = [ "reasoning.encrypted_content" ];
    stream = false;
    tools =
      [
        Responses.Function tool;
        Responses.Web_search
          {
            allowed_domains = [ "example.com" ];
            excluded_domains = [];
            enable_image_search = Some true;
            enable_image_understanding = None;
          };
        Responses.Code_interpreter;
        Responses.File_search
          { vector_store_ids = [ "collection_1" ]; max_num_results = Some 3 };
      ];
    tool_choice = Some Responses.Auto_tools;
    parallel_tool_calls = Some true;
    max_turns = Some 4;
    max_output_tokens = Some 128;
    temperature = Some 0.2;
    top_p = None;
    top_k = None;
    min_p = None;
    text = Some { format = Responses.Json_object };
    reasoning =
      Some
        {
          effort = Some "high";
          summary = Some "detailed";
          generate_summary = Some true;
        };
    reasoning_effort = Some "high";
    search_parameters = None;
    service_tier = Some Responses.Priority;
    user = Some "eta-user";
    prompt_cache_key = Some "eta-cache";
  }

(* Unary create against an application-owned HTTP client *)
let create_effect client ~api_key =
  Responses.create client ~api_key request

(* Stored response helpers *)
let retrieve_effect client ~api_key ~response_id =
  Responses.retrieve client ~api_key ~response_id

let delete_effect client ~api_key ~response_id =
  Responses.delete client ~api_key ~response_id

let list_items_effect client ~api_key ~response_id =
  Responses.list_input_items client ~api_key ~response_id
    ~limit:20 ~order:`Asc ()

let compact_effect client ~api_key =
  Responses.compact client ~api_key request

(* HTTP SSE: open, pull, close. Concurrent reads on one stream fail. *)
let stream_effect client ~api_key =
  let open Eta.Syntax in
  let* stream =
    Responses.stream client ~api_key { request with stream = true }
  in
  let rec loop () =
    let* event = Responses.read_stream_event stream in
    match event with
    | None | Some Responses.Done -> Responses.close_stream stream
    | Some (Responses.Unknown_event _) -> loop ()
  in
  loop ()

(* Provider-neutral encode path (function tools only at the Eta_ai layer) *)
let neutral_provider = responses_provider ()

let of_eta_ai_example () =
  let neutral : Responses.tool Eta_ai.Responses.request =
    {
      model = "grok-4.5";
      input = Eta_ai.Responses.Text "hello";
      instructions = None;
      previous_response_id = None;
      store = None;
      include_ = [];
      tools = [ Responses.Function tool ];
      tool_choice = Some Eta_ai.Responses.Auto;
      parallel_tool_calls = None;
      max_turns = None;
      max_output_tokens = Some 64;
      temperature = None;
      top_p = None;
      top_k = None;
      min_p = None;
      text = None;
      reasoning = None;
      reasoning_effort = None;
      service_tier = None;
      user = None;
      prompt_cache_key = None;
      replay_items = [];
      stream = false;
    }
  in
  Responses.of_eta_ai neutral
```

### Typed projections

- `Responses.decode_response` → `Responses.response` with typed `output_item`
  variants (`Message`, `Reasoning`, `Function_call`, server tool calls,
  `Compaction`, `Unknown`).
- `Responses.to_eta_ai_response` projects into the shared `Eta_ai.response`.
- HTTP SSE decodes only `Done` and `Unknown_event` today; use
  `to_eta_ai_stream_events` for the neutral stream surface (`Stream_done` from
  `Done`; unknown frames project to no events).
- WebSocket Responses streaming lives in `eta_ai_xai_eio.Responses_ws`.

### Application-owned tool execution

Server-side tools (`Web_search`, `X_search`, `Code_interpreter`, `File_search`,
`Mcp`, `Image_generation`) run on xAI. Function tools do not: the package
decodes `Function_call` items and encodes `Function_call_output` inputs; your
application executes the tool and feeds the next request. The library does not
keep a tool registry or conversation loop.

## Files

```ocaml
let file : Eta_ai.binary_file =
  {
    filename = "notes.pdf";
    content_type = "application/pdf";
    data = Bytes.of_string "%PDF";
  }

let upload client ~api_key =
  Eta_ai_xai.Files.upload client ~api_key ~expires_after_s:3600
    ~purpose:"assistants" file

let list client ~api_key =
  Eta_ai_xai.Files.list client ~api_key
    {
      limit = Some 20;
      order = Some Eta_ai_xai.Files.Desc;
      sort_by = Some Eta_ai_xai.Files.Filename;
      pagination_token = None;
      filter = None;
    }

let content client ~api_key ~file_id =
  Eta_ai_xai.Files.content client ~api_key ~file_id
    ~format:Eta_ai_xai.Files.Original

let public_url client ~api_key ~file_id =
  Eta_ai_xai.Files.create_public_url client ~api_key ~file_id
    ~expires_after_s:3600 ()
```

`expires_after_s` for upload and public URLs must be in `3600 .. 2592000`.

## Collections

Management-plane CRUD uses `management_key` and
`https://management-api.x.ai` by default. Document search uses the inference
API key and inference endpoint.

```ocaml
open Eta_ai_xai

let create_collection client ~management_key =
  Collections.create_collection client ~management_key
    {
      collection_name = "docs";
      team_id = None;
      collection_description = Some "Eta docs";
      index_configuration = None;
      chunk_configuration = None;
      metric_space = Some Collections.Cosine;
      field_definitions =
        [
          {
            key = "source";
            required = Some true;
            unique = None;
            inject_into_chunk = Some true;
            description = Some "origin";
          };
        ];
      version = None;
    }

let search client ~api_key =
  Collections.search client ~api_key
    {
      query = "cancellation";
      collection_ids = [ "collection_1" ];
      rag_pipeline = None;
      filter = None;
      limit = Some 5;
      instructions = None;
      group_by = None;
      retrieval_mode = Collections.Hybrid None;
    }
```

## Models

Catalog GETs only (no create/delete):

- `/v1/models`, `/v1/language-models`
- `/v1/embedding-models`, `/v1/image-generation-models`, `/v1/video-generation-models`

```ocaml
let list client ~api_key =
  Eta_ai_xai.Models.list_language_models client ~api_key

let get client ~api_key =
  Eta_ai_xai.Models.get_model client ~api_key ~model_id:"grok-4.5"
```

`Capabilities.shared.embeddings` and `video_generation` stay `false`: catalog
listing is implemented; embedding/video generation runners are not.

## Unary speech and voices

```ocaml
open Eta_ai_xai

let stt : Audio.Speech_to_text.request =
  {
    source =
      Audio.Speech_to_text.File
        {
          Eta_ai.Audio.filename = "audio.wav";
          content_type = "audio/wav";
          source = Eta_ai.Audio.bytes (Bytes.of_string "RIFF");
        };
    audio_format = None;
    sample_rate = None;
    language = Some "en";
    format = Some true;
    multichannel = None;
    channels = None;
    diarize = Some true;
    keyterm = [ "Eta" ];
    filler_words = Some false;
    vad_threshold = None;
  }

let transcribe client ~api_key =
  Audio.Speech_to_text.transcribe client ~api_key stt

let tts : Audio.Text_to_speech.request =
  {
    text = "hello";
    language = "en";
    voice_id = Some "eve";
    output_format =
      Some
        {
          codec = Audio.Text_to_speech.Mp3;
          sample_rate = Some 24000;
          bit_rate = Some 128000;
        };
    speed = Some 1.0;
    optimize_streaming_latency = None;
    text_normalization = Some true;
    with_timestamps = false;
  }

let synthesize client ~api_key =
  Audio.Text_to_speech.synthesize client ~api_key tts

let voices client ~api_key =
  let open Eta.Syntax in
  let* built_in = Audio.Voices.list_built_in client ~api_key in
  let* custom = Audio.Voices.list_custom client ~api_key ~limit:100 () in
  Eta.Effect.pure (built_in, custom)
```

Custom voices are read-only discovery (`list` / `get` / `custom_audio`). There
is no create, update, or delete surface; `Capabilities.detailed.custom_voice_management`
is `false`.

Streaming STT/TTS WebSockets are in `eta_ai_xai_eio`.

## Realtime codecs and client secrets

`Audio.Realtime` builds sessions and event codecs only. Connection is
`Eta_ai_xai_eio.Audio.Realtime`.

```ocaml
open Eta_ai_xai

let session =
  let format =
    match Audio.Realtime.pcm ~sample_rate:24000 with
    | Ok format -> format
    | Error error -> failwith (Format.asprintf "%a" Error.pp error)
  in
  match
    Audio.Realtime.session ~model:"grok-voice-latest" ~voice:"eve"
      ~input_audio:
        {
          format;
          transport = Audio.Realtime.Json;
          transcription =
            Some { language_hint = Some "en"; keyterms = [ "Eta" ] };
        }
      ~output_audio:
        {
          format = Audio.Realtime.opus;
          transport = Audio.Realtime.Binary;
          speed = None;
        }
      ()
  with
  | Ok session -> session
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let mint_secret client ~api_key =
  Audio.Realtime.create_client_secret client ~api_key ~expires_after_s:3600

(* Codecs for application-owned loops *)
let _ =
  Audio.Realtime.client_event_message Audio.Realtime.Input_audio_buffer_commit
let decode message = Audio.Realtime.decode_server_event message
```

- `expires_after_s` must be in `1 .. 3600`.
- SIP / phone call attach uses an inference API key plus `call_id` on the Eio
  connector (`connect_api_key ~call_id`). There is no phone provisioning or call
  control API here (`phone_management` and `call_control` are `false`).

## Errors and redaction

```ocaml
let handle = function
  | Eta_ai_xai.Error.Http err -> (* transport *) ignore err
  | Provider { status; payload; raw_body; _ } ->
      ignore (status, payload.message, payload.code, raw_body)
  | Unknown_response { status; raw_body; _ } -> ignore (status, raw_body)
  | Decode { message; raw_body } -> ignore (message, raw_body)
  | Invalid_request message -> ignore message

let project error = Eta_ai_xai.Error.to_ai_error error
```

Failures keep status, headers, and body when the provider returned them.
`to_ai_error` is an explicit neutral projection; lossless bodies remain on the
provider error's `raw` field. Local validation is `Invalid_request`, never
"feature unavailable".

## Explicit non-features

| Surface | Status |
| --- | --- |
| Live Translation | `Capabilities.detailed.live_translation = Unavailable` |
| Custom voice create/update/delete | not implemented |
| Phone number provisioning / call control | not implemented |
| Chat Completions path on `provider` | rejected as unsupported |
| Embeddings / video generation runners | catalogs only |
| Eio WebSocket connect | `eta_ai_xai_eio` |
| JS / js_of_ocaml adapter | none |

## Limits (enforced in this package)

| Rule | Bound |
| --- | --- |
| Responses tools | at most 128 |
| Unary TTS `text` | at most 15_000 characters, valid UTF-8 |
| STT/TTS sample rates | 8000, 16000, 22050, 24000, 44100, 48000 |
| TTS MP3 bit rates | 32000, 64000, 96000, 128000, 192000 |
| File / public-url `expires_after_s` | 3600 .. 2592000 |
| Realtime client-secret TTL | 1 .. 3600 seconds |
| Realtime PCM sample rates | 8000, 16000, 22050, 24000, 32000, 44100, 48000 |
| HTTP SSE reassembly buffer | 1_048_576 bytes |
| Custom voice reference audio / TTS body reads | up to 128 MiB |
| Neutral `Json_schema` via `of_eta_ai` | rejected (xAI schema has no name/strict pair); use typed `Responses.Json_schema` JSON directly |
| Neutral `service_tier` | `"default"` / `"priority"` / `None` only |

## Tradeoffs

- Transport-neutral codecs stay usable from any `Eta_http.Client.t` backend;
  WebSocket lifecycle stays in a separate Eio package.
- SSE stream events stay coarse (`Done` / `Unknown_event`) until a richer typed
  SSE map is implemented; WebSocket Responses is the richer streaming path.
- Applications keep tool loops and stored IDs. The library will not invent a
  hidden agent runtime.

## Development

```sh
nix develop -c dune runtest test/ai/xai --force
nix develop -c dune build @install
nix develop -c dune runtest --force
```

Without Nix, after `opam install . --deps-only --with-test`:

```sh
dune runtest test/ai/xai --force
```

Offline fixtures under `test/ai/xai/fixtures` prove codecs and HTTP integration.
They do not prove live xAI service behavior. Live reach requires an API key and
is outside the default gate.

Eio WebSocket docs and tests: `lib/ai/xai_eio/README.md`, `test/ai/xai_eio`.
