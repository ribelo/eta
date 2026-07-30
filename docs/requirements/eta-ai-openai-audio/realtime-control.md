---
kind: requirement
---
# OpenAI Realtime connection control

## Intent

Expose server-side credentials and call lifecycle operations without moving
browser, telephony, or application conversation state into Eta.

## Requirements

- The OpenAI provider shall expose transport-neutral client-secret creation for each documented Realtime audio session kind. ^oactl-ostl
- When OpenAI returns a Realtime client secret, the OpenAI provider shall preserve its redacted value, expiry, session binding, and complete raw JSON. ^oactl-gvd3
- The OpenAI provider shall expose transport-neutral WebRTC SDP call setup for documented Realtime audio session kinds. ^oactl-xxn7
- When a caller creates a Realtime call, the OpenAI provider shall preserve the SDP answer and response content type. ^oactl-64uq
- The OpenAI provider shall expose documented Realtime call accept, reject, hangup, and refer operations. ^oactl-qz2s
- When a caller attaches to a SIP call, the OpenAI Realtime transport shall represent the documented call identifier and authentication contract. ^oactl-ffup
- The OpenAI provider shall preserve documented SIP and call lifecycle events as typed events with complete raw JSON. ^oactl-xy2l
- The OpenAI provider shall leave browser peer-connection ownership, media tracks, SIP routing policy, and application call state to the application. ^oactl-hiz9
- The OpenAI provider shall expose every call-control operation through `Eta_ai_openai.Error.t`. ^oactl-6kx2
- The OpenAI provider shall represent Realtime call identifiers as a nominal type distinct from voice, consent, and client-secret values. ^oactl-vg14
