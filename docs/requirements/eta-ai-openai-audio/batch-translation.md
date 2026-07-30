---
kind: requirement
---
# OpenAI batch audio translation

## Intent

Translate completed recordings into English without conflating translation with
same-language transcription or continuous Realtime interpretation.

## Requirements

- When a caller creates a batch audio translation, the OpenAI provider shall send `POST /v1/audio/translations` as multipart form data. ^oatrn-qchq
- The OpenAI batch-translation request shall require a completed audio upload and the `whisper-1` model contract. ^oatrn-caqf
- The OpenAI batch-translation request shall represent the documented prompt, response-format, and temperature controls. ^oatrn-62nf
- The OpenAI batch-translation result shall distinguish text and verbose results with an explicit variant. ^oatrn-18kr
- When OpenAI returns a text translation, the OpenAI provider shall preserve the translated English text and complete raw JSON. ^oatrn-o1sg
- When OpenAI returns a verbose translation, the OpenAI provider shall preserve English output language, duration, text, segments, and complete raw JSON. ^oatrn-w34r
- When OpenAI returns a translation segment, the OpenAI provider shall preserve its identifiers, seek offset, timestamps, text, tokens, temperature, average log probability, compression ratio, and no-speech probability. ^oatrn-8n8m
- The OpenAI provider shall expose batch translation as a protocol distinct from file transcription. ^oatrn-3amm
- The OpenAI provider shall expose batch translation as a protocol distinct from Realtime translation. ^oatrn-vz3t
