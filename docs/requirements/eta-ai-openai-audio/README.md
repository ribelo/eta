# Eta OpenAI audio requirements

This directory indexes the desired-state capability requirements for the complete
publicly documented OpenAI audio surface. It covers generally available, preview,
and restricted-access contracts, but never undocumented or inferred operations.

## Capability notes

- [[package-boundary]] — package, dependency, type-ownership, and public-surface boundaries.
- [[cross-provider]] — common Eta AI vocabulary and explicit OpenAI/xAI bridges.
- [[speech-generation]] — buffered and streaming text-to-speech.
- [[file-transcription]] — buffered, diarized, verbose, and streamed file transcription.
- [[batch-translation]] — completed-audio translation into English.
- [[chat-audio]] — Chat Completions audio input and output.
- [[realtime-architecture]] — Conversation, Transcription, and Translation protocol topology.
- [[realtime-transcription]] — live and committed-turn transcription sessions.
- [[realtime-translation]] — continuous translated audio and transcripts.
- [[realtime-control]] — client secrets, WebRTC setup, call control, and SIP lifecycle.
- [[custom-voices]] — restricted voice-consent management and voice creation.
- [[streaming-lifecycle]] — pull ownership, cleanup, finish, and abort boundaries.
- [[errors-validation]] — nominal errors, unknown-wire preservation, and validation.
- [[observability]] — provider audio telemetry and content exclusion.

## Proposed verification seams

These are planning notes, not requirements:

- Verify every REST method, path, query, header, JSON body, multipart field, and binary response with recording HTTP clients and first-party-derived fixtures.
- Exercise buffered audio, raw chunked audio, Speech SSE, and transcription SSE independently at their public pull-stream seams.
- Run one shared lifecycle suite against Conversation, Transcription, and Translation Eio connections while retaining protocol-specific state-machine tests.
- Cover WebSocket fragmentation, malformed text and binary frames, unknown events, concurrent use, cancellation, finish/drain, abort, and release counters.
- Test WebRTC SDP and SIP/call-control operations at the transport-neutral request/response seam without requiring browser state.
- Inspect telemetry using secret, transcript, prompt, and audio sentinels to prove content exclusion and nested HTTP-span suppression.
- Reserve authenticated canaries for restricted custom-voice eligibility and provider behavior that static contracts cannot establish.
