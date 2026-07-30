---
kind: requirement
---
# OpenAI restricted custom voices

## Intent

Expose OpenAI's eligibility-gated consent and custom-voice creation contracts
without claiming account eligibility or inventing unsupported voice-resource APIs.

## Requirements

- The OpenAI provider shall expose restricted custom-voice operations under `Audio.Restricted.Custom_voices` and `Audio.Restricted.Voice_consents`. ^oavoi-io68
- The restricted namespace shall communicate eligibility without performing a fabricated client-side eligibility check. ^oavoi-9vux
- When OpenAI rejects custom-voice access, the OpenAI provider shall preserve the normal nominal provider failure. ^oavoi-aauh
- When a caller creates voice consent, the OpenAI provider shall send `POST /v1/audio/voice_consents` as multipart form data containing name, BCP 47 language, and recording. ^oavoi-4eok
- When a caller retrieves voice consent, the OpenAI provider shall send `GET /v1/audio/voice_consents/{consent_id}`. ^oavoi-6mfn
- When a caller updates voice-consent metadata, the OpenAI provider shall send `POST /v1/audio/voice_consents/{consent_id}` with the updated name. ^oavoi-vklt
- When a caller deletes voice consent, the OpenAI provider shall send `DELETE /v1/audio/voice_consents/{consent_id}`. ^oavoi-hsge
- When OpenAI returns deleted voice consent, the OpenAI provider shall preserve ID, deleted status, object type, and complete raw JSON. ^oavoi-ld53
- When a caller lists voice consents, the OpenAI provider shall send `GET /v1/audio/voice_consents` with optional `after` and `limit`. ^oavoi-iomr
- When OpenAI returns voice consent, the OpenAI provider shall preserve ID, creation time, language, name, object type, and complete raw JSON. ^oavoi-h2n6
- When OpenAI returns a voice-consent page, the OpenAI provider shall preserve data, `has_more`, first ID, last ID, object type, and complete raw JSON. ^oavoi-gqt0
- When a caller creates a custom voice, the OpenAI provider shall send `POST /v1/audio/voices` as multipart form data containing name, consent ID, and audio sample. ^oavoi-1fsj
- When OpenAI returns a custom voice, the OpenAI provider shall preserve ID, creation time, name, object type, and complete raw JSON. ^oavoi-xpk7
- The OpenAI provider shall expose documented custom-voice creation without inventing custom-voice list, retrieve, update, or delete operations. ^oavoi-xuhw
- The OpenAI Speech module shall accept a custom voice ID where documented. ^oavoi-p7et
- The OpenAI Chat audio-output module shall accept a custom voice ID where documented. ^oavoi-gpmi
- The OpenAI Realtime audio-output modules shall accept a custom voice ID where documented. ^oavoi-fmnf
- The OpenAI custom-voice public API shall leave consent recording, actor verification, disclosure, and organizational eligibility policy to the application and OpenAI service. ^oavoi-h6sx

## Open questions

- Should built-in voices be a documented enum with a forward-compatible `Other` case?
- Should consent IDs and custom voice IDs be distinct nominal private types?
- Should consent pagination expose page primitives only or bounded pull-based iteration conveniences?
