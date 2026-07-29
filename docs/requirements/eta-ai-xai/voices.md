---
kind: requirement
---
# xAI voices

## Intent

Allow applications to discover built-in and team-scoped custom voices and use
their opaque identifiers across supported speech capabilities.

## Requirements

- When a caller lists built-in voices, the xAI provider shall send `GET /v1/tts/voices` and decode `voice_id`, `name`, and `language`. ^xaivoice-v50p
- When a caller requests a built-in voice by ID, the xAI provider shall send `GET /v1/tts/voices/{voice_id}` and return typed voice metadata. ^xaivoice-9kah
- When a caller lists custom voices, the xAI provider shall send `GET /v1/custom-voices` and return a typed page of team-scoped metadata. ^xaivoice-mv4h
- When a caller requests a custom voice by ID, the xAI provider shall send `GET /v1/custom-voices/{voice_id}` and return typed metadata. ^xaivoice-4yam
- When a caller requests custom-voice reference audio, the xAI provider shall send `GET /v1/custom-voices/{voice_id}/audio` and preserve its content type and bytes. ^xaivoice-f3yb
- When a caller selects a custom voice for unary text-to-speech, the xAI provider shall encode its opaque voice ID unchanged. ^xaivoice-v39s
- When a caller selects a custom voice for streaming text-to-speech, the xAI provider shall encode its opaque voice ID unchanged. ^xaivoice-c456
- When a caller selects a custom voice for Realtime speech, the xAI provider shall encode its opaque voice ID unchanged. ^xaivoice-f3cx
- The xAI provider shall limit its custom-voice management surface to list, get, and reference-audio operations. ^xaivoice-6b5p
