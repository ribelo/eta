---
kind: requirement
---
# xAI Realtime speech

## Intent

Expose xAI speech-to-speech as a scoped typed protocol while applications own
conversation state and tool execution.

## Requirements

- The xAI Realtime session type shall represent `instructions`, `model`, `reasoning.effort`, and `voice`. ^xairt-fjv5
- The xAI Realtime tool type shall represent function tools. ^xairt-pxi5
- The xAI Realtime tool type shall represent web-search tools. ^xairt-2vq8
- The xAI Realtime tool type shall represent X-search tools. ^xairt-w2io
- The xAI Realtime tool type shall represent file-search tools. ^xairt-a9t9
- The xAI Realtime tool type shall represent MCP tools. ^xairt-qh81
- The xAI provider shall keep Realtime tools distinct from Responses tools while reusing shared schemas for overlapping tool forms. ^xairt-tuno
- The xAI Realtime session type shall represent `turn_detection.type`, `threshold`, `silence_duration_ms`, `prefix_padding_ms`, and `idle_timeout_ms`. ^xairt-ouxn
- The xAI Realtime session type shall represent `resumption.enabled` and the audio-only `replace` map. ^xairt-zrks
- The xAI Realtime session type shall represent input transcription `language_hint` and `keyterms`. ^xairt-sfeb
- The xAI Realtime audio type shall represent `audio/pcm`, `audio/pcmu`, `audio/pcma`, and `audio/opus`. ^xairt-yhm2
- When a caller selects `audio/pcmu`, the xAI Realtime audio type shall require 8000 Hz. ^xairt-tkis
- When a caller selects `audio/pcma`, the xAI Realtime audio type shall require 8000 Hz. ^xairt-q2pj
- When a caller selects `audio/opus`, the xAI Realtime audio type shall require 24000 Hz mono audio. ^xairt-r2oo
- When a caller selects `audio/pcm`, the xAI Realtime audio type shall accept 8000, 16000, 22050, 24000, 32000, 44100, or 48000 Hz. ^xairt-35ni
- The xAI Realtime session type shall represent JSON and binary input and output audio transports. ^xairt-yyoh
- The xAI Realtime session type shall represent output speed from 0.7 through 1.5 inclusive. ^xairt-wqji
- When a caller creates an ephemeral Realtime client secret, the xAI provider shall send `POST /v1/realtime/client_secrets` with a redacted inference API key. ^xairt-u0gn
- If an ephemeral Realtime client-secret TTL exceeds 3600 seconds, then the xAI provider shall reject it before transport. ^xairt-r25l
- The xAI Eio transport shall expose a Realtime connection operation that accepts an inference API key. ^xairt-edx9
- The xAI Eio transport shall expose a Realtime connection operation that accepts an ephemeral client secret. ^xairt-1pv3
- When a caller connects with a SIP `call_id`, the xAI Eio transport shall authenticate with an inference API key. ^xairt-bnaw
- If a caller supplies an ephemeral client secret with a SIP `call_id`, then the xAI Eio transport shall reject the connection before transport. ^xairt-7t3a
- While configured for JSON audio transport, the xAI Eio transport shall send audio through `input_audio_buffer.append` with base64 JSON data. ^xairt-dite
- While configured for binary audio transport, the xAI Eio transport shall send raw codec bytes as binary WebSocket frames. ^xairt-xgpp
- While a Realtime connection is open, the xAI Eio transport shall serialize sends. ^xairt-swoy
- While a Realtime connection is open, the xAI Eio transport shall expose one typed pull event stream. ^xairt-v6m0
- When a Realtime connection closes, the xAI Eio transport shall close the WebSocket and release its event stream exactly once. ^xairt-eutb
- When a Realtime connection fails, the xAI Eio transport shall close the WebSocket and release its event stream exactly once. ^xairt-webr
- When a Realtime connection is cancelled, the xAI Eio transport shall close the WebSocket and release its event stream exactly once. ^xairt-74dg
- When a caller updates a Realtime session, the xAI provider shall encode a `session.update` client event. ^xairt-ix1l
- When a caller appends input audio, the xAI provider shall encode an `input_audio_buffer.append` client event. ^xairt-t5ie
- When a caller commits input audio, the xAI provider shall encode an `input_audio_buffer.commit` client event. ^xairt-qyz3
- When a caller clears input audio, the xAI provider shall encode an `input_audio_buffer.clear` client event. ^xairt-s2k1
- When a caller creates a conversation item, the xAI provider shall encode a `conversation.item.create` client event. ^xairt-tczg
- When a caller deletes a conversation item, the xAI provider shall encode a `conversation.item.delete` client event. ^xairt-75yu
- When a caller truncates a conversation item, the xAI provider shall encode a `conversation.item.truncate` client event. ^xairt-dpki
- When a caller creates a response, the xAI provider shall encode a `response.create` client event. ^xairt-ujsx
- When a caller cancels a response, the xAI provider shall encode a `response.cancel` client event. ^xairt-et1h
- When xAI emits `session.created`, the xAI provider shall decode it into a typed server event. ^xairt-2zle
- When xAI emits `session.updated`, the xAI provider shall decode it into a typed server event. ^xairt-569h
- When xAI emits `conversation.created`, the xAI provider shall decode it into a typed server event. ^xairt-29wn
- When xAI emits `conversation.item.added`, the xAI provider shall decode it into a typed server event. ^xairt-86zx
- When xAI emits `conversation.item.deleted`, the xAI provider shall decode it into a typed server event. ^xairt-4fvf
- When xAI emits `conversation.item.truncated`, the xAI provider shall decode it into a typed server event. ^xairt-w8yj
- When xAI emits `input_audio_buffer.speech_started`, the xAI provider shall decode it into a typed server event. ^xairt-52vr
- When xAI emits `input_audio_buffer.speech_stopped`, the xAI provider shall decode it into a typed server event. ^xairt-6aq0
- When xAI emits `input_audio_buffer.committed`, the xAI provider shall decode it into a typed server event. ^xairt-wk85
- When xAI emits `input_audio_buffer.cleared`, the xAI provider shall decode it into a typed server event. ^xairt-oose
- When xAI emits `input_audio_buffer.timeout_triggered`, the xAI provider shall decode it into a typed server event. ^xairt-5g3o
- When xAI emits `conversation.item.input_audio_transcription.completed`, the xAI provider shall decode it into a typed server event. ^xairt-ucx1
- When xAI emits `conversation.item.input_audio_transcription.updated`, the xAI provider shall decode it as a cumulative transcript server event. ^xairt-jjwl
- When xAI emits `response.created`, the xAI provider shall decode it into a typed server event. ^xairt-xxg9
- When xAI emits `response.output_audio.delta`, the xAI provider shall decode its base64 audio into a typed server event. ^xairt-px9d
- When xAI emits `response.output_audio.done`, the xAI provider shall decode it into a typed server event. ^xairt-3d1n
- When xAI emits `response.output_audio_transcript.delta`, the xAI provider shall decode it into a typed server event. ^xairt-gpfd
- When xAI emits `response.output_audio_transcript.done`, the xAI provider shall decode it into a typed server event. ^xairt-5y42
- When xAI emits `response.text.delta`, the xAI provider shall decode it into a typed server event. ^xairt-wc99
- When xAI emits `response.output_text.delta`, the xAI provider shall decode it into a typed server event. ^xairt-mp37
- When xAI emits `response.done`, the xAI provider shall decode it into a typed server event. ^xairt-m9g0
- When xAI emits `response.done`, the xAI provider shall classify it as a terminal response event. ^xairt-nzcz
- When xAI emits `input_audio_buffer.dtmf_event_received`, the xAI provider shall decode it into a typed SIP server event. ^xairt-b92m
- When xAI emits `error`, the xAI provider shall decode it into a typed error server event. ^xairt-s4o1
- If xAI emits an unknown Realtime event, then the xAI provider shall preserve it as raw JSON in an `Unknown` variant. ^xairt-fp57
- When xAI requests a function call, the xAI provider shall return the typed call without executing application code. ^xairt-y06g
- When an application submits a function result, the xAI provider shall encode it as a typed `function_call_output` conversation item. ^xairt-wots
- The xAI Eio transport shall retain only protocol state required for connection safety. ^xairt-s34d

## Open questions

- Does `POST /v1/realtime/client_secrets` accept a `session` binding?
- What are the exact event names and payload schemas for Realtime output-item,
  content-part, function-call, MCP, usage, and resumption lifecycle events?
- Which `error` types are recoverable, and which terminate the connection?
