---
kind: requirement
---
# Eta AI telemetry sharing

## Intent

Share GenAI inference telemetry by semantic operation rather than coupling it
to one provider request record.

## Requirements

- The `Eta_ai.Provider.Telemetry` inference operation shall accept the model and streaming state independently of a Chat or Responses request type. ^aitel-synr
- When Eta AI instruments Chat or Responses inference, Eta AI shall use the same inference-span semantics. ^aitel-w404
- When an instrumented non-streaming inference returns an Eta AI response, Eta AI shall derive response telemetry from that returned response. ^aitel-olpk
- When an instrumented streaming inference observes its first response chunk, Eta AI shall permit the caller to record time to first chunk on the inference span. ^aitel-gw1d
- The `Eta_ai.Provider.Telemetry` module shall expose typed telemetry operations for embeddings and tool execution. ^aitel-lyku
- When Eta performs a provider resource-management operation that is not a GenAI semantic-convention operation, Eta shall not describe that operation as a GenAI inference span. ^aitel-jtwt
- The `Eta_ai.Provider.Telemetry` module shall expose an ordinary client-span operation for provider resource-management and catalog requests. ^aitel-ku25

## Open questions

- Which provider, server, and operation attributes shall ordinary provider
  client spans record?
