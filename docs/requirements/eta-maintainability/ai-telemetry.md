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
- When Eta AI emits an ordinary provider client span, Eta AI shall record `eta_ai.provider.name`. ^aitel-h72d
- When Eta AI emits an ordinary provider client span, Eta AI shall record `eta_ai.operation.name`. ^aitel-vgfn
- When Eta AI emits an ordinary provider client span, Eta AI shall record `server.address`. ^aitel-nfi7
- When an ordinary provider client span targets an explicit server port, Eta AI shall record `server.port`. ^aitel-1cbb
- When an ordinary provider client operation returns a typed failure, Eta AI shall record `error.type`. ^aitel-zqkg
- While an ordinary provider client span owns an operation, Eta AI shall suppress nested eta-http observability for that operation. ^aitel-7vb8
- The `Eta_ai.Provider.Telemetry` module shall accept a typed error view that supplies error classification and formatting without changing the effect error type. ^aitel-dull
- While the accepted Eta GenAI convention does not define speech-to-text, text-to-speech, or voice-resource operations, Eta AI shall describe those operations with ordinary provider client spans. ^aitel-h2cu
- The `Eta_ai.Provider.Telemetry` public interface shall expose its typed error-view vocabulary to provider adapters. ^aitel-z1et
- If a provider adapter supplies an empty ordinary operation name, then `Eta_ai.Provider.Telemetry` shall reject the operation before emitting a span. ^aitel-qwbk
