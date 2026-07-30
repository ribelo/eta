---
kind: requirement
---
# xAI observability

## Intent

Describe xAI inference with Eta AI GenAI telemetry while keeping resource
management outside the GenAI operation vocabulary and excluding nested
transport noise and sensitive content.

## Requirements

- When the xAI provider performs an operation covered by Eta AI GenAI telemetry, the xAI provider shall emit one GenAI operation span. ^xaiobs-98ld
- When the xAI provider performs a resource-management or catalog operation, the xAI provider shall not describe that operation as a GenAI operation span. ^xaiobs-jdm1
- When the xAI provider performs a resource-management or catalog operation, the xAI provider shall emit one ordinary provider client span. ^xaiobs-hchu
- When the xAI provider opens a WebSocket protocol session, the xAI provider shall emit one session-level span. ^xaiobs-84gq
- When the xAI provider emits a GenAI span, the xAI provider shall record `gen_ai.operation.name`. ^xaiobs-rtcw
- When the xAI provider emits a GenAI span, the xAI provider shall record `gen_ai.provider.name`. ^xaiobs-fkqh
- When the xAI provider emits a GenAI span, the xAI provider shall record `server.address`. ^xaiobs-2bo2
- When the configured xAI authority uses an explicit port, the xAI provider shall record `server.port` on its GenAI span. ^xaiobs-veq9
- When an xAI request identifies a model, the xAI provider shall record `gen_ai.request.model` on its GenAI span. ^xaiobs-4hfa
- When an xAI response supplies an identifier, the xAI provider shall record `gen_ai.response.id` on its GenAI span. ^xaiobs-h4yv
- When an xAI response supplies a model, the xAI provider shall record `gen_ai.response.model` on its GenAI span. ^xaiobs-mqxo
- When an xAI response supplies finish reasons, the xAI provider shall record `gen_ai.response.finish_reasons` on its GenAI span. ^xaiobs-8ztz
- When an xAI response supplies input-token usage, the xAI provider shall record `gen_ai.usage.input_tokens` on its GenAI span. ^xaiobs-lxsp
- When an xAI response supplies output-token usage, the xAI provider shall record `gen_ai.usage.output_tokens` on its GenAI span. ^xaiobs-48m9
- When an xAI operation streams a response, the xAI provider shall record `gen_ai.request.stream` on its GenAI span. ^xaiobs-67fn
- When an xAI request identifies audio encoding formats, the xAI provider shall record `gen_ai.request.encoding_formats` on its GenAI span. ^xaiobs-i7jj
- When the xAI provider observes the first response chunk, the xAI provider shall record `gen_ai.response.time_to_first_chunk` on its streaming GenAI span. ^xaiobs-2vw6
- When an xAI operation returns a typed failure, the xAI provider shall record `error.type` on its GenAI span. ^xaiobs-jxip
- While the xAI provider executes transport calls beneath a GenAI or WebSocket session span, the xAI provider shall apply `suppress_provider_transport_observability`. ^xaiobs-e3sy
- The xAI provider shall exclude prompt content from telemetry by default. ^xaiobs-md1q
- The xAI provider shall exclude output content from telemetry by default. ^xaiobs-u7fb
- The xAI provider shall exclude tool arguments from telemetry by default. ^xaiobs-4szd
- The xAI provider shall exclude tool results from telemetry by default. ^xaiobs-r290
- The xAI provider shall exclude audio content from telemetry by default. ^xaiobs-8qbo

## Open questions

- Which protocol metrics, names, units, labels, and cardinality bounds are
  required for each WebSocket protocol?
