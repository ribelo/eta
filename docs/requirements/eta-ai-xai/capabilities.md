---
kind: requirement
---
# xAI capabilities

## Intent

Let callers discover precise xAI feature support while retaining Eta AI's
coarse provider-neutral capability view.

## Requirements

- The xAI provider shall expose a typed xAI capability record for Responses, resource, voice, and streaming operation support. ^xaicore-hns4
- The xAI provider shall populate Eta AI's shared capability record from the typed xAI capability record. ^xaicap-c5ir
