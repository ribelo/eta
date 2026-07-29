---
kind: requirement
---
# xAI speech to text

## Intent

Support unary and streaming xAI transcription with typed media, transcript,
finality, and lifecycle boundaries.

## Requirements

- The xAI speech-to-text request shall require exactly one audio source consisting of an uploaded binary file or a remote URL. ^xaistt-9ncy
- If an uploaded speech-to-text file exceeds xAI's documented 500 MB limit, then the xAI provider shall reject it before transport. ^xaistt-bbo1
- When a caller submits unary speech to text, the xAI provider shall represent `audio_format`, `sample_rate`, `language`, `format`, `multichannel`, `channels`, `diarize`, `keyterm`, `filler_words`, and `vad_threshold`. ^xaistt-1j69
- When a caller declares raw speech-to-text audio, the xAI provider shall accept `pcm`, `mulaw`, or `alaw` as the audio format. ^xaistt-tlyz
- When a caller declares raw speech-to-text audio, the xAI speech-to-text request shall require a sample rate of 8000, 16000, 22050, 24000, 44100, or 48000 Hz. ^xaistt-yi4h
- When a caller uploads unary speech, the xAI provider shall place all option fields before the file in the multipart body. ^xaistt-vjqk
- When xAI returns a unary transcript, the xAI provider shall preserve `text`, `language`, `duration`, `words`, and `channels`. ^xaistt-fmd4
- When xAI returns a transcript word, the xAI provider shall preserve `text`, `start`, `end`, `confidence`, and `speaker`. ^xaistt-atxf
- The xAI Eio transport shall expose streaming speech to text as a protocol distinct from Realtime speech. ^xaistt-afb9
- The xAI Eio transport shall expose streaming speech to text as a protocol distinct from streaming text to speech. ^xaistt-7mqs
- When opening streaming speech to text, the xAI Eio transport shall represent `sample_rate`, `encoding`, `interim_results`, `endpointing`, `language`, `diarize`, `filler_words`, `multichannel`, `channels`, `keyterm`, `smart_turn`, `smart_turn_timeout`, and `vad_threshold` as query parameters. ^xaistt-jrej
- While a streaming speech-to-text connection is open, the xAI Eio transport shall send caller-supplied audio as binary WebSocket frames. ^xaistt-7lou
- While a streaming speech-to-text connection awaits `transcript.created`, the xAI Eio transport shall defer caller-supplied audio frames. ^xaistt-579p
- When a caller requests utterance finalization, the xAI Eio transport shall send a `finalize` client message. ^xaistt-9t1s
- When a caller finalizes an utterance, the xAI Eio transport shall keep the streaming speech-to-text connection open. ^xaistt-m2dm
- When a caller signals end of audio, the xAI Eio transport shall send an `audio.done` client message. ^xaistt-9jib
- When a caller sends `audio.done`, the xAI Eio transport shall flush pending audio. ^xaistt-cc5x
- When xAI emits `transcript.done` following the caller's `audio.done`, the xAI Eio transport shall close the connection. ^xaistt-hs0n
- When xAI emits `transcript.created`, the xAI Eio transport shall decode its `id` into a typed event. ^xaistt-spzg
- When xAI emits `transcript.partial`, the xAI Eio transport shall decode `text`, `words`, `is_final`, `speech_final`, `start`, `duration`, `channel_index`, and `end_of_turn_confidence`. ^xaistt-hyt4
- When xAI emits `transcript.done`, the xAI Eio transport shall decode it into a typed completion event. ^xaistt-ydg9
- When xAI emits an `error` message, the xAI Eio transport shall decode `message` into a typed error event. ^xaistt-gw6z
- When `transcript.partial` has `is_final=false` and `speech_final=false`, the xAI Eio transport shall classify the event as interim transcript content. ^xaistt-uepg
- When `transcript.partial` has `is_final=true` and `speech_final=false`, the xAI Eio transport shall classify the event as a locked transcript chunk within an unfinished utterance. ^xaistt-hp1p
- When `transcript.partial` has `is_final=true` and `speech_final=true`, the xAI Eio transport shall classify the event as an utterance-final transcript. ^xaistt-zs6w
- If xAI emits an unknown streaming speech-to-text event, then the xAI Eio transport shall preserve the event as raw JSON in an `Unknown` variant. ^xaistt-fda0

## Open questions

- Is unary response `language` empty, an ISO 639-1 code, or a display name, and
  does setting request `language` affect only inverse text normalization?
- Does the detailed unary API accept WebM?
- Which streaming error types leave the socket open, and which close it?
