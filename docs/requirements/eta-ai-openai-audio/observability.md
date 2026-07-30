---
kind: requirement
---
# OpenAI audio observability

## Intent

Make audio operations observable without recording credentials, prompts,
transcripts, voice samples, consent recordings, or audio content.

## Requirements

- The OpenAI provider shall emit ordinary provider-client spans for speech generation, file transcription, batch translation, custom voices, voice consents, client secrets, and call-control operations. ^oaobs-hsqu
- The OpenAI provider shall emit GenAI inference spans for Chat audio and Realtime Conversation inference. ^oaobs-ll1y
- Each OpenAI audio span shall record provider, operation, server authority, and nominal error classification. ^oaobs-49xl
- Where the accepted GenAI convention defines audio usage attributes, the OpenAI provider shall record those attributes from provider usage facts. ^oaobs-cna3
- OpenAI audio provider spans shall suppress nested eta-http client spans by default. ^oaobs-140d
- OpenAI audio telemetry shall exclude API keys, ephemeral secrets, prompts, transcripts, source audio, generated audio, voice samples, consent recordings, and raw provider bodies. ^oaobs-c50d
- Realtime audio telemetry shall record protocol and lifecycle facts without recording event content. ^oaobs-30a6
- Streaming audio telemetry shall record streaming mode without accumulating stream content. ^oaobs-lxts
