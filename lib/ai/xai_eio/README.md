# eta_ai_xai_eio

Native Eio WebSocket transports for the xAI provider.

This package connects, sends, receives, and closes four xAI WebSocket surfaces
on top of codecs from `eta_ai_xai`. It does not re-implement HTTP unary APIs and
does not own application conversation state or tool execution.

## Why it is separate

`eta_ai_xai` stays transport-neutral (no `eio` dependency). WebSocket lifecycle,
TLS, backpressure fences, and switch-scoped cancellation belong beside
`eta_http_eio`, not in the codec package. The same split is used for OpenAI
Realtime (`eta_ai_openai` + `eta_ai_openai_realtime_eio`).

## Package boundary

| Package | Owns |
| --- | --- |
| `eta_ai_xai` | Requests, decoders, redacted secrets, unary HTTP runners, Realtime codecs |
| `eta_ai_xai_eio` | `Responses_ws`, `Realtime`, `Audio.Speech_to_text`, `Audio.Text_to_speech` |
| Application | Switch, net, audio/text buffers, tool handlers, reconnect policy |

Depends on: `eta`, `eta_ai`, `eta_ai_xai`, `eta_http`, `eta_http_eio`,
`eta_redacted`, `eta_stream`, `base64`, `eio`.

There is no JS WebSocket adapter for xAI.

`Eta_ai_xai_eio.capabilities` flips the base capability record to mark
Responses WebSocket and streaming STT/TTS as available.

## Shared setup

```ocaml
let api_key =
  match Sys.getenv_opt "XAI_API_KEY" with
  | Some value -> Eta_ai.api_key value
  | None -> failwith "XAI_API_KEY is required"

let with_xai env f =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
  in
  f ~sw ~net ~rt
```

Connections take `sw` and `net`. Closing the switch closes active sockets.
Optional `~ca_file` adds a PEM CA bundle for TLS.

## Responses WebSocket

Long-lived Responses socket: connect once, `create` or `warmup` requests, pull
`Eta_ai_xai.Responses.stream_event` values, then `close`.

```ocaml
open Eta_ai_xai_eio

let request : Eta_ai_xai.Responses.request =
  {
    model = "grok-4.5";
    input = Eta_ai_xai.Responses.Text_input "hello";
    instructions = None;
    previous_response_id = None;
    store = Some false;
    include_ = [];
    stream = true;
    tools = [];
    tool_choice = None;
    parallel_tool_calls = None;
    max_turns = None;
    max_output_tokens = None;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    text = None;
    reasoning = None;
    reasoning_effort = None;
    search_parameters = None;
    service_tier = None;
    user = None;
    prompt_cache_key = None;
  }

let run_responses ~sw ~net ~rt ~api_key =
  let open Eta.Syntax in
  let effect =
    let* conn = Responses_ws.connect ~sw ~net ~api_key () in
    let* () = Responses_ws.create conn request in
    let rec loop () =
      let* event = Responses_ws.read_event conn in
      match event with
      | None | Some Eta_ai_xai.Responses.Done -> Responses_ws.close conn
      | Some (Eta_ai_xai.Responses.Unknown_event _) -> loop ()
    in
    loop ()
  in
  Eta_eio.Runtime.run rt effect
```

- Default `max_age` is 25 minutes. Values must be `> 0` and `<= 25` minutes;
  larger values fail with `` `Invalid_request `` before connect.
- `create` sends a generating request; `warmup` encodes the same shape with
  `generate=false`.
- Provider errors surface as `` `Provider_error `` with optional codes
  `Previous_response_not_found` and `Websocket_connection_limit_reached`.
- Provider may reject additional work with
  `Websocket_connection_limit_reached`; treat that as a hard connection limit,
  not a silent queue.

## Realtime

Conversational speech WebSocket using `Eta_ai_xai.Audio.Realtime.session` and event
codecs.

