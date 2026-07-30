---
kind: requirement
---
# OpenAI audio streaming lifecycle

## Intent

Provide bounded, backpressured, cancellation-safe ownership for HTTP and WebSocket
audio streams while preserving protocol-specific completion behavior.

## Requirements

- The OpenAI Speech raw-audio stream shall be an OpenAI-owned abstract pull stream. ^oastr-agby
- The OpenAI Speech SSE stream shall be an OpenAI-owned abstract pull stream distinct from the raw-audio stream. ^oastr-ygsw
- The OpenAI file-transcription SSE stream shall be an OpenAI-owned abstract pull stream distinct from Realtime event streams. ^oastr-72w1
- Each OpenAI-owned HTTP pull stream shall map transport failures into `Eta_ai_openai.Error.t`. ^oastr-g432
- When an OpenAI-owned HTTP pull stream reaches normal completion, the stream shall release its response body exactly once. ^oastr-51s9
- When an OpenAI-owned HTTP pull stream fails, the stream shall release its response body exactly once. ^oastr-e7es
- When an OpenAI-owned HTTP pull stream is cancelled, the stream shall release its response body exactly once. ^oastr-vzni
- When stream cleanup also fails, the stream shall retain the triggering provider or transport failure as the primary cause. ^oastr-6is9
- Each OpenAI Eio Realtime connection shall serialize outbound sends. ^oastr-r5x4
- Each OpenAI Eio Realtime connection shall expose typed pull-based event delivery. ^oastr-1gq5
- Each OpenAI Eio Realtime connection shall expose a graceful `finish` operation. ^oastr-p26t
- Each OpenAI Eio Realtime connection shall expose an immediate `abort` operation distinct from `finish`. ^oastr-2sa1
- When a protocol defines a terminal drain event, `finish` shall keep delivering events until that terminal event arrives or the effect is cancelled. ^oastr-oe6k
- When a caller invokes `abort`, the OpenAI Eio transport shall terminate the connection without waiting for protocol drain. ^oastr-zrr2
- When a caller invokes `abort`, the OpenAI Eio transport shall release the connection exactly once. ^oastr-7r31

## Open questions

- Should concurrent pulls and sends serialize or fail immediately with a nominal concurrent-use diagnostic?
- Which framing, JSON, and pending-event limits shall have safe defaults and per-operation overrides?
- Should `finish` rely only on effect cancellation, and should a separate timeout convenience be exposed?
