---
kind: requirement
---
# OpenAI speech generation

## Intent

Generate spoken audio from bounded text while exposing buffered audio, raw
chunked audio, and Speech SSE as distinct typed protocols.

## Requirements

- When a caller creates speech, the OpenAI provider shall send `POST /v1/audio/speech`. ^oatts-4f7w
- The OpenAI speech request shall represent `input`, `model`, `voice`, `instructions`, `response_format`, `speed`, and `stream_format`. ^oatts-l4uo
- The OpenAI speech request shall distinguish a built-in voice from a custom voice object containing a voice ID. ^oatts-thhq
- The OpenAI speech response-format type shall represent `mp3`, `opus`, `aac`, `flac`, `wav`, and `pcm`. ^oatts-tco2
- The OpenAI speech stream-format type shall distinguish raw `audio` streaming from `sse` event streaming. ^oatts-ts26
- The OpenAI Speech module shall expose separate `create`, `stream_audio`, and `stream_events` operations. ^oatts-p95d
- When buffered speech succeeds, the OpenAI provider shall preserve the response audio bytes and content type. ^oatts-x0xu
- When raw streaming speech succeeds, the OpenAI provider shall expose an OpenAI-owned abstract pull stream of audio chunks. ^oatts-l7gr
- When Speech SSE emits a documented event, the OpenAI provider shall decode it into its corresponding typed event. ^oatts-mtin
- If Speech SSE emits an undocumented event type, then the OpenAI provider shall preserve its type and complete JSON in an `Unknown` event. ^oatts-q0hi
- When a caller selects a custom voice, the OpenAI provider shall encode the custom voice ID using the documented `{ "id": ... }` object form. ^oatts-7u4k
- The OpenAI speech model type shall represent documented TTS model identifiers without preventing future provider model identifiers. ^oatts-gbnd
- The OpenAI speech API shall expose a convenience operation that collects a streaming audio response only when the caller explicitly chooses collection. ^oatts-snbf
- The OpenAI speech collection convenience shall accept a caller-supplied maximum byte limit. ^oatts-7c46

## Open questions
- The published speech reference declares `stream_format=sse` without event schemas, so the concrete Speech SSE event types are unresolved and need an authenticated canary.
