---
kind: requirement
---
# xAI public surface

## Intent

Expose the approved callable xAI inference and resource capabilities without
inventing operations for unpublished or adjacent products.

## Requirements

- The xAI provider shall expose Responses, Files, Collections, model discovery, speech-to-text, text-to-speech, Realtime speech, built-in voices, and read-only custom voices as its callable product surface. ^xaisurf-errd
- While xAI publishes no callable Live Translation contract, the xAI provider shall limit its Live Translation public surface to an unavailable capability value. ^xaipkg-rhsy
- The xAI provider shall limit its telephony public surface to Realtime SIP session events and connection parameters. ^xaipkg-tzj8
