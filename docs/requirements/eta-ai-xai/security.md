---
kind: requirement
---
# xAI credential security

## Intent

Keep inference, management, and ephemeral credentials nominally distinct,
redacted, authority-bound, and raw only at authentication boundaries.

## Requirements

- The xAI provider shall accept inference credentials as redacted `Eta_ai.api_key` values. ^xaisec-aplg
- The xAI provider shall represent a Management API key as a redacted nominal type distinct from the inference API key type. ^xaicol-tz3p
- The xAI provider shall represent an ephemeral Realtime client secret as a redacted nominal type distinct from inference and Management API key types. ^xaisec-tlxw
- When the xAI provider authenticates an inference request, the xAI provider shall extract the raw inference key only while constructing authentication data for `api.x.ai`. ^xaisec-ut3h
- When the xAI provider authenticates a collection-management request, the xAI provider shall extract the raw Management API key only while constructing the bearer header for `management-api.x.ai`. ^xaisec-5v4u
- When the xAI Eio transport authenticates Realtime with an ephemeral client secret, the xAI Eio transport shall extract the raw secret only while constructing the bearer header or `Sec-WebSocket-Protocol` value for `api.x.ai`. ^xaisec-e4nv
- When the xAI provider performs collection management, the xAI provider shall send the Management API key only to `management-api.x.ai`. ^xaicol-0x3g
- When the xAI provider performs inference or inference-resource operations, the xAI provider shall send the inference API key only to `api.x.ai`. ^xaisec-p3p6
- When the xAI Eio transport uses an ephemeral client secret, the xAI Eio transport shall send the secret only to the Realtime endpoint on `api.x.ai`. ^xaisec-n7lu
- The xAI provider shall exclude inference credentials from logs and telemetry. ^xaisec-sags
- The xAI provider shall exclude Management API credentials from logs and telemetry. ^xaisec-khar
- The xAI provider shall exclude ephemeral client secrets from logs and telemetry. ^xaisec-fo5p
