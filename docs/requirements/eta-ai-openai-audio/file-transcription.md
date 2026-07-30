---
kind: requirement
---
# OpenAI file transcription

## Intent

Transcribe completed recordings through the full request and response-format
surface without conflating buffered files, streamed transcript output, and live
Realtime audio.

## Requirements

- When a caller creates a file transcription, the OpenAI provider shall send `POST /v1/audio/transcriptions` as multipart form data. ^oastt-2asc
- The OpenAI file-transcription request shall accept a provider-neutral upload source supporting bytes and pull streaming. ^oastt-59ol
- The OpenAI file-transcription upload source shall represent optional known length and replayability. ^oastt-bvq8
- The OpenAI file-transcription request shall represent `file`, `model`, `prompt`, `response_format`, `temperature`, `stream`, `include`, `timestamp_granularities`, `chunking_strategy`, `known_speaker_names`, `known_speaker_references`, `keywords`, `language`, and `languages`. ^oastt-3y32
- The OpenAI file-transcription request shall preserve repeated multipart fields for keywords, languages, timestamp granularities, known-speaker names, and known-speaker references. ^oastt-ffor
- The OpenAI file-transcription result shall distinguish JSON, verbose JSON, and diarized JSON responses with an explicit variant. ^oastt-if8v
- When OpenAI returns a JSON transcription, the OpenAI provider shall preserve text, detected languages, log probabilities, usage, and complete raw JSON. ^oastt-efp8
- When OpenAI returns token usage, the OpenAI provider shall preserve input tokens, output tokens, total tokens, audio-token details, and text-token details. ^oastt-dp0c
- When OpenAI returns duration usage, the OpenAI provider shall preserve billed audio seconds. ^oastt-sgcd
- When OpenAI returns a verbose transcription, the OpenAI provider shall preserve text, input language, duration, segments, words, usage, and complete raw JSON. ^oastt-8j16
- When OpenAI returns a transcription segment, the OpenAI provider shall preserve its identifiers, seek offset, timestamps, text, tokens, temperature, average log probability, compression ratio, and no-speech probability. ^oastt-7fk7
- When OpenAI returns a transcription word, the OpenAI provider shall preserve its text and timestamps. ^oastt-b17y
- When OpenAI returns a diarized transcription, the OpenAI provider shall preserve text, duration, task, usage, speaker-labeled segments, and complete raw JSON. ^oastt-8ia0
- When OpenAI returns a diarized segment, the OpenAI provider shall preserve its ID, speaker, timestamps, text, type, and complete raw JSON. ^oastt-2h2y
- The OpenAI file-transcription module shall expose buffered creation and streamed-event creation as separate operations. ^oastt-9dx2
- When streamed transcription emits `transcript.text.delta`, the OpenAI provider shall preserve the delta, token log probabilities, optional segment ID, and complete raw JSON in a typed event. ^oastt-zxuv
- When streamed diarization emits `transcript.text.segment`, the OpenAI provider shall preserve the completed speaker segment and complete raw JSON in a typed event. ^oastt-5bhd
- When streamed transcription emits `transcript.text.done`, the OpenAI provider shall preserve the final text, log probabilities, usage, and complete raw JSON in a typed event. ^oastt-8axi
- If streamed transcription emits an undocumented event type, then the OpenAI provider shall preserve its type and complete JSON in an `Unknown` event. ^oastt-ma40
- The OpenAI streamed file-transcription operation shall return an abstract pull stream whose failures use `Eta_ai_openai.Error.t`. ^oastt-nsnl
- The OpenAI provider shall keep file-transcription streaming distinct from Realtime transcription. ^oastt-dzn7
