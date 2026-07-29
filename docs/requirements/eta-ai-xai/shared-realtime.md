---
kind: requirement
---
# Shared Realtime provider contract

## Intent

Provide one codec and transport lifecycle shape while retaining each
provider's lossless Realtime session and event vocabulary.

## Requirements

- Eta AI shall expose a provider-neutral Realtime codec and transport interface with provider-specific session, client-event, server-event, and error types. ^airealtime-02ky
- The OpenAI and xAI Realtime providers shall retain separate lossless session and event types behind the shared interface. ^airealtime-5xcr
- The shared Realtime interface shall parameterize each provider's accepted session fields and events through provider-specific types. ^airealtime-xem8
- The Eio Realtime transport interface shall expose scoped connection, typed send, typed event-stream, and close operations through one lifecycle shape. ^airealtime-nfad
- When a provider supports binary WebSocket messages, the shared Realtime transport interface shall permit typed binary send and receive behavior. ^airealtime-6gv2
- The shared Realtime interface shall represent streaming speech-to-text with a protocol type distinct from conversational Realtime. ^airealtime-u580
- The shared Realtime interface shall represent streaming text-to-speech with a protocol type distinct from conversational Realtime. ^airealtime-zwge
- The shared Realtime interface shall represent Responses WebSocket mode with a protocol type distinct from conversational Realtime. ^airealtime-32fe
