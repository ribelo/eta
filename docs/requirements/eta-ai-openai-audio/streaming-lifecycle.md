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
- If a caller starts a second concurrent operation on an OpenAI audio pull stream, then the OpenAI provider shall fail that operation immediately with a nominal concurrent-use error. ^oastr-qjzb
- If a caller starts a second concurrent read on an OpenAI Realtime connection, then the OpenAI Eio transport shall fail that read immediately with a nominal concurrent-use error. ^oastr-jete
- Each OpenAI audio stream shall bound its unframed buffer size by default. ^oastr-h4gx
- Each OpenAI audio stream shall bound its decoded JSON size by default. ^oastr-nxev
- Each OpenAI audio stream shall bound its pending decoded event count by default. ^oastr-8f7g
- Each OpenAI audio stream shall accept per-operation overrides of its documented bounds. ^oastr-659y
- Each OpenAI audio stream shall permit unbounded total streamed audio while its framing and pending-state bounds remain in force. ^oastr-39sn
- The OpenAI Eio Realtime transport shall expose a bounded-wait finish convenience accepting a caller-supplied timeout. ^oastr-ip8c
