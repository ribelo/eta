---
kind: requirement
---
# OpenAI Chat Completions audio

## Intent

Add documented audio input and spoken output to Chat Completions without
misrepresenting the text-and-image Responses contract as audio-capable.

## Requirements

- The OpenAI Chat module shall expose a provider-owned request type that combines common prompt and tool vocabulary with OpenAI modalities and audio-output configuration. ^oachat-97z2
- When a Chat request includes audio input, the OpenAI provider shall encode it as an `input_audio` content part containing base64 data and its format. ^oachat-xn7a
- When a Chat request asks for spoken output, the OpenAI provider shall encode `audio` in `modalities`. ^oachat-4aoo
- When a Chat request asks for spoken output, the OpenAI provider shall encode the selected voice and output format in the request `audio` object. ^oachat-7hjy
- The OpenAI Chat voice type shall distinguish built-in and custom voice references. ^oachat-8qmj
- The OpenAI Chat module shall expose a provider-owned response type that preserves the complete Chat response and provider raw JSON. ^oachat-pf4m
- When OpenAI returns Chat audio, the OpenAI provider shall preserve its audio ID, expiry, base64 data, transcript, and complete raw JSON. ^oachat-ss65
- When OpenAI returns Chat usage, the OpenAI provider shall preserve audio-token usage details. ^oachat-u5do
- The OpenAI Chat module shall expose an explicit projection from its provider response to the common Eta AI response vocabulary. ^oachat-xp24
- When the explicit Chat projection encounters provider audio facts without a neutral representation, the projection shall discard those facts only at that explicit boundary. ^oachat-na0v
- If a caller supplies audio content to OpenAI Responses, then the OpenAI provider shall reject the request before transport with nominal `Unsupported`. ^oachat-1jii
- The OpenAI provider shall report audio-input capability for Chat Completions without reporting that capability for Responses. ^oachat-er2s
- The OpenAI provider shall report audio-output capability for Chat Completions without reporting that capability for Responses. ^oachat-03zt

## Open questions

- Shall Chat response audio preserve only exact base64 plus a safe bytes decoder, eager bytes plus base64, or another representation?
- Which documented Chat audio streaming fields and deltas belong in the typed streaming event algebra?