```ocaml
open Eta_ai_xai_eio

let session =
  let format =
    match Eta_ai_xai.Audio.Realtime.pcm ~sample_rate:24000 with
    | Ok format -> format
    | Error error ->
        failwith (Format.asprintf "%a" Eta_ai_xai.Error.pp error)
  in
  match
    Eta_ai_xai.Audio.Realtime.session ~model:"grok-voice-latest"
      ~input_audio:
        {
          format;
          transport = Eta_ai_xai.Audio.Realtime.Json;
          transcription = None;
        }
      ~output_audio:
        {
          format;
          transport = Eta_ai_xai.Audio.Realtime.Json;
          speed = None;
        }
      ()
  with
  | Ok session -> session
  | Error error ->
      failwith (Format.asprintf "%a" Eta_ai_xai.Error.pp error)

let run_realtime_api_key ~sw ~net ~rt ~api_key =
  let open Eta.Syntax in
  let effect =
    let* conn =
      Audio.Realtime.connect_api_key ~sw ~net ~api_key ~session ()
    in
    let* () = Audio.Realtime.send_audio conn (Bytes.create 320) in
    let* () =
      Audio.Realtime.send_event conn
        Eta_ai_xai.Audio.Realtime.Input_audio_buffer_commit
    in
    let* event = Audio.Realtime.read_event conn in
    ignore event;
    Audio.Realtime.close conn
  in
  Eta_eio.Runtime.run rt effect

let run_realtime_ephemeral ~sw ~net ~rt ~secret =
  let open Eta.Syntax in
  let effect =
    let* conn =
      Audio.Realtime.connect_ephemeral ~sw ~net ~secret ~session ()
    in
    Audio.Realtime.close conn
  in
  Eta_eio.Runtime.run rt effect

(* SIP / existing call attach: inference API key + call_id query only *)
let run_sip ~sw ~net ~rt ~api_key ~call_id =
  let open Eta.Syntax in
  let effect =
    let* conn =
      Audio.Realtime.connect_api_key ~sw ~net ~api_key ~session ~call_id ()
    in
    Audio.Realtime.close conn
  in
  Eta_eio.Runtime.run rt effect
```

- `connect_api_key` authorizes with the inference API key (optional
  `call_id` / `conversation_id` query params).
- `connect_ephemeral` authorizes with a redacted client secret from
  `Eta_ai_xai.Audio.Realtime.create_client_secret`. Secrets with CR/LF fail before
  network I/O.
- `send_audio` chooses JSON base64 vs binary frames from the session transport.
- Function-call server events are delivered as typed
  `Response_function_call_arguments_done`; the application executes tools and
  replies with `Conversation_item_create (Function_call_output ...)`.
- No Live Translation socket, phone provisioning, or call-control methods.

`Audio.Realtime.Transport` implements `Eta_ai.Realtime.Transport` for generic
session runners.

## Streaming speech-to-text

```ocaml
open Eta_ai_xai_eio

let config : Audio.Speech_to_text.config =
  {
    sample_rate = Some 16000;
    encoding = Some Audio.Speech_to_text.Pcm;
    interim_results = Some true;
    endpointing = Some 250;
    language = Some "en";
    diarize = Some true;
    filler_words = Some false;
    multichannel = None;
    channels = None;
    keyterm = [ "Eta" ];
    smart_turn = Some 0.7;
    smart_turn_timeout = Some 2;
    vad_threshold = Some 0.08;
  }

let run_stt ~sw ~net ~rt ~api_key =
  let open Eta.Syntax in
  let effect =
    let* conn = Audio.Speech_to_text.connect ~sw ~net ~api_key config in
    let* () = Audio.Speech_to_text.send_audio conn (Bytes.create 640) in
    let* () = Audio.Speech_to_text.finalize conn in
    let* () = Audio.Speech_to_text.audio_done conn in
    let rec loop () =
      let* event = Audio.Speech_to_text.read_event conn in
      match event with
      | None | Some (Audio.Speech_to_text.Transcript_done _) ->
          Audio.Speech_to_text.close conn
      | Some _ -> loop ()
    in
    loop ()
  in
  Eta_eio.Runtime.run rt effect
```

