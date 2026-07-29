---
kind: requirement
---
# xAI text to speech

## Intent

Support unary and multi-utterance streaming synthesis while preserving audio,
alignment, framing, and connection lifecycle.

## Requirements

- When a caller submits unary text to speech, the xAI provider shall represent `text`, `language`, `voice_id`, `output_format`, `speed`, `optimize_streaming_latency`, `text_normalization`, and `with_timestamps`. ^xaitts-wfo1
- When a caller selects unary latency optimization, the xAI provider shall accept level 0 or level 1. ^xaitts-3gtl
- When a caller selects a text-to-speech codec, the xAI provider shall accept `mp3`, `wav`, `pcm`, `mulaw`, or `alaw`. ^xaitts-6c22
- When a caller selects a text-to-speech sample rate, the xAI provider shall accept 8000, 16000, 22050, 24000, 44100, or 48000 Hz. ^xaitts-3s49
- When a caller selects an MP3 bit rate, the xAI provider shall accept 32000, 64000, 96000, 128000, or 192000 bits per second. ^xaitts-36y7
- When a caller selects text-to-speech speed, the xAI provider shall accept values from 0.7 through 1.5 inclusive. ^xaitts-9hog
- If unary text exceeds 15,000 characters, then the xAI provider shall reject the request before transport. ^xaitts-jo6b
- When unary text to speech returns raw audio, the xAI provider shall preserve the response bytes and content type in a typed audio result. ^xaitts-b7vv
- When unary text to speech returns timestamped audio, the xAI provider shall decode the base64 audio, content type, duration, and `graph_chars`. ^xaitts-2xcr
- When unary text to speech returns timestamped audio, the xAI provider shall preserve `graph_times` without loss. ^xaitts-m0n3
- The unary text-to-speech result shall distinguish raw audio from timestamped audio with an explicit variant. ^xaitts-ho68
- The xAI Eio transport shall expose streaming text to speech as a protocol distinct from Realtime speech. ^xaitts-f5w0
- The xAI Eio transport shall expose streaming text to speech as a protocol distinct from streaming speech to text. ^xaitts-1cyg
- When opening streaming text to speech, the xAI Eio transport shall represent `language`, `voice`, `codec`, `sample_rate`, `bit_rate`, `speed`, `optimize_streaming_latency`, `text_normalization`, and `with_timestamps` as query parameters. ^xaitts-4jh3
- When a caller selects streaming latency optimization, the xAI Eio transport shall accept level 0 or level 1. ^xaitts-bsz3
- While a streaming text-to-speech connection is open, when a caller supplies text, the xAI Eio transport shall send a `text.delta` client message. ^xaitts-f4ik
- If a `text.delta` contains more than 15,000 characters, then the xAI Eio transport shall reject it before sending. ^xaitts-fwob
- While a streaming text-to-speech connection is open, when a caller completes an utterance, the xAI Eio transport shall send a `text.done` client message. ^xaitts-wpzm
- While a streaming text-to-speech connection is open, when a caller clears buffered text, the xAI Eio transport shall send a `text.clear` client message. ^xaitts-bk5a
- When xAI emits `audio.delta`, the xAI Eio transport shall decode its base64 `delta` into a typed audio event. ^xaitts-vxb2
- When xAI includes timestamp data in `audio.delta`, the xAI Eio transport shall preserve the timestamp fields in that audio-delta event. ^xaitts-1owf
- When xAI emits `audio.done`, the xAI Eio transport shall decode it into a typed utterance-completion event. ^xaitts-c3u5
- When xAI emits `audio.clear`, the xAI Eio transport shall decode it into a typed audio-clear event. ^xaitts-f583
- When xAI emits `error`, the xAI Eio transport shall decode it into a typed error event. ^xaitts-edr7
- When xAI emits `audio.done`, the xAI Eio transport shall keep the connection open. ^xaitts-86ko
- While a streaming text-to-speech connection remains reusable following `audio.done`, when a caller supplies a new text delta, the xAI Eio transport shall begin a new utterance. ^xaitts-9573
- If xAI emits an unknown streaming text-to-speech event, then the xAI Eio transport shall preserve the event as raw JSON in an `Unknown` variant. ^xaitts-3bdl

## Open questions

- Does xAI support `optimize_streaming_latency=2` for unary requests,
  streaming connections, or both?
- Is unary `audio_timestamps.graph_times` encoded as arrays of
  `[start, end]` pairs or as objects with `start` and `end` fields?
