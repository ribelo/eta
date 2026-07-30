---
kind: requirement
---
# OpenAI Realtime translation

## Intent

Continuously translate incoming speech into target-language audio and transcripts
through OpenAI's dedicated interpreter protocol and graceful drain lifecycle.

## Requirements

- The OpenAI Realtime Translation module shall connect WebSocket sessions through `/v1/realtime/translations`. ^oartr-zaly
- The OpenAI Realtime Translation module shall select the translation model through the WebSocket query. ^oartr-a4ll
- The OpenAI Realtime Translation session shall represent target output language and documented audio configuration. ^oartr-sok5
- The OpenAI Realtime Translation protocol shall remain distinct from assistant Conversation sessions. ^oartr-usqp
- The OpenAI Realtime Translation protocol shall not expose `response.create`. ^oartr-kmdx
- While a Translation connection is open, when a caller appends source audio, the OpenAI Eio transport shall send `session.input_audio_buffer.append`. ^oartr-c2is
- When OpenAI emits `session.output_audio.delta`, the OpenAI provider shall preserve translated audio and complete raw JSON in a typed event. ^oartr-8hwa
- When OpenAI emits `session.output_transcript.delta`, the OpenAI provider shall preserve translated transcript text and complete raw JSON in a typed event. ^oartr-jews
- When OpenAI emits `session.input_transcript.delta`, the OpenAI provider shall preserve source transcript text and complete raw JSON in a typed event. ^oartr-3j7p
- When a caller finishes Translation input, the OpenAI Eio transport shall send `session.close`. ^oartr-g3i5
- While Translation is finishing, the OpenAI Eio transport shall continue delivering pending translated audio and transcript events. ^oartr-lkjk
- When OpenAI emits `session.closed`, the OpenAI Eio transport shall complete graceful Translation finish. ^oartr-zre7
- When OpenAI emits `session.closed`, the OpenAI Eio transport shall close the Translation WebSocket exactly once. ^oartr-59md
- If a caller aborts Translation, then the OpenAI Eio transport shall terminate the WebSocket without waiting for `session.closed`. ^oartr-6hfx
- If a caller aborts Translation, then the OpenAI Eio transport shall release the Translation connection exactly once. ^oartr-9gqb
- The OpenAI Realtime Translation module shall expose client-secret creation for translation sessions. ^oartr-nu18
- The OpenAI Realtime Translation module shall expose WebRTC SDP call setup through the documented translation calls endpoint. ^oartr-a33r
- The OpenAI Realtime Translation protocol shall use `gpt-realtime-translate` as its documented model contract while permitting future provider model identifiers. ^oartr-de4h