Lifecycle fences:

1. Binary audio may buffer until `transcript.created`.
2. `finalize ?channel` ends input; when `channel` is set it must satisfy
   `0 <= channel < expected_channels` (`expected_channels` is the configured
   multichannel count, otherwise `1`).
3. `audio_done` ends the stream after finals.
4. Pending pre-ready audio is capped at 1_048_576 bytes and 1024 items;
   exceeding either fails with `` `Protocol "streaming STT pre-ready audio limit exceeded" ``.

Sample rates: 8000, 16000, 22050, 24000, 44100, 48000. Multichannel requires
`multichannel = Some true` and `channels` in `2 .. 8`.

## Streaming text-to-speech

```ocaml
open Eta_ai_xai_eio

let config : Audio.Text_to_speech.config =
  {
    language = "en";
    voice = "eve";
    codec = Some Audio.Text_to_speech.Mp3;
    sample_rate = Some 24000;
    bit_rate = Some 128000;
    speed = Some 1.0;
    optimize_streaming_latency = Some 1;
    text_normalization = None;
    with_timestamps = Some false;
  }

let run_tts ~sw ~net ~rt ~api_key =
  let open Eta.Syntax in
  let effect =
    let* conn = Audio.Text_to_speech.connect ~sw ~net ~api_key config in
    let* () = Audio.Text_to_speech.text_delta conn "hello from Eta" in
    let* () = Audio.Text_to_speech.text_done conn in
    let rec loop () =
      let* event = Audio.Text_to_speech.read_event conn in
      match event with
      | None | Some (Audio.Text_to_speech.Audio_done _) -> Audio.Text_to_speech.close conn
      | Some (Audio.Text_to_speech.Audio_delta _) -> loop ()
      | Some (Audio.Text_to_speech.Audio_clear _) -> loop ()
      | Some (Audio.Text_to_speech.Error _) -> Audio.Text_to_speech.close conn
      | Some (Audio.Text_to_speech.Unknown _) -> loop ()
    in
    loop ()
  in
  Eta_eio.Runtime.run rt effect
```

- Each `text.delta` must be valid UTF-8 and at most 15_000 characters.
- After `text_done`, further `text_delta` fails until a new cycle (or
  `text_clear` where supported by the server).
- Sample rates and MP3 bit rates match the unary TTS validators in `eta_ai_xai`.

## Errors

Transport errors are a polymorphic variant shared across modules:

```ocaml
[ Eta_http_eio.Ws.Client.ws_error
| `Decode of string
| `Invalid_request of string
| `Xai_error of Eta_ai_xai.Error.t
]
```

`Responses_ws` adds `` `Provider_error of provider_error ``. Authorization
headers use redacted keys; secrets are not copied into observability attribute
values by the transport helpers.

## Limits and footguns

| Topic | Behavior |
| --- | --- |
| Responses `max_age` | default 25 min; must be in `(0, 25]` minutes |
| STT pending audio | 1 MiB and 1024 items before `transcript.created` |
| TTS `text.delta` | ≤ 15_000 UTF-8 characters per delta |
| SIP | `connect_api_key ~call_id` only; no number buy/release APIs |
| Live Translation | unavailable (same as `eta_ai_xai`) |
| Custom voice mutation | not exposed; pass an existing `voice` / `voice_id` |
| Switch release | dropping `sw` closes sockets; always `close` when finished early |
| Application state | reconnect, buffering, and tool loops stay outside this package |

## Development

```sh
nix develop -c dune runtest test/ai/xai_eio --force
nix develop -c dune runtest test/ai/xai --force
nix develop -c dune build @install
```

Without Nix, after `opam install . --deps-only --with-test`:

```sh
dune runtest test/ai/xai_eio --force
```

Tests use local TLS mocks (`eio.mock`); they do not call live xAI. Codec and
HTTP coverage remains under `test/ai/xai`.
