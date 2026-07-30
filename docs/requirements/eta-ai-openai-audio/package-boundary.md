---
kind: requirement
---
# OpenAI audio package boundary

## Intent

Expose the complete documented OpenAI audio product surface without forcing Eio,
browser, or provider-specific contracts into applications that do not use them.

## Requirements

- The OpenAI provider shall expose every publicly documented callable audio operation, including generally available, preview, and restricted-access operations. ^oaud-xv8e
- The OpenAI provider shall exclude undocumented and inferred audio operations from its public surface. ^oaud-tmbh
- The `eta_ai_openai` package shall own OpenAI audio REST codecs, HTTP request builders, HTTP runners, provider-specific audio types, and HTTP response streaming. ^oaud-gg0p
- The `eta_ai_openai_realtime_eio` package shall own Eio WebSocket transports for OpenAI Realtime Conversation, Transcription, and Translation protocols. ^oaud-34lq
- The `eta_ai_openai` package shall not depend on Eio. ^oaud-q2us
- The OpenAI provider shall expose full-fidelity provider-owned audio request, response, session, event, voice, and resource types. ^oaud-l7r8
- The OpenAI provider shall expose exact typed protocol primitives and thin convenience operations built directly on those primitives. ^oaud-6uu1
- The OpenAI audio public surface shall expose the current contract without parallel backward-compatibility operations. ^oaud-eg54
- The OpenAI audio expansion shall retain application ownership of conversation state, transcript reconciliation, tool execution, playback, recording, and persistence. ^oaud-0e65
- The OpenAI audio Realtime surface shall cover audio-related Conversation, Transcription, Translation, client-secret, WebRTC, call-control, and SIP contracts without expanding unrelated MCP functionality. ^oaud-sjy4
