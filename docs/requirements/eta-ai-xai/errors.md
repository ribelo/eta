---
kind: requirement
---
# xAI errors

## Intent

Preserve xAI failure information while permitting explicit projection into the
provider-neutral Eta AI error vocabulary.

## Requirements

- The xAI provider shall expose a typed xAI error preserving the provider error payload without loss. ^xaicore-07fo
- When a caller requests provider-neutral failure handling, the xAI provider shall project its typed error explicitly to `Eta_ai.ai_error`. ^xaicore-db5h
- If an xAI response contains an unrecognized error shape, then the xAI provider shall preserve the status, headers, and raw body in the typed error. ^xaicore-i1og
