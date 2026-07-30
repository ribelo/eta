---
kind: requirement
---
# OpenAI Realtime transcription

## Intent

Transcribe live or explicitly committed audio turns without introducing an
assistant-response lifecycle or conflating live input with completed-file SSE.

## Requirements

- The OpenAI Realtime Transcription module shall represent sessions with `type` equal to `transcription`. ^oartt-tff9
- The OpenAI Realtime Transcription session shall represent input format, transcription model, prompt, keywords, languages, delay, and turn detection. ^oartt-unnl
- The OpenAI Realtime Transcription protocol shall support `gpt-live-transcribe` for continuously arriving audio. ^oartt-y134
- The OpenAI Realtime Transcription protocol shall support `gpt-transcribe` for committed-turn transcription and detected-language output. ^oartt-4o8i
- While a Transcription connection is open, when a caller appends audio, the OpenAI Eio transport shall send `input_audio_buffer.append`. ^oartt-63bk
- While automatic turn detection is disabled, when a caller commits a turn, the OpenAI Eio transport shall send `input_audio_buffer.commit`. ^oartt-bety
- When OpenAI emits `conversation.item.input_audio_transcription.delta`, the OpenAI provider shall preserve item ID, content index, delta, and complete raw JSON in a typed event. ^oartt-v2o4
- When OpenAI emits `conversation.item.input_audio_transcription.completed`, the OpenAI provider shall preserve item ID, content index, final transcript, detected languages when present, and complete raw JSON in a typed event. ^oartt-o19j
- The OpenAI Realtime Transcription event type shall preserve item ID so callers can reconcile completion events that arrive out of turn order. ^oartt-nkg1
- When OpenAI reports no reliable language prediction, the OpenAI provider shall preserve an empty detected-languages list as a successful result. ^oartt-niot
- The OpenAI Realtime Transcription protocol shall remain distinct from file-transcription streaming. ^oartt-29gg
- The OpenAI Realtime Transcription protocol shall not expose speaker diarization as a supported session capability. ^oartt-3ex8
