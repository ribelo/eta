# xAI Voice APIs — first-party research bundle

**Captured:** 2026-07-29
**Authority:** first-party xAI docs and API reference only (`docs.x.ai`, `x.ai`, machine-readable WS schemas on `docs.x.ai`).
**Scope:** speech-to-speech, batch + streaming speech-to-text, text-to-speech, voice cloning / custom voices, live translation.
**Screenshot:** no screenshot was attached to this task. Identity of any UI screenshot is therefore **unverified**. Findings below map the official Grok Voice surface that such a screenshot would typically depict; contradictions and gaps are called out explicitly.

---

## 1. Executive summary

| Capability | Callable today? | Primary surface | Base host |
|---|---|---|---|
| Speech-to-speech (voice agent) | **Yes** | `wss://api.x.ai/v1/realtime` | `api.x.ai` |
| Speech-to-text batch (file/URL) | **Yes** | `POST https://api.x.ai/v1/stt` | `api.x.ai` |
| Speech-to-text streaming | **Yes** | `wss://api.x.ai/v1/stt` | `api.x.ai` |
| Text-to-speech batch | **Yes** | `POST https://api.x.ai/v1/tts` | `api.x.ai` |
| Text-to-speech streaming | **Yes** | `wss://api.x.ai/v1/tts` (GET + WS upgrade) | `api.x.ai` |
| Voice cloning / custom voices | **Partially** | Console for all; `POST /v1/custom-voices` **Enterprise-gated**; list/get/use broadly | `api.x.ai` |
| Live translation | **No public callable API** | Marketing “Coming Soon” + early-access contact | `x.ai/voice/translation` |

**Auth (all callable endpoints):** `Authorization: Bearer <XAI_API_KEY>` (or ephemeral client secret for browser Realtime).
**Region (model pages):** `us-east-1` for STT / TTS / S2S model cards.
**Pricing (docs pricing page, USD):**

| Mode | Cost |
|---|---|
| S2S `grok-voice-think-fast-1.0` | $0.05 / min audio + $0.004 / text input message |
| S2S `grok-voice-think-fast-2.0` | $0.08 / min audio + $0.004 / text input message |
| STT REST | $0.10 / hr |
| STT streaming | $0.20 / hr |
| TTS | $15.00 / 1M characters |

Marketing also quotes “30 free clones” for voice cloning; custom-voice docs say **30 custom voices per team** default hard limit.

---

## 2. Is this “xAI”? Screenshot identity

**No screenshot was provided in-repo or in the agent prompt attachments.** Under that constraint:

- The five named capabilities **do** match xAI’s public Grok Voice suite (`x.ai/api/voice`, `docs.x.ai` Voice section).
- That is **not** proof a particular screenshot is xAI. Competing vendors (OpenAI Realtime, Deepgram, ElevenLabs, AssemblyAI, Google STT/TTS, etc.) expose overlapping capability labels.
- Discriminators that would confirm xAI UI/docs:
  - Hosts `api.x.ai` / `console.x.ai` / `docs.x.ai`
  - Model IDs `grok-voice-latest`, `grok-voice-think-fast-1.0`, `grok-voice-think-fast-2.0`
  - Paths `/v1/realtime`, `/v1/stt`, `/v1/tts`, `/v1/custom-voices`
  - Voices such as `eve`, `ara`, `rex`, `sal`, `leo`, plus celestial roster (`altair`, `orion`, …)
  - Ephemeral token prefix `xai-client-secret.`
  - Live Translation labeled **Coming Soon**
  - Custom Voices geo gate: **US only, excluding Illinois**
- Discriminators that would **contradict** xAI:
  - OpenAI-only hosts (`api.openai.com`) without xAI base URL swap
  - Deepgram/ElevenLabs path shapes (`/v1/listen`, `/v1/text-to-speech/{voice_id}` with their auth schemes)
  - Live translation presented as GA with a public path (xAI has no such path in docs)

**Verdict:** capability set is consistent with xAI Grok Voice; screenshot attribution remains **unknown without the image**.

---

## 3. Common conventions

### 3.1 Base URLs

| Scheme | Base |
|---|---|
| HTTPS REST | `https://api.x.ai/v1` |
| WebSocket | `wss://api.x.ai/v1` |
| Docs | `https://docs.x.ai` |
| Console | `https://console.x.ai` |
| Marketing voice | `https://x.ai/api/voice` |

No alternate regional API host is documented for these voice endpoints (model cards list cluster `us-east-1` only).

### 3.2 Authentication

| Context | Mechanism |
|---|---|
| Server-side REST + WS | `Authorization: Bearer $XAI_API_KEY` |
| Browser / mobile Realtime | Ephemeral token from `POST /v1/realtime/client_secrets`, then either Bearer of that value **or** `Sec-WebSocket-Protocol: xai-client-secret.<token>` (browsers cannot set WS headers) |
| SIP `call_id` Realtime sessions | API key only — ephemeral secrets **not** supported |

Ephemeral token create:

- `POST https://api.x.ai/v1/realtime/client_secrets`
- Body: `{ "expires_after": { "seconds": N } }` — default 600, max 3600
- REST reference also documents optional `session` bind (`model`, `reasoning.effort`); the ephemeral-tokens **guide** curl note says it does **not** support `"session"` or `"expires_after.anchor"` — **internal docs contradiction** (see §10).
- Response: `{ "value": "xai-realtime-client-secret-…", "expires_at": <unix_s> }`

### 3.3 Machine-readable WS contracts

Official JSON schemas (high-signal for implementers):

| File | Endpoint |
|---|---|
| https://docs.x.ai/voice-realtime.ws.json | `wss://api.x.ai/v1/realtime` |
| https://docs.x.ai/stt-streaming.ws.json | `wss://api.x.ai/v1/stt` |
| https://docs.x.ai/tts-streaming.ws.json | `wss://api.x.ai/v1/tts` |

---

## 4. Speech-to-speech (Realtime voice agent)

### 4.1 Endpoint

```
wss://api.x.ai/v1/realtime?model=grok-voice-latest
```

Optional query params (REST ref + guide):

| Param | Notes |
|---|---|
| `model` | default `grok-voice-latest` |
| `reasoning.effort` | `high` \| `none` (default `high`) |
| `call_id` | SIP inbound call bind; API key auth only |
| `conversation_id` | session resumption (with `resumption.enabled`) |

Connection: HTTP GET upgraded to WebSocket (101). Compatible with OpenAI Realtime clients by pointing base URL at `wss://api.x.ai/v1/realtime` (with documented event differences).

### 4.2 Models

| Model ID | Role |
|---|---|
| `grok-voice-latest` | Alias → currently `grok-voice-think-fast-1.0`; docs say it **updates to `grok-voice-think-fast-2.0` on August 5, 2026** |
| `grok-voice-think-fast-2.0` | Flagship |
| `grok-voice-think-fast-1.0` | Previous-generation |

### 4.3 Lifecycle (happy path)

1. Connect WS → server sends `session.created`, `conversation.created`
2. Client `session.update` (voice, instructions, VAD, tools, audio formats, …) → `session.updated`
3. Stream user audio:
   - **VAD mode** (`turn_detection.type = "server_vad"`): only `input_audio_buffer.append` (or binary frames); server auto-finalizes turns
   - **Manual mode** (`turn_detection.type = null`): `append` → `input_audio_buffer.commit` → usually `response.create`
4. Server emits response cascade: `response.created` → item/content parts → `response.output_audio.delta` (+ transcript deltas) → `*.done` → `response.done`
5. Tools: `response.function_call_arguments.done` → client `conversation.item.create` with `function_call_output`
6. Errors: most recoverable; session stays open (`error` event with typed payload)
7. Hard stop types include `timeout`, `max_duration` (error enum)

**Session resumption:** default WS close drops history. Opt in with `session.resumption.enabled: true`, persist `conversation.created.conversation.id`, reconnect with `?conversation_id=…` and opt in again; cached turns replay as `conversation.item.created`.

**Max session duration (model card):** 120 minutes.
**Concurrent sessions (model card):** field present but **numeric value stripped/empty in rendered HTML** at capture time — treat as unknown from public HTML; check console rate limits.

### 4.4 Client → server events (canonical set)

From REST ref / `voice-realtime.ws.json`:

- `session.update`
- `input_audio_buffer.append` (base64 audio; default JSON transport)
- `input_audio_buffer.commit`
- `input_audio_buffer.clear`
- `conversation.item.create`
- `conversation.item.delete`
- `conversation.item.truncate`
- `response.create`
- `response.cancel`

Binary WebSocket frames carry raw codec bytes when `audio.input.transport = "binary"` (dual-accept with JSON append).

### 4.5 Server → client events (high-signal)

- Session/conversation: `session.created`, `session.updated`, `conversation.created`, `conversation.item.added`, `conversation.item.deleted`, `conversation.item.truncated`
- VAD: `input_audio_buffer.speech_started`, `speech_stopped`, `committed`, `cleared`, `timeout_triggered`
- User ASR: `conversation.item.input_audio_transcription.completed`, `.updated` (cumulative; only when `audio.input.transcription.model = "grok-transcribe"`)
- Response audio/text: `response.created`, `response.output_item.*`, `response.content_part.*`, `response.output_audio.delta` / `.done`, `response.output_audio_transcript.delta` / `.done`, `response.text.delta`, `response.output_text.delta` (GA alias), `response.done`
- Tools/MCP: function_call argument deltas/done; `mcp_list_tools.*`; `response.mcp_call_*`
- SIP: `input_audio_buffer.dtmf_event_received`
- `error`

Audio JSON deltas are **base64**. With `audio.output.transport = "binary"`, audio bytes are raw WS binary; lifecycle events remain JSON. Docs also accept legacy name `response.audio.delta` alongside `response.output_audio.delta`.

### 4.6 `session.update` fields (guide)

| Field | Meaning |
|---|---|
| `instructions` | System prompt |
| `model` | One of the three voice model IDs |
| `reasoning.effort` | `high` \| `none` |
| `voice` | Built-in or custom voice id (default examples use `eve`) |
| `tools[]` | `web_search`, `x_search`, `file_search` / collections, `mcp`, `function` |
| `turn_detection.type` | `"server_vad"` or `null` |
| `turn_detection.threshold` | 0.1–0.9, default **0.85** |
| `turn_detection.silence_duration_ms` | 0–10000 |
| `turn_detection.prefix_padding_ms` | 0–10000, default **333** |
| `turn_detection.idle_timeout_ms` | proactive re-engage after idle; default null |
| `resumption.enabled` | bool, default false |
| `audio.input/output.format.type` | `audio/pcm`, `audio/pcmu`, `audio/pcma`, `audio/opus` |
| `audio.input/output.format.rate` | PCM: 8k/16k/22.05k/24k/**32k**/44.1k/48k; default examples **24000** |
| `audio.input/output.transport` | `json` (default) \| `binary` |
| `audio.input.transcription.language_hint` | BCP-47 bias |
| `audio.input.transcription.keyterms` | ≤100 terms, ≤50 chars each |
| `audio.output.speed` | 0.7–1.5, default 1.0 |
| `replace` | phrase → spoken substitution map (audio only; transcript unchanged) |

### 4.7 Audio formats (S2S)

| Type | Encoding | Rate notes |
|---|---|---|
| `audio/pcm` | Linear16 LE | configurable rates above |
| `audio/pcmu` | G.711 μ-law | 8000 Hz |
| `audio/pcma` | G.711 A-law | 8000 Hz |
| `audio/opus` | Opus packets (one packet per payload) | 24000 Hz mono |

### 4.8 Billing semantics (model card)

- Audio meter: per minute of audio **sent or received**
- Text input: per client `conversation.item.create`, **except** `function_call_output` and items whose content is `input_audio` / `audio`
- `response.create` is **not** billable as a text event

### 4.9 OpenAI Realtime compatibility (docs, last updated 2026-07-27)

- Most OpenAI client libraries work after base URL change.
- Naming: OpenAI `conversation.item.input_audio_transcription.delta` → xAI **`…updated`** (cumulative transcript).
- Unsupported client: `conversation.item.retrieve`; `output_audio_buffer.clear` WebRTC/SIP only.
- Unsupported server: `conversation.item.done`, `…transcription.failed`, `…transcription.segment`, `…retrieved`, several `output_audio_buffer.*`, `rate_limits.updated`.
- xAI extensions: `force_message` item type, `resumption`, `replace`.

### 4.10 Related telephony REST (out of core five, but adjacent)

- `POST /v2/phone-numbers` — provision / BYO SIP
- `POST /v1/realtime/calls/{call_id}/refer`
- `POST /v1/realtime/calls/{call_id}/hangup`
- SIP host example in responses: `sip.voice.x.ai`

---

## 5. Speech-to-text

### 5.1 Batch REST

```
POST https://api.x.ai/v1/stt
Content-Type: multipart/form-data
Authorization: Bearer $XAI_API_KEY
```

**Either `file` or `url` required.** `file` must be the **last** multipart field (fields after `file` may be ignored).

| Field | Type | Default | Notes |
|---|---|---|---|
| `file` | binary | | max **500 MB** |
| `url` | string | | server-side download |
| `audio_format` | enum | | **only** for raw `pcm`/`mulaw`/`alaw` |
| `sample_rate` | enum Hz | | required for raw; 8000/16000/22050/24000/44100/48000; alias `sample_rate_hertz` mentioned in REST ref |
| `language` | string | | with `format=true` enables ITN |
| `format` | bool/`"true"`| false | Inverse Text Normalization; requires `language` |
| `multichannel` | bool | false | per-channel results in `channels[]` |
| `channels` | int | | raw multichannel 2–8 |
| `diarize` | bool | false | word-level `speaker` index |
| `keyterm` | repeatable | | max 100 × 50 chars |
| `filler_words` | bool | false | include uh/um/er when true |
| `vad_threshold` | number | **0.5** (REST) | 0 disables gate |

**Container formats (auto-detected):** wav, mp3, ogg, opus, flac, aac, mp4, m4a, mkv (MP3/AAC/FLAC codecs for mkv).
**Raw:** pcm (s16le), mulaw, alaw.
Marketing also lists WebM; developer format table emphasizes the containers above — **minor marketing vs docs tension** (WebM not in the detailed STT format table).

**Response (JSON):**

```json
{
  "text": "…",
  "language": "en",
  "duration": 8.4,
  "words": [
    { "text": "The", "start": 0.0, "end": 0.24, "confidence": 0.33, "speaker": 0 }
  ],
  "channels": [ { "index": 0, "text": "…", "words": [] } ]
}
```

**Doc contradictions on `language`:**

- Guide example response shows `"language": "English"` (display name).
- REST reference requires `language` and says ISO 639-1, but example has `"language": ""` and notes **“Currently empty — language detection is not yet enabled.”**

**HTTP errors (guide):** 200, 400, 401, 413 (>500MB), 429, 502 (url fetch), 503.

### 5.2 Streaming WebSocket

```
wss://api.x.ai/v1/stt?<query>
```

Config **only** via query string (no setup JSON). Auth: Bearer API key. Docs: never expose key in browsers — proxy.

| Query | Default | Notes |
|---|---|---|
| `sample_rate` | 16000 | 8k–48k set |
| `encoding` | `pcm` | `pcm` \| `mulaw` \| `alaw` |
| `interim_results` | false | partials ~every 500 ms |
| `endpointing` | 10 | ms silence → speech_final; 0–5000 |
| `language` | | enables ITN when set |
| `diarize` | false | |
| `filler_words` | false | |
| `multichannel` | false | needs `channels` ≥ 2 |
| `channels` | 1 | max 8 interleaved |
| `keyterm` | repeatable | |
| `smart_turn` | unset | 0–1 confidence threshold |
| `smart_turn_timeout` | unset | 1–5000 ms force speech_final |
| `vad_threshold` | **0.08** | streaming default ≠ REST 0.5 |

**Client messages:**

- Binary frames: raw audio, real-time paced (docs suggest ~100 ms; 3200 bytes @ 16 kHz PCM16 mono)
- `{"type":"finalize"|"Finalize", "channel"?: N}` — force utterance final (PTT); session stays open
- `{"type":"audio.done"}` — flush, then `transcript.done`, **connection closes**

**Server messages:**

| Type | Role |
|---|---|
| `transcript.created` | ready (`id` UUID) — **wait before sending audio** |
| `transcript.partial` | `text`, `words[]`, `is_final`, `speech_final`, `start`, `duration`, optional `channel_index`, `end_of_turn_confidence` |
| `transcript.done` | final after `audio.done`; one per channel if multichannel; then close |
| `error` | `{message}`; parse errors keep socket open; most others close |

**Finality matrix:**

| `is_final` | `speech_final` | Meaning |
|---|---|---|
| false | false | interim |
| true | false | chunk locked (~3s) / smart_turn demotion |
| true | true | utterance complete |

**Recommended defaults (guide):** `sample_rate=16000&encoding=pcm`, enable `interim_results`, send 100 ms chunks, wait for `transcript.created`.

**Pricing / limits:** $0.10/hr REST, $0.20/hr streaming; model card RPS and concurrent session **numbers empty in HTML** at capture.

### 5.3 STT languages (formatting codes)

Guide table (ITN / `language` parameter):
`ar, cs, da, nl, en, fil, fr, de, hi, id, it, ja, ko, mk, ms, fa, pl, pt, ro, ru, es, sv, th, tr, vi`
Model still transcribes these without `language`; setting `language` enables number/currency/unit formatting.

---

## 6. Text-to-speech

### 6.1 Batch REST

```
POST https://api.x.ai/v1/tts
Content-Type: application/json
Authorization: Bearer $XAI_API_KEY
```

| Field | Req | Notes |
|---|---|---|
| `text` | yes | max **15,000** chars (unary); speech tags supported |
| `language` | yes | BCP-47 or `auto` (case-insensitive) |
| `voice_id` | no | default **`eve`**; case-insensitive |
| `output_format` | no | `{codec, sample_rate?, bit_rate?}`; default MP3 24 kHz / 128 kbps |
| `speed` | no | 0.7–1.5, default 1.0 |
| `optimize_streaming_latency` | no | guide: 0/1/2; **REST + WS schema enum often only 0/1** — contradiction |
| `text_normalization` | no | default false |
| `with_timestamps` | no | default false; changes response shape |

**Default response:** raw audio bytes (`Content-Type` per codec: `audio/mpeg`, `audio/wav`, `audio/pcm`, `audio/basic` mulaw, `audio/alaw`).

**With `with_timestamps: true`:** `application/json`:

```json
{
  "audio": "<base64>",
  "content_type": "audio/mpeg",
  "duration": 0.92,
  "audio_timestamps": {
    "graph_chars": ["H","e",…],
    "graph_times": [[0.0,0.06], …]
  }
}
```

REST ref sometimes types `graph_times` as objects `{start,end}` in examples vs guide’s `[start,end]` arrays — **schema shape inconsistency** between pages.

**Codecs / rates / MP3 bitrates:**

- Codecs: `mp3`, `wav`, `pcm`, `mulaw`, `alaw`
- Rates: 8000, 16000, 22050, 24000, 44100, 48000
- MP3 `bit_rate`: 32000, 64000, 96000, 128000, 192000

**Unary vs stream limits (guide):** request timeout **15 minutes** unary; streaming has **no text length limit** and **50 concurrent sessions per team**.

### 6.2 Streaming WebSocket

```
wss://api.x.ai/v1/tts?language=en&voice=eve&codec=mp3&…
```

Same path as POST; GET + `Upgrade: websocket` selects streaming. Query params mirror batch (`voice` not `voice_id`, `codec` not nested `output_format`).

**Client:**

- `{"type":"text.delta","delta":"…"}` — each delta ≤ 15,000 chars; generation starts as text buffers
- `{"type":"text.done"}` — end utterance

**Server:**

- `{"type":"audio.delta","delta":"<base64>"}` (+ optional timestamps fields when enabled)
- `{"type":"audio.done"}` — utterance complete; **connection stays open** for multi-utterance
- `error`

### 6.3 Voices (built-in)

List: `GET https://api.x.ai/v1/tts/voices` → `{ "voices": [ { "voice_id", "name", "language?" } ] }`
Single: `GET /v1/tts/voices/{voice_id}`

Documented roster (TTS guide table + core five):

| voice_id | Tone (docs) |
|---|---|
| `eve` | Energetic and upbeat (**default**) |
| `ara` | Warm and friendly |
| `leo` | Authoritative and strong |
| `rex` | Confident and clear |
| `sal` | Smooth and balanced |
| `carina` | Soft, empathetic |
| `zagan` | Powerful, dramatic |
| `helix` | Bold, dynamic |
| `orion` | Rich, cinematic |
| `luna` | Gentle, nurturing |
| `iris` | Friendly, upbeat |
| `altair` | Elegant, premium |
| `zenith` | Sharp, focused |
| `perseus` | Strong, confident |
| `helios` | Upbeat, versatile |
| `lux` | Grounded, calm |
| `kepler` | Inventive, charismatic |
| `rigel` | Precise, professional |
| `cosmo` | Bright, curious |
| `celeste` | Compassionate |
| `ursa` | Friendly, warm |
| `sirius` | Quick-witted, playful |
| `lumen` | Warm, articulate |
| `castor` | Charismatic, easygoing |
| `naksh` | Warm, thoughtful |
| `atlas` | Confident, commanding |

(Complete authoritative list is whatever `GET /v1/tts/voices` returns for the team.)

### 6.4 Speech tags

**Inline:** `[pause]`, `[long-pause]`, `[hum-tune]`, `[laugh]`, `[chuckle]`, `[giggle]`, `[cry]`, `[tsk]`, `[tongue-click]`, `[lip-smack]`, `[breath]`, `[inhale]`, `[exhale]`, `[sigh]`

**Wrapping** (open/close tags):
`soft`, `whisper`, `loud`, `build-intensity`, `decrease-intensity`, `higher-pitch`, `lower-pitch`, `slow`, `fast`, `sing-song`, `singing`, `laugh-speak`, `emphasis`

### 6.5 TTS languages

`auto`, `en`, `ar-EG`, `ar-SA`, `ar-AE`, `bn`, `zh`, `fr`, `de`, `hi`, `id`, `it`, `ja`, `ko`, `pt-BR`, `pt-PT`, `ru`, `es-MX`, `es-ES`, `tr`, `vi`
Docs: additional languages may work with varying accuracy. Marketing “25+ languages” is broader than this explicit table.

---

## 7. Voice cloning / custom voices

### 7.1 Availability gates

- **Geo:** United States only, **except Illinois** (hard warning on docs).
- **Create via API:** `POST /v1/custom-voices` is **Enterprise-gated** (`403` without contract). Non-enterprise: create in console (up to 30 free).
- **Use:** custom `voice_id` works on `POST /v1/tts`, `wss://api.x.ai/v1/tts`, `wss://api.x.ai/v1/realtime` (`session.voice`).
- Custom voices **do not** appear in `GET /v1/tts/voices`; use `GET /v1/custom-voices`.
- Team-scoped; never shared across teams.

### 7.2 Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/custom-voices` | Create (multipart); **201** + voice object |
| `GET` | `/v1/custom-voices` | List (`limit` 1–1000 default 100, `pagination_token`) |
| `GET` | `/v1/custom-voices/{voice_id}` | Get metadata |
| `PATCH` | `/v1/custom-voices/{voice_id}` | Update metadata only (JSON; `""` rejected; `null` clears) |
| `GET` | `/v1/custom-voices/{voice_id}/audio` | Download original reference |
| `DELETE` | `/v1/custom-voices/{voice_id}` | Delete → `{"deleted": true}` |

### 7.3 Create body (multipart)

| Field | Req | Notes |
|---|---|---|
| `file` | yes | reference audio, **max 120 s** (no documented minimum; 90–120 s recommended; marketing often says “two minutes”) |
| `name`, `description` | | |
| `gender` | | `male` \| `female` \| `neutral` |
| `accent` | | free text |
| `age` | | `young` \| `middle-aged` \| `old` |
| `language` | | ISO 639 or BCP-47 (`en-US`; region uppercase) |
| `use_case` | | conversational, narration, characters, educational, advertisement, social_media, entertainment |
| `tone` | | warm, casual, professional, friendly, authoritative, expressive, calm |

Recommended upload: WAV PCM, **24 kHz**, 16-bit, mono. Also accepts MP3/FLAC/OGG/Opus/M4A/AAC/MKV/MP4.

**voice_id:** 8-char lowercase alphanumeric.

**Limits:** 30 voices/team default; 120 s max clip; contact sales for higher limits.

**Errors:** 201 create; 200 read/update/delete; 400 bad audio/labels/limit; 401; 403 not enabled / non-enterprise create API; 404; 500.

### 7.4 Marketing vs API

| Claim | API docs |
|---|---|
| “Clone from two minutes” | Accepts **≤120 s**; recommends 90–120 s; no 120 s *minimum* |
| “Two-stage verification: passphrase + speaker embedding” | Described on marketing (`x.ai/voice/cloning`); **not** exposed as fields on `POST /v1/custom-voices` in developer docs (console flow may differ) |
| 30 free clones | Aligns with 30/team limit |

---

## 8. Live translation

| Question | Finding |
|---|---|
| Public product page? | Yes: https://x.ai/voice/translation |
| Status | **“Coming Soon”**; “Contact our team to be considered for early access” |
| Documented REST path? | **None** in `docs.x.ai` Voice / inference reference |
| Documented WebSocket path? | **None** |
| In `llms.txt` voice bullets? | Only TTS / STT / real-time voice — **no** live translation |
| Callable today from public API key? | **No evidence of a public callable API** |

Do **not** invent `/v1/translate` or similar. Early access is sales/contact mediated.

Multilingual **S2S auto language match** and TTS/STT language lists are **not** the Live Translation product.

---

## 9. Cross-cutting limits & compliance (as documented)

| Item | Value | Source quality |
|---|---|---|
| STT max upload | 500 MB | explicit |
| STT channels | ≤8 | explicit |
| TTS unary text | 15,000 chars | explicit |
| TTS stream concurrency | 50 sessions/team | explicit |
| TTS unary timeout | 15 minutes | explicit |
| Custom voice clip | ≤120 s | explicit |
| Custom voices / team | 30 | explicit |
| S2S max session | 120 minutes | model card |
| S2S concurrent sessions | **number missing in HTML** | unknown |
| STT RPS / stream concurrency | **missing in HTML** | unknown |
| Ephemeral token TTL | default 600 s, max 3600 s | explicit |
| Data retention claim | audio processed real time; not stored/used for training | overview marketing/compliance blurb |
| Compliance badges claimed | SOC2 Type II, HIPAA eligible, GDPR, residency, SSO/RBAC | overview |

Pricing page tool invocation costs apply when S2S uses server-side tools (web/x search, etc.).

---

## 10. Contradictions & doc quality issues (do not paper over)

1. **Ephemeral token `session` bind:** REST reference allows `session` on `POST /v1/realtime/client_secrets`; ephemeral-tokens guide curl says session fields unsupported.
2. **STT `language` response:** guide shows English display names; REST ref says ISO code and “currently empty / detection not enabled.”
3. **STT `vad_threshold` defaults:** REST **0.5** vs streaming **0.08**.
4. **TTS `optimize_streaming_latency`:** guide mentions levels **0/1/2**; REST ref + `tts-streaming.ws.json` enum **0/1** only.
5. **TTS timestamp `graph_times` shape:** guide arrays of pairs vs REST example objects with `start`/`end`.
6. **WebM:** marketing STT format chips include WebM; detailed STT format table does not list WebM.
7. **Language count:** “25+ languages” marketing vs explicit TTS table (~20 codes) vs STT formatting table (~25 codes) — different surfaces, easy to over-unify.
8. **Rate limit integers** on several model cards render blank in public HTML (likely console-personalized).
9. **`grok-voice-latest` alias migration date** (2026-08-05) is time-sensitive; pin versioned model IDs in production.
10. **No screenshot** → cannot validate UI copy against these APIs.

---

## 11. Source index (first-party)

| URL | Role |
|---|---|
| https://docs.x.ai/developers/model-capabilities/audio/voice | Voice overview |
| https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech | S2S guide |
| https://docs.x.ai/developers/model-capabilities/audio/speech-to-text | STT guide |
| https://docs.x.ai/developers/model-capabilities/audio/text-to-speech | TTS guide |
| https://docs.x.ai/developers/model-capabilities/audio/custom-voices | Custom voices guide |
| https://docs.x.ai/developers/model-capabilities/audio/ephemeral-tokens | Ephemeral tokens |
| https://docs.x.ai/developers/rest-api-reference/inference/voice | Voice REST + Realtime + TTS WS ref |
| https://docs.x.ai/developers/rest-api-reference/inference/speech-to-text | STT REST + streaming ref |
| https://docs.x.ai/voice-realtime.ws.json | Realtime WS schema |
| https://docs.x.ai/stt-streaming.ws.json | STT WS schema |
| https://docs.x.ai/tts-streaming.ws.json | TTS WS schema |
| https://docs.x.ai/developers/models/speech-to-speech | S2S model card |
| https://docs.x.ai/developers/models/speech-to-text | STT model card |
| https://docs.x.ai/developers/models/text-to-speech | TTS model card |
| https://docs.x.ai/developers/pricing | Voice pricing table |
| https://x.ai/api/voice | Marketing API hub |
| https://x.ai/voice/translation | Live translation teaser |
| https://x.ai/voice/cloning | Cloning marketing |
| https://x.ai/news/grok-stt-and-tts-apis | STT/TTS launch post |
| https://x.ai/news/grok-voice-agent-api | Voice agent launch post |

---

## 12. Implementation checklist

### Shared

- [ ] Obtain `XAI_API_KEY`; never ship it to browsers.
- [ ] Centralize base URL `https://api.x.ai/v1` / `wss://api.x.ai/v1`.
- [ ] Implement 401/429 backoff; surface 403 geo/plan gates clearly.
- [ ] Log `us-east-1` residency assumptions for compliance review.
- [ ] Pin non-`latest` model IDs where alias drift matters (S2S).

### Speech-to-speech

- [ ] WS client to `wss://api.x.ai/v1/realtime?model=…`.
- [ ] Server route: `POST /v1/realtime/client_secrets` → hand token to client.
- [ ] Browser auth via `Sec-WebSocket-Protocol: xai-client-secret.<token>`.
- [ ] On open: handle `session.created` / `conversation.created`; send `session.update`.
- [ ] Choose VAD vs manual commit path; implement interrupt via `response.cancel` / server VAD barge-in.
- [ ] Audio pipeline: PCM16 LE @ agreed rate; optional binary transport.
- [ ] Decode `response.output_audio.delta` (and legacy `response.audio.delta`).
- [ ] Tool loop for `function_call_output`; optional `web_search` / `x_search` / MCP.
- [ ] Optional: `replace` map, language_hint, keyterms, resumption (`conversation_id`).
- [ ] Enforce/monitor 120-minute max session; handle `max_duration` / `timeout` errors.
- [ ] If OpenAI SDK used: apply xAI event renames and unsupported-event list.

### STT batch

- [ ] Multipart POST; options **before** `file`.
- [ ] Support `url` mode and raw pcm/mulaw/alaw + sample_rate.
- [ ] Map words/speakers/channels; don’t assume `language` populated.
- [ ] Cap uploads at 500 MB client-side.

### STT streaming

- [ ] Wait for `transcript.created` before audio.
- [ ] Send raw binary frames (no base64).
- [ ] Interpret interim/chunk/utterance via `is_final`/`speech_final`.
- [ ] Implement `Finalize` for PTT; `audio.done` for end-of-stream close.
- [ ] Optional Smart Turn + timeout; multichannel interleaving math.
- [ ] Proxy WS through backend for browsers.

### TTS

- [ ] JSON POST; treat default body as **bytes**, timestamp mode as **JSON**.
- [ ] `GET /v1/tts/voices` cache; allow custom ids separately.
- [ ] Streaming client: query-param config, `text.delta` → `text.done`, gather `audio.delta` until `audio.done`; multi-utterance reuse.
- [ ] Respect 15k unary limit / 50 stream sessions; pool or queue.
- [ ] Expose speech-tag helpers carefully (inline vs wrapping).

### Custom voices

- [ ] Detect plan: console-only create vs Enterprise API create.
- [ ] Enforce US-except-Illinois product eligibility before UX promises.
- [ ] CRUD wrapper for `/v1/custom-voices`; store 8-char ids.
- [ ] Validate ≤120 s / recommend 90–120 s mono 24 kHz WAV.
- [ ] After delete, fail fast on stale ids in TTS/S2S.

### Live translation

- [ ] **Do not implement** a public client against guessed endpoints.
- [ ] Gate feature flag off; link to early-access contact only.
- [ ] Re-check `docs.x.ai` before any future enablement.

### Verification

- [ ] Contract tests against the three `*.ws.json` schemas.
- [ ] Golden-path integration: STT file, STT stream, TTS bytes, TTS stream, Realtime text turn, Realtime audio turn.
- [ ] Negative tests: 401, oversized STT, TTS >15k unary, custom voice 403/404.

---

## 13. Explicit unknowns

1. **Screenshot contents / vendor identity** — not supplied.
2. **Numeric concurrent session / RPS limits** for S2S and STT (blank in public model-card HTML).
3. **Whether Live Translation early access exposes any path, proto, or header** — unpublished.
4. **Whether ephemeral `session` binding works** despite guide disclaimer.
5. **STT language detection ETA** and stable `language` response taxonomy (code vs name vs empty).
6. **TTS latency level `2`** support in production vs docs drift.
7. **Exact `graph_times` wire type** (pair array vs object array).
8. **WebM acceptance** on `POST /v1/stt` despite omission from detailed table.
9. **Passphrase / embedding verification API** for cloning beyond console UX.
10. **Full OpenAI-compat matrix** beyond the summarized unsupported lists (deep event payload parity).
11. **SIP/WebRTC-only event behavior** on pure WS sessions.
12. **Per-team overrides** for custom voice caps, geo policy, and model availability.
13. **Whether `grok-voice-latest` has already flipped** after 2026-08-05 in a given environment (time-sensitive).
14. **Billing meter edge cases** (silence, binary transport, tool-only turns) beyond the high-level rules.
15. **Non-US data residency knobs for voice** — claimed at overview level without endpoint-level controls in the captured pages.

---

## 14. Capture method

- Queried and crawled first-party pages on `docs.x.ai` and `x.ai` only.
- Downloaded and parsed official WS JSON schemas (`voice-realtime.ws.json`, `stt-streaming.ws.json`, `tts-streaming.ws.json`).
- Did **not** call authenticated API endpoints (no key exercise); did **not** touch non-xAI vendors as authority.
- Did **not** modify any repository files outside this path.

**Output file:** `.scratch/research/xai/voice-apis-first-party-2026-07-29.md`


---

# Part B — Responses API surface inventory (for a first-class Eta provider)

**Captured:** 2026-07-29 (same session as Part A)
**Authority:** first-party only — `https://docs.x.ai/openapi.json` (OpenAPI 3.1), markdown guides under `docs.x.ai/developers/**`, REST reference pages, pricing/models pages.
**Non-goals:** no Eta API design/implementation; no third-party SDKs as authority (SDK snippets quoted only when they illustrate first-party HTTP shapes).

## B1. Scope split: core Responses runner vs resource/management

### B1.1 Belongs in a **core Responses runner** (inference turn loop)

These are the callable surfaces a provider must implement to run ordinary and agentic Grok turns:

| Surface | Method / transport | Role |
|---|---|---|
| Create response | `POST https://api.x.ai/v1/responses` | Primary sync/stream inference |
| Create response (WS mode) | `wss://api.x.ai/v1/responses` + client `response.create` | Long-lived agentic loop; always event-streamed |
| Retrieve stored response | `GET /v1/responses/{response_id}` | Resume/inspect within 30-day store window |
| Delete stored response | `DELETE /v1/responses/{response_id}` | Explicit forget |
| List input items | `GET /v1/responses/{response_id}/input_items` | Paginated reconstruction of stored input |
| Compact context | `POST /v1/responses/compact` | Shrink history → opaque compaction item(s) for next `input` |
| List models (discovery) | `GET /v1/models`, `GET /v1/language-models`, `GET /v1/models/{id}`, `GET /v1/language-models/{id}` | Model/alias inventory for routing |

**In-request capabilities of the runner** (fields on `ModelRequest` / tools on the same POST): text (+ structured `text.format`), image inputs, file inputs, reasoning config, client function tools, server tools (`web_search`, `x_search`, `code_interpreter`, `file_search`, `mcp`, `image_generation`), optional legacy `search_parameters`, streaming SSE, `previous_response_id` chaining, `store`, `include`, `service_tier`, `max_turns`, sampling knobs.

### B1.2 Separate resource / management endpoints (not the turn runner)

| Area | Endpoints (docs / OpenAPI) | Relation to Responses |
|---|---|---|
| **Files** | `POST/GET /v1/files`, `GET/DELETE /v1/files/{file_id}`, `GET .../content`, `POST .../public-url`, `POST .../public-url/revoke` | Produce `file_id` (or public URL) referenced as `input_file` / collections |
| **Collections (RAG index)** | Console + Collections API guides (`/developers/files/collections`, `/developers/files/collections/api`); semantic search also via `POST /v1/documents/search` in OpenAPI | Produce **collection IDs** passed as `file_search.vector_store_ids` |
| **Batch jobs** | `POST/GET /v1/batches`, `.../{batch_id}`, `.../requests`, `.../results` (guide; **not** present in captured `openapi.json`) | Async bulk wrapper that can embed `/v1/responses` bodies |
| **Deferred chat completions** | `POST /v1/chat/completions` with `deferred:true` → `GET /v1/chat/deferred-completion/{request_id}` | **Legacy Chat Completions only** — not Responses |
| **Legacy Chat Completions** | `POST /v1/chat/completions` | Deprecated parallel API; do not treat as Responses core |
| **Other legacy** | `POST /v1/completions`, `POST /v1/complete`, `POST /v1/messages` | Out of Responses scope |
| **Imagine (images/videos)** | `/v1/images/*`, `/v1/videos/*` | Separate product; optional **tool** `image_generation` can be invoked *inside* Responses |
| **Voice** | Part A (`/v1/stt`, `/v1/tts`, `/v1/realtime`, …) | Separate product; **not** Responses input audio |
| **Embeddings** | `/v1/embeddings`, embedding model lists | Separate |
| **Skills** | `/v1/skills`… | Present in OpenAPI; not documented as part of Responses turn loop in captured guides |
| **Account** | `GET /v1/api-key`, `GET /v1/me` | Auth/account metadata |
| **Management API** | Separate Management API section (billing, audit, …) | Org ops, not inference |

### B1.3 Explicitly **not** found as Responses lifecycle ops

| Expected feature | Status in first-party docs/OpenAPI |
|---|---|
| `POST /v1/responses/{id}/cancel` | **Absent** (`cancel` not in OpenAPI) |
| Working `background: true` async Responses | Field exists; marked **`(Unsupported)` / “Not used at the moment”** |
| Deferred Responses poll URL | **Absent** — deferred is Chat Completions only |
| `input_audio` content part on Responses | **Absent** from `ModelInputContentItem` |
| OpenAPI Batch paths | Batch documented in guides; **missing from** `openapi.json` snapshot |

---

## B2. Endpoint / feature matrix

Legend: **Core** = runner; **Res** = resource dependency; **Adj** = adjacent/legacy; **N/A** = not offered.

| Feature | Core? | HTTP/WS | Auth | Notes |
|---|---|---|---|---|
| Create text response | Core | `POST /v1/responses` | Bearer API key | `input` required; `model` strongly expected |
| Stream response (HTTP SSE) | Core | same + `stream:true` | Bearer | OpenAPI: data-only SSE ended by `data: [DONE]` |
| Stream response (WebSocket) | Core | `wss://api.x.ai/v1/responses` | Bearer | Client msg `type=response.create`; serial turns; max **25 min**/conn |
| Warmup without generation | Core (WS) | WS `generate:false` | Bearer | Emits response id; no model run |
| Retrieve response | Core | `GET /v1/responses/{id}` | Bearer | 404 if missing/expired |
| Delete response | Core | `DELETE /v1/responses/{id}` | Bearer | `{id, object:"response", deleted:true}` |
| List input items | Core | `GET .../input_items?limit&order&after` | Bearer | Paginated `list` |
| Context compaction | Core | `POST /v1/responses/compact` | Bearer | Returns `response.compaction` + opaque `compaction` items |
| Stateful multi-turn | Core | `previous_response_id` | Bearer | Needs `store:true` (default) or encrypted content / full replay |
| Disable server store | Core | `store:false` | Bearer | ZDR-friendly; WS in-memory chain still works until disconnect |
| 30-day retention | Core policy | — | — | Then permanent delete |
| Structured outputs | Core | `text.format` = `text` \| `json_object` \| `json_schema` | Bearer | OpenAPI schema field name is `schema` under format object |
| Reasoning effort | Core | `reasoning.effort` or `reasoning_effort` | Bearer | Effort values documented for **`grok-4.3`**: none/low/medium/high |
| Encrypted reasoning | Core | `include: ["reasoning.encrypted_content"]` | Bearer | Replay via prior `output` items when `store:false` |
| Client function tools | Core | `tools[{type:function,...}]` | Bearer | Max **128** tools; return `function_call_output` |
| Web search tool | Core | `tools[{type:web_search,...}]` | Bearer | Server-executed; citations/annotations |
| X search tool | Core | `tools[{type:x_search,...}]` | Bearer | Server-executed |
| Code interpreter | Core | `tools[{type:code_interpreter}]` | Bearer | OpenAI name; xAI SDK often `code_execution` |
| Collections / file_search | Core+Res | `tools[{type:file_search, vector_store_ids:[collection_ids]}]` | Bearer | IDs are collection IDs |
| Remote MCP | Core | `tools[{type:mcp, server_url, server_label, ...}]` | Bearer | `require_approval` / `connector_id` **not supported** (MCP guide) |
| Image generation tool | Core | `tools[{type:image_generation}]` | Bearer | In-response tool; separate from Imagine REST |
| Shell tool | Core (client) | `tools[{type:shell, environment}]` | Bearer | Model emits `shell_call`; **local** execution + `shell_call_output` |
| Legacy live search block | Core (legacy) | `search_parameters` | Bearer | Takes precedence over `web_search_preview` if present |
| Priority tier | Core | `service_tier: "priority"\|"default"` | Bearer | 2× token pricing when served as priority |
| Image input | Core | `input_image` + `image_url` | Bearer | jpg/png; max 20MiB; `file_id` on image “compat only”; storing images “not fully supported” |
| File input | Core+Res | `input_file` via `file_id` \| `file_data` \| `file_url` | Bearer | Exactly one of three |
| Audio input on Responses | **N/A** | — | — | Use Voice STT (Part A), not Responses |
| Cancel in-flight response | **N/A** | — | — | No cancel route |
| Background async Responses | **N/A** (field stub) | `background` ignored/unsupported | — | Do not build on it |
| Deferred Responses | **N/A** | — | — | Use Batch or hold HTTP/WS |
| Batch `/v1/responses` jobs | Adj/Res | Batch API `/v1/batches*` | Bearer | **`grok-4.5` rejected** by Batch today |
| Chat Completions | Adj/Legacy | `POST /v1/chat/completions` | Bearer | Deprecated vs Responses |
| Deferred Chat Completions | Adj/Legacy | `deferred` + GET poll (24h, once) | Bearer | Not Responses |
| Files CRUD | Res | `/v1/files*` | Bearer | purpose often `assistants` in examples |
| Collections CRUD/search | Res | Collections API + optional `POST /v1/documents/search` | Bearer | Feeds `file_search` |
| Model discovery | Core support | `/v1/models`, `/v1/language-models` | Bearer | Also console |

---

## B3. Models and aliases (text / Responses-relevant)

From [Models](https://docs.x.ai/developers/models) + pricing table (text API):

| Model id (as published) | Context | Notes |
|---|---|---|
| `grok-4.5` | 500k | Recommended default for code/chat; long-context price step at 200k prompt tokens |
| `grok-4.3` | 1M | Documented **`reasoning.effort`** support (none/low/medium/high) |
| `grok-4.20-0309-reasoning` | 1M | Reasoning variant |
| `grok-4.20-0309-non-reasoning` | 1M | Non-reasoning variant |
| `grok-4.20-multi-agent-0309` | 1M | Multi-agent variant |
| `grok-build-0.1` | 256k | Build/coding line |
| `latest` | alias | Appears in OpenAPI examples — resolve via models API/console |

**Alias policy (docs):**

- `<modelname>` → latest stable
- `<modelname>-latest` → latest (features)
- `<modelname>-<date>` → pinned release

**Batch incompatibility:** Batch guide warning — **`grok-4.5` is not currently supported** for Batch and will be rejected (use other models e.g. `grok-4.3` in batch examples).

**Knowledge cutoff (Grok 4.5 note):** February 1, 2026.
**Realtime knowledge:** requires web/X search tools.

**logprobs:** not supported on `grok-4.20` and newer — silently ignored.

Vision limits (models page): max image **20MiB**; types **jpg/jpeg, png**; no documented max image count.

---

## B4. Request schema (`POST /v1/responses`) — OpenAPI `ModelRequest`

**Required:** `input`
**Auth:** `Authorization: Bearer <XAI_API_KEY>`
**Errors documented on create:** `400`, `422`

### B4.1 Top-level fields

| Field | Type | Default / notes |
|---|---|---|
| `input` | string **or** `ModelInputPart[]` | Text shorthand or item list |
| `model` | string | e.g. `grok-4.5`, `latest` |
| `instructions` | string\|null | System prompt alternate; **cannot** combine with `previous_response_id` (prior system reused) |
| `previous_response_id` | string\|null | Continue stored (or WS-cached) chain |
| `store` | bool\|null | default **true**; 30-day retention when true |
| `stream` | bool\|null | default false; SSE when true |
| `include` | string[]\|null | e.g. `reasoning.encrypted_content`; tool-output includes; `message.output_text.logprobs` accepted but **silently ignored** |
| `tools` | `ModelTool[]`\|null | max **128**; OpenAPI description still says “only functions and web search” while enum includes more — **doc drift** |
| `tool_choice` | `none`\|`auto`\|`required`\|`{type:"function", name}` | defaults none/auto depending on tools |
| `parallel_tool_calls` | bool\|null | default true |
| `max_turns` | int\|null | agentic server-side turn cap; ignored if non-agentic |
| `max_output_tokens` | int\|null | output+reasoning; default behavior **128,000 when unset** |
| `text` | `{ format: ModelResponseFormat }` | structured outputs |
| `reasoning` | `{ effort, summary?, generate_summary? }` | effort documented for grok-4.3 |
| `reasoning_effort` | string\|null | used only if `reasoning` unset |
| `search_parameters` | SearchParameters\|null | legacy live-search control block |
| `service_tier` | `default`\|`priority` (OpenAPI enum; request text also mentions `auto`) | priority = higher price/scheduling |
| `temperature` | 0–2 | default 1 |
| `top_p` | (0,1] | default 1 |
| `top_k` | int≥1\|null | optional |
| `min_p` | 0–1\|null | optional |
| `logprobs` / `top_logprobs` | | ignored on grok-4.20+ |
| `user` | string\|null | end-user id |
| `prompt_cache_key` | string\|null | sticky routing / Open Responses compat (`x-grok-conv-id`) |
| `metadata` | | **not supported** — compat only |
| `truncation` | string\|null | **not supported** — compat only |
| `background` | bool\|null | **unsupported** async flag |
| `context_management` | array\|null | “Parsed but not yet executed” (e.g. future compaction directives) |

**Present on response object but not as request field in OpenAPI:** `max_tool_calls`, `safety_identifier`, `frequency_penalty`/`presence_penalty` (response echoes; request marks penalties unsupported).

### B4.2 `input` shapes (`ModelInput` / `ModelInputPart`)

1. **Plain string** — single user text.
2. **Array of parts**, each one of:

| Part kind | Discriminator | Role |
|---|---|---|
| Message | `role` + `content` (+ optional `type:"message"`) | `user` \| `assistant` \| `system` \| `developer` |
| Prior model output | `ModelOutput` items | Replay assistant/tool/reasoning items |
| Function result | `type:"function_call_output"` | `{call_id, output}` — output string or content parts |
| Shell result | `ShellCallOutput` | Local shell tool return |
| Compaction | `type:"compaction"` | `{encrypted_content, id?}` opaque |

**Message `content` (`ModelInputContentItem`):**

| type | Fields | Notes |
|---|---|---|
| `input_text` | `text` | |
| `output_text` | `text` | used in compact outputs |
| `input_image` | `image_url` required; `file_id` compat-only | “Storing and fetching images is not fully supported” |
| `input_file` | exactly one of `file_id`, `file_data` (base64), `file_url` | |

**No `input_audio`.** Image understanding examples also pass `"detail":"high"` in guides even when OpenAPI image object omits `detail` — **guide vs OpenAPI gap**.

### B4.3 Structured outputs (`text.format`)

| `type` | Meaning |
|---|---|
| `text` | free text (default) |
| `json_object` | any JSON (legacy; prefer schema) |
| `json_schema` | requires `schema` object; `name`/`description`/`strict` compat-only in OpenAPI |

Guides also describe Chat Completions `response_format` and note tool-call arguments always schema-conform (`strict` implicitly true for tools; function `strict` flag **not supported** in OpenAPI).

### B4.4 Tools (`ModelTool` oneOf)

| `type` | Execution | Key config |
|---|---|---|
| `function` | **Client** | `name`, `parameters` JSON Schema, `description`; `strict` unsupported |
| `web_search` | **Server** | `allowed_domains`/`excluded_domains` (max 5, mutually exclusive); `enable_image_search`; `enable_image_understanding`; OpenAI-only fields **rejected** if set (`external_web_access`, `search_context_size`, `user_location`) |
| `x_search` | **Server** | `allowed_x_handles`/`excluded_x_handles` (max 10); date range; `enable_image_understanding`; `enable_video_understanding` |
| `file_search` | **Server** | **`vector_store_ids`** (collection IDs, max 10); `max_num_results`; OpenAI `filters`/`ranking_options` **rejected** |
| `code_interpreter` | **Server** | OpenAI `container` **rejected** if set |
| `mcp` | **Server** | `server_url`, `server_label` required; `server_description`, `allowed_tools`, `authorization`, `headers`; `require_approval` & `connector_id` unsupported per MCP guide |
| `image_generation` | **Server** | `action`: `auto`\|`generate`\|`edit` |
| `shell` | **Client** | `environment` required — model emits `shell_call` |

**Output item types** (Responses `response.output[]`, from guides + OpenAPI `ModelOutput`):

| `output[].type` | Who runs it |
|---|---|
| `message` | model text/refusal |
| `reasoning` | reasoning summary / encrypted |
| `function_call` | **client** must run |
| `web_search_call` | server (already run) |
| `x_search_call` | server (docs; may appear as typed item / tool_call naming) |
| `code_interpreter_call` | server |
| `file_search_call` | server |
| `mcp_call` | server |
| `image_generation_call` | server |
| `shell_call` | **client** must run |
| `custom_tool_call` | present in OpenAPI (custom tools) |

Client continuation pattern (docs): either
- `previous_response_id` + `input: [function_call_output…]`, or
- `include: [reasoning.encrypted_content]` and resend full `input` history including prior `output` + tool outputs.

Server-side tool **results** are consumed internally; streaming may show invocations; billable successes in usage/`server_side_tool_usage_details`.

### B4.5 Citations

- `output_text.annotations[]` with `type` (currently `url_citation`), `url`, optional `title`, `start_index`, `end_index` (OpenAPI `Annotation`).
- Usage may include `num_sources_used`.
- Legacy/search flows also expose citation lists in SDK (`response.citations`) — wire field set differs by SDK vs raw Responses JSON.

---

## B5. Response object (`ModelResponse`)

Notable fields: `id`, `object:"response"`, `created_at`, `completed_at?`, `model`, `output[]`, `status` ∈ `completed`|`in_progress`|`incomplete`, `store`, `previous_response_id`, `tools`, `tool_choice`, `parallel_tool_calls`, `text`, `reasoning`, `usage`, `incomplete_details` (`max_output_tokens`|`max_prompt_tokens`|`max_time_limit`), `error`, `service_tier`, `background` (compat), penalty fields (unsupported), `user`, `instructions`, `prompt_cache_key`, `max_tool_calls?`, `safety_identifier?`, `truncation`.

**Usage (`ModelUsage`):** `input_tokens`, `output_tokens`, `total_tokens`, `input_tokens_details.cached_tokens`, `output_tokens_details.reasoning_tokens`, `num_sources_used`, `num_server_side_tools_used`, optional `server_side_tool_usage_details` (web/x/code/file_search/mcp/document_search/image_generation counts), optional cost ticks / nano-USD, optional `context_details` (informational, not billing).

**OpenAPI example inconsistency:** some retrieve examples still show Chat-style `prompt_tokens`/`completion_tokens` usage keys alongside Responses `input_tokens`/`output_tokens` — treat Responses names as canonical for `ModelUsage`.

---

## B6. Streaming protocols

### B6.1 HTTP SSE (`stream: true` on `POST /v1/responses`)

- OpenAPI description: partial deltas as **data-only server-sent events**, terminated by `data: [DONE]`.
- Streaming **capability guide** examples are largely **Chat Completions** shaped (`chat.completion.chunk`, `choices[0].delta.content`).
- WebSocket guide states: **“The event types and ordering are identical to the existing Responses streaming format.”**
- **Gap:** captured OpenAPI does **not** enumerate Responses SSE event type names (`response.created`, `response.output_text.delta`, etc.). Implementers must capture live SSE or SDK parsers; do not assume Chat Completions chunk schema for Responses.

### B6.2 WebSocket mode (`wss://api.x.ai/v1/responses`)

| Item | Spec |
|---|---|
| Client entry | `{ "type":"response.create", ...ModelRequest without stream/background }` |
| Warmup | `generate: false` |
| Follow-ups | `previous_response_id` + only **new** input items |
| Concurrency | **Serial** per connection (second create queues) |
| Max lifetime | **25 minutes** then server close |
| store=false / ZDR | In-memory chain on socket; older ids → `previous_response_not_found` if not stored |
| Failed turn | Evicts id from connection cache |
| Errors | `previous_response_not_found`; `websocket_connection_limit_reached` |

### B6.3 Function-call streaming caveat

Function calling guide: with streaming, **function call is returned whole in a single chunk**, not argument-token streamed.

---

## B7. Conversation / previous-response state

| Mechanism | How | Limits |
|---|---|---|
| Server store (default) | `store:true`, chain `previous_response_id` | **30 days**; then gone |
| Explicit retrieve | `GET /v1/responses/{id}` | 404 after delete/expiry |
| Explicit delete | `DELETE /v1/responses/{id}` | |
| Input item listing | `GET .../input_items` | limit 1–100 default 20; order asc/desc; cursor `after` |
| Local/ZDR replay | `store:false` + `include:["reasoning.encrypted_content"]` + resend `output` history | Must keep encrypted reasoning + messages yourself |
| Compaction | `POST /v1/responses/compact` → pass `output` compaction items as next `input` prefix | Opaque `encrypted_content`; do not parse |
| WS cache | last response id hot on connection | 25 min connection; failure eviction |

After 30 days docs: store history + encrypted thinking locally and pass in a new request body.

---

## B8. Reasoning

- Output item `type:"reasoning"` with `summary[]` (`summary_text`), optional `content[]`, optional `encrypted_content` when included.
- Configure via `reasoning.effort` / `reasoning_effort`.
- OpenAPI text: effort values **only supported by `grok-4.3`** (`none`/`low` default/`medium`/`high`). Guides still demo encrypted content with `grok-4.5` — **possible product drift**; verify per model card.
- `reasoning.summary` / `generate_summary`: compatibility; model “shall always return `detailed`”.
- Reasoning tokens billed under `usage.output_tokens_details.reasoning_tokens`.
- Chat Completions path does **not** return reasoning content (comparison guide).

---

## B9. Files & collections dependencies

### Files (resource)

- Upload: `POST /v1/files` multipart (`file`, `purpose` e.g. `assistants` in examples).
- List/get/delete/content/public-url/revoke as in OpenAPI.
- Use in Responses: `input_file.file_id` or skip upload via `file_data` / `file_url`.
- Public URLs: attach by URL without upload when accessible (files guide).
- Storage pricing on pricing page (GiB/day) — operational concern for provider resource layer.

### Collections (resource → `file_search`)

- Collections = embedded document groups; file may belong to multiple collections.
- Responses tool: `file_search` with `vector_store_ids: [collection_id, …]` (OpenAI-compatible name; values are **xAI collection IDs**).
- Management via Collections API/console (not fully expanded in `openapi.json` beyond `POST /v1/documents/search`).
- Collections search guide shows combining `file_search` + `code_interpreter` in one Responses call.

---

## B10. Batch & deferred / async (adjacent)

| Mechanism | Applies to Responses? | Semantics |
|---|---|---|
| **Batch API** | Yes as **request url** `/v1/responses` inside batch | Create batch → add requests → poll → results; ~24h best effort; cheaper; **no** per-minute rate limit accounting; **`grok-4.5` unsupported** |
| **Deferred Chat Completions** | **No** | `deferred:true` on `/v1/chat/completions`; poll GET once within **24h**; 200 done / 202 pending |
| **`background` on Responses** | **No (stub)** | Unsupported |
| **Async HTTP clients** | Transport only | `AsyncOpenAI` / xAI `AsyncClient` — concurrent connections, not a server job API |
| **Priority processing** | Yes | `service_tier:"priority"`; 2× tokens when confirmed priority; **not** for Batch |

Batch also accepts `/v1/chat/completions`, image/video generation URLs per guide examples.

---

## B11. Errors (documented fragments)

| Code | Where | Meaning |
|---|---|---|
| 400 | create/get/delete/list | bad request / invalid key (wording mixes auth into 400 in OpenAPI) |
| 404 | get/delete/list inputs | unknown `response_id` |
| 422 | create | missing fields |
| 202 | deferred chat poll only | still processing |
| WS `previous_response_not_found` | WS mode | cannot hydrate prior id |
| WS `websocket_connection_limit_reached` | WS mode | 25 minute cap |
| Incomplete `status` | response body | `incomplete_details.reason` = max_output_tokens \| max_prompt_tokens \| max_time_limit |

Full debugging matrix page path in nav (`Debugging Errors`); markdown fetch 404’d at capture — partial content visible via `llms.txt`. Provider should treat console rate-limit pages as source for 429 numeric limits (often personalized).

---

## B12. OpenAI compatibility: documented gaps & traps

| Topic | xAI behavior |
|---|---|
| Preferred API | **Responses**; Chat Completions **legacy/deprecated** for new features |
| Base URL | `https://api.x.ai/v1` with OpenAI SDKs |
| Messages → input | `messages` becomes `input`; `max_tokens` → `max_output_tokens` |
| Stateful store | xAI default `store:true` (30 days); OpenAI semantics differ by product |
| Reasoning | Responses returns encrypted/summary reasoning; Chat Completions does not |
| Server tools | Native on Responses; Chat Completions “function calling only” per comparison table |
| MCP | `require_approval`, `connector_id` unsupported |
| Web search OpenAI fields | `external_web_access`, `search_context_size`, `user_location` → **request rejected** if set |
| file_search OpenAI fields | `filters`, `ranking_options` rejected |
| code_interpreter `container` | rejected |
| `background` | accepted as compat field, **not executed** |
| `metadata`, `truncation`, function `strict` | compat / not supported |
| logprobs include path | silently ignored |
| `message.output_text.logprobs` in `include` | silently ignored |
| Tool naming | `code_interpreter` (Responses) vs `code_execution` (xAI SDK) |
| Collections | exposed as OpenAI-like `file_search` + `vector_store_ids` but IDs are collections |
| Streaming event schema | Do not assume OpenAI Responses event names without live capture — OpenAPI silent |
| Batch | OpenAI Batch ≠ xAI `/v1/batches` shapes; check xAI guide |
| Voice/Realtime | Separate; OpenAI Realtime compat is Part A, not Responses |

Comparison guide parameter map (subset):
`messages→input`, `max_tokens→max_output_tokens`, plus Responses-only `previous_response_id`, `store`, `include`.

---

## B13. Core vs resource — provider packaging recommendation (inventory only)

**Minimum core runner:**
`POST/GET/DELETE /v1/responses`, optional `input_items`, optional `compact`, HTTP `stream` and/or WS mode, model list, full `ModelRequest` tool surface the product enables, structured outputs, reasoning include/effort, previous_response chaining, error mapping.

**Resource clients (separate modules):**
Files CRUD/public URL; Collections lifecycle + document ingest; Batch job supervisor; (optional) Imagine REST if not only via `image_generation` tool; Voice stack from Part A; legacy Chat Completions/deferred only if compatibility required.

**Do not put in core runner:** Management API billing/audit, embeddings-only flows, video deferred polling, skills CRUD (unless product explicitly needs them).

---

## B14. Responses-specific contradictions & unknowns

### Contradictions / drift

1. OpenAPI `tools` description still says “only functions and web search” while `ModelTool` includes x_search, file_search, code_interpreter, mcp, image_generation, shell.
2. Streaming guide samples Chat Completions SSE; Responses streaming event list not in OpenAPI.
3. `reasoning.effort` “only grok-4.3” in OpenAPI vs guides using `grok-4.5` with encrypted reasoning.
4. `service_tier` request text mentions `auto`; enum shows `default`|`priority`.
5. Retrieve examples sometimes show Chat usage key names.
6. Image `detail` in guides vs absent in OpenAPI image schema.
7. Batch endpoints documented but **absent** from `openapi.json` snapshot.
8. `FunctionToolCall.type` description overloaded with server tool type strings — overlaps dedicated output schemas.
9. Comparison table says Chat Completions has function calling only; ChatRequest still has `search_parameters` in OpenAPI.
10. Part A Live Translation still non-callable; unrelated but suite screenshots may conflate products.

### Unknowns

1. Canonical **Responses SSE event type catalog** and field-level parity with OpenAI Responses streaming.
2. Whether `x_search_call` always appears as its own output schema variant vs via `function_call`-shaped records.
3. Exact matrix of which models accept `reasoning.effort` values beyond grok-4.3.
4. Full Collections REST path list (console/API subpages) beyond tool usage.
5. Batch OpenAPI/schema and all supported `url` values / size limits.
6. Whether `context_management` will execute compaction server-side soon.
7. `shell` environment object full schema and security model.
8. `custom_tool_call` end-to-end contract (OpenAPI present; sparse guide coverage).
9. `max_tool_calls` request-side control (response field only in OpenAPI).
10. ZDR org interaction details with `store` and WS cache beyond guide notes.
11. Numeric rate limits / concurrency for Responses (console-personalized).
12. Whether `GET /v1/responses/{id}` returns full tool transcripts and encrypted reasoning without re-`include`.
13. `documents/search` vs `file_search` tool equivalence boundaries.
14. Skills API relationship to Responses (if any).
15. Live confirmation that `background` remains no-op.

---

## B15. Implementation checklist (Responses provider — research only)

### Core runner

- [ ] `POST /v1/responses` with Bearer auth; map `input` string|items
- [ ] Support `store`, `previous_response_id`, `instructions` exclusion rule
- [ ] SSE streaming + `[DONE]`; capture real event schema under test
- [ ] Optional WS mode: `response.create`, serial queue, 25m reconnect, warmup `generate:false`
- [ ] `GET`/`DELETE` responses; `GET input_items` pagination
- [ ] `POST /v1/responses/compact` and opaque replay
- [ ] Structured outputs via `text.format`
- [ ] Reasoning effort + `include: reasoning.encrypted_content` replay path
- [ ] Client tool loop: `function_call` / `shell_call` → `*_output` + chain
- [ ] Server tools: web_search, x_search, code_interpreter, file_search, mcp, image_generation
- [ ] Reject/avoid unsupported OpenAI-only tool fields that 400
- [ ] Citations via `annotations`
- [ ] Usage/cost fields; incomplete_details; status handling
- [ ] `service_tier` priority path
- [ ] Model discovery + alias policy; don’t Batch `grok-4.5`
- [ ] No cancel/background/deferred-Responses assumptions
- [ ] No Responses audio input — route to STT if needed

### Resource modules

- [ ] Files upload/list/get/delete/content/public-url
- [ ] Collections create/ingest/search IDs for `vector_store_ids`
- [ ] Batch supervisor for bulk `/v1/responses` (non-4.5 models)
- [ ] Optional legacy Chat Completions + deferred poll
- [ ] Optional Imagine REST vs tool-only image generation

### Verification

- [ ] Contract tests against `https://docs.x.ai/openapi.json` `ModelRequest`/`ModelResponse`
- [ ] Live SSE fixture dump for Responses (fill event catalog unknown)
- [ ] Multi-turn store + store=false encrypted paths
- [ ] Mixed server+client tool pause/resume
- [ ] MCP negative tests for require_approval/connector_id
- [ ] Image and file input golden paths
- [ ] WS 25m and `previous_response_not_found` handling

---

## B16. Sources added for Part B

| URL | Role |
|---|---|
| https://docs.x.ai/openapi.json | Canonical REST schemas/paths snapshot |
| https://docs.x.ai/developers/rest-api-reference/inference/chat | Responses + Chat REST reference |
| https://docs.x.ai/developers/model-capabilities/text/generate-text | Responses guide (store, chain, encrypted) |
| https://docs.x.ai/developers/model-capabilities/text/streaming | Streaming/SSE overview |
| https://docs.x.ai/developers/model-capabilities/text/structured-outputs | JSON schema outputs |
| https://docs.x.ai/developers/model-capabilities/text/reasoning | Reasoning |
| https://docs.x.ai/developers/model-capabilities/text/comparison | Responses vs Chat Completions |
| https://docs.x.ai/developers/model-capabilities/images/understanding | Image input examples |
| https://docs.x.ai/developers/tools/overview | Tool categories |
| https://docs.x.ai/developers/tools/function-calling | Client functions |
| https://docs.x.ai/developers/tools/web-search | Web search tool |
| https://docs.x.ai/developers/tools/x-search | X search tool |
| https://docs.x.ai/developers/tools/code-execution | Code interpreter |
| https://docs.x.ai/developers/tools/collections-search | file_search / collections |
| https://docs.x.ai/developers/tools/remote-mcp | MCP + unsupported OpenAI fields |
| https://docs.x.ai/developers/tools/citations | Citations |
| https://docs.x.ai/developers/tools/tool-usage-details | tool_calls vs usage billing |
| https://docs.x.ai/developers/tools/advanced-usage | Mixed tools, multi-turn agentic |
| https://docs.x.ai/developers/advanced-api-usage/batch-api | Batch jobs |
| https://docs.x.ai/developers/advanced-api-usage/websocket-mode | Responses WS mode |
| https://docs.x.ai/developers/advanced-api-usage/priority-processing | service_tier |
| https://docs.x.ai/developers/advanced-api-usage/context-compaction | compact endpoint guide |
| https://docs.x.ai/developers/advanced-api-usage/prompt-caching | cache key / sticky routing |
| https://docs.x.ai/developers/files/managing-files | Files API |
| https://docs.x.ai/developers/files/collections | Collections concepts |
| https://docs.x.ai/developers/models | Models, aliases, vision limits |
| https://docs.x.ai/developers/pricing | Token/tool/batch/priority pricing |
| https://docs.x.ai/llms.txt | Deferred chat completions + async client notes |

**Capture method addendum:** downloaded OpenAPI and first-party `.md` doc routes; parsed schemas programmatically; did not call authenticated endpoints; did not modify files outside this research path.


---

# Part C — Files, Collections, and Models callable contracts (Responses dependencies)

**Captured:** 2026-07-29
**Authority:** `https://docs.x.ai/openapi.json`; Files REST (`upload`/`manage`/`download`); Collections REST (`collection` management + `search`); guides under `developers/files/**`, `developers/tools/collections-search`, `developers/model-capabilities/files/chat-with-files`, `developers/models`, `developers/pricing`, Management API guide.
**Scope:** exact callable inventory required by approved Responses provider scope. No Eta design.

## C0. Hosts and auth (critical split)

| Host | Used for | Credential |
|---|---|---|
| `https://api.x.ai` | Files CRUD/content/public-url; document **search**; model lists; Responses/`file_search` | **Inference API key** `Authorization: Bearer $XAI_API_KEY` |
| `https://management-api.x.ai` | Collection CRUD; add/list/get/patch/delete documents in collections | **Management API key** `Authorization: Bearer $XAI_MANAGEMENT_API_KEY` |

Management keys are created in Console → Settings → Management Keys. Collections ops need Collections Endpoint group permissions; document attach needs `AddFileToCollection` (guide).
Inference keys are ACL’d separately (`api-key:model:*`, `api-key:endpoint:chat`, etc.) via Management API.

**There is no OpenAI-style `/v1/vector_stores` resource on xAI.** RAG indexes are **Collections** (`collection_<uuid>`).

---

## C1. Verdict: `collections` vs `vector_store_ids`

| Question | First-party answer |
|---|---|
| Are Collections the RAG knowledge-base resource? | **Yes** — “group of files … with an embedding index” ([Collections](https://docs.x.ai/developers/files/collections)). |
| What does Responses `file_search.vector_store_ids` take? | **Collection IDs** — docs explicitly: `vector_store_ids: ["your_collection_id_here"]` with comment “Replace with actual collection ID” ([Collections Search Tool](https://docs.x.ai/developers/tools/collections-search)). |
| OpenAI name mapping | Responses/OpenAI-compatible tool type `file_search`; xAI SDK name `collections_search`; same backend ([collections-search SDK table](https://docs.x.ai/developers/tools/collections-search)). |
| Separate vector-store CRUD? | **Not documented.** Lifecycle is Collections on **management-api**. |
| Direct search without agent? | `POST https://api.x.ai/v1/documents/search` with `source.collection_ids` (inference key). |

**Conclusion:** Under xAI, **`vector_store_ids` is an OpenAI-compatible parameter name for Collection IDs**. Same resource; different name in tool schema vs management/search APIs (`collection_ids`).

---

## C2. Files API — endpoint matrix (`api.x.ai`)

Auth: Bearer **API key**. Base: `https://api.x.ai`.

| Method | Path | Purpose | Request | Response | Errors (documented) |
|---|---|---|---|---|---|
| `POST` | `/v1/files` | Upload | **multipart/form-data** | `File` JSON | 400, **413** (>50 MB) |
| `GET` | `/v1/files` | List (paginated) | query | `{ data: File[], pagination_token }` | 200 |
| `GET` | `/v1/files/{file_id}` | Metadata | path | `File` | 404 |
| `DELETE` | `/v1/files/{file_id}` | Delete | path | `{ id, deleted, object:"file" }` | 404 |
| `GET` | `/v1/files/{file_id}/content` | Download bytes | path + optional `format` | **`application/octet-stream`** stream | 404 |
| `POST` | `/v1/files/{file_id}/public-url` | Create CDN URL | JSON body | `{ public_url, expires_at? }` | 400, 404, **429** |
| `POST` | `/v1/files/{file_id}/public-url/revoke` | Revoke CDN URL | (empty) | `{ id, revoked, public_url? }` | 200 |
| `PUT` | `/v1/files/{file_id}` | Listed in manage ref | **schema undocumented** in captured docs (“API endpoint for PUT…”) | unknown | unknown |
| `POST` | `/v1/files:initialize` | Listed in upload ref | **undocumented body** | unknown | unknown |
| `POST` | `/v1/files:uploadChunks` | Listed in upload ref | **undocumented body** | unknown | unknown |

### C2.1 `POST /v1/files` multipart contract

| Field | Required | Rules |
|---|---|---|
| `file` | **yes** | binary; filename from `Content-Disposition filename=` becomes `File.filename` |
| `expires_after` | no | TTL seconds from upload; **3600–2592000** inclusive; omit = no expiry. **Must appear before `file`** in multipart (handler streams file and cannot rewind). Also accepts OpenAI deepObject: `expires_after[anchor]=created_at` + `expires_after[seconds]=N` before `file`. |
| `purpose` | no | OAI compat only; **not enforced/interpreted**; conventional `"assistants"` |

**Limits (OpenAPI upload summary):** max file size **50 MB**; kept until delete or TTL.
**413** if over 50 MB.

### C2.2 `File` object (OpenAPI)

| Field | Type | Notes |
|---|---|---|
| `id` | string | e.g. `file_<uuid>` — use as `file_id` |
| `object` | string | always `file` |
| `bytes` | int64 | size |
| `created_at` | int64 unix s | |
| `expires_at` | int64\|null | |
| `filename` | string | |
| `purpose` | string | often `""` |
| `public_url` | string\|null | when active |
| `public_url_expires_at` | int64\|null | |

### C2.3 List pagination (`GET /v1/files`)

| Query | Default / range | Notes |
|---|---|---|
| `limit` | default **100**, max **100**, min 1 | |
| `order` | default **`desc`** | `asc`\|`desc` |
| `sort_by` | default **`created_at`** | `created_at`\|`filename`\|`size` |
| `pagination_token` | | from previous response; **always returned**; end when `data.length < limit` |
| `after` | | **compat only** — use `pagination_token` |
| `filter` | | AIP-160; fields: `name`/`file_name`, `file_id`, `size_bytes`, `content_type`, `created_at`, `expires_at`, `upload_status` (`Complete`), `user_defined_id` |

### C2.4 Download (`GET .../content`)

- Response: streamed raw bytes, `Content-Type: application/octet-stream`
- Query `format`: enum **`original`** \| **`text`** (OpenAPI `ContentFormat`)
- 404 if missing/deleted/expired

### C2.5 Public URLs

- Create only for **existing** stored files (not during upload).
- CDN example host: `https://files-cdn.x.ai/<token>/...`
- `expires_after` on URL: 3600–2592000 s; cannot exceed file remaining lifetime; omit → inherit file TTL or indefinite.
- Revoke independent of file delete; revoke is no-op if no URL (`revoked:false`).
- **429**: per-team active public URL quota **1000 max** or rate limit (OpenAPI).
- Create 400 also: unsupported content type, empty file, or file **> 50 MiB** (public-url OpenAPI text).

### C2.6 Lifecycle vs Responses / Collections

```
upload POST /v1/files  →  file_id
        ├─→ Responses input_file {file_id} | file_data | file_url
        ├─→ management POST .../collections/{cid}/documents/{file_id}  (index into collection)
        ├─→ public-url → shareable HTTPS for input_file.file_url / external
        └─→ DELETE file → cannot attach; collection refs break/404 content
```

Chat-with-files: attaching files enables document search agentic behavior; shapes `{type:input_file, file_id|file_url}` ([chat-with-files](https://docs.x.ai/developers/model-capabilities/files/chat-with-files)).

### C2.7 Files pricing (pricing page)

| Item | Rate |
|---|---|
| File storage | **$0.025 / GiB / day** |
| File downloads | **$0.20 / GiB downloaded** |

---

## C3. Collections API — endpoint matrix

### C3.1 Management plane (`https://management-api.x.ai`)

Auth: Bearer **Management API key**. Paths below are under `/v1/...` on that host.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/collections` | Create collection |
| `GET` | `/v1/collections` | List collections (paginated) |
| `GET` | `/v1/collections/{collection_id}` | Get collection metadata |
| `PUT` | `/v1/collections/{collection_id}` | Update name/chunk config/field defs |
| `DELETE` | `/v1/collections/{collection_id}` | Delete collection |
| `POST` | `/v1/collections/{collection_id}/documents/{file_id}` | **Add existing Files API file** into collection (+ `fields`) |
| `POST` | `/v1/collections/{collection_id}/documents` | **Direct multipart upload** into collection (`name`,`data`,`content_type`,`fields`) — guide/metadata examples |
| `GET` | `/v1/collections/{collection_id}/documents` | List documents (paginated) |
| `GET` | `/v1/collections/{collection_id}/documents/{file_id}` | Get document metadata in collection |
| `PATCH` | `/v1/collections/{collection_id}/documents/{file_id}` | **Regenerate indices** for document |
| `DELETE` | `/v1/collections/{collection_id}/documents/{file_id}` | Remove document from collection (not necessarily delete File) |
| `GET` | `/v1/collections/{collection_id}/documents:batchGet` | Batch get by `file_ids` query |

Optional query on most ops: `team_id` (else derived from credentials).

#### Create `POST /v1/collections` body (REST ref)

| Field | Notes |
|---|---|
| `collection_name` | **required** |
| `team_id` | optional |
| `collection_description` | optional |
| `index_configuration.model_name` | embedding model (example `grok-embedding-small`) |
| `chunk_configuration` | chars/tokens/markdown/code/table/bytes configs; `strip_whitespace`; `inject_name_into_chunks` |
| `metric_space` | HNSW cosine/euclidean/inner_product/unknown |
| `field_definitions[]` | `key` required; `required`, `unique`, `inject_into_chunk`, `description` |
| `version` | internal |

**Response highlights:** `collection_id`, `collection_name`, `created_at`, configs, `documents_count`, `field_definitions`, …

#### List collections query

| Param | Notes |
|---|---|
| `limit` | max **100**, default 100 |
| `order` | `ORDERING_ASCENDING` \| `ORDERING_DESCENDING` (default desc) |
| `sort_by` | `COLLECTIONS_SORT_BY_NAME` \| `COLLECTIONS_SORT_BY_AGE` (default name) |
| `pagination_token` | |
| `filter` | collection_id, collection_name, created_at, documents_count |

#### List documents query

| Param | Notes |
|---|---|
| `limit` | max 100, default 100 |
| `order` | ascending/descending |
| `sort_by` | NAME \| SIZE \| AGE (default name) |
| `pagination_token` | |
| `name` | **deprecated** — use filter |
| `filter` | file metadata + `status` + `fields.{key}` |

#### Document object (collection-scoped)

- `file_metadata`: `file_id`, `name`, `size_bytes` (**string** in examples), `content_type`, `created_at`, `expires_at`, `hash`, `upload_status`, `upload_error_message`, `processing_status`, `file_path`
- `fields`: string map metadata
- `status`: `DOCUMENT_STATUS_UNKNOWN|PROCESSING|PROCESSED|FAILED`
- `error_message`, `last_indexed_at`

#### Two add-document flows (both first-party)

1. **Decoupled (recommended in collections API guide):**
   `POST api.x.ai/v1/files` (API key) → `POST management-api.../collections/{cid}/documents/{file_id}` with optional JSON `{fields}` (Management key).
2. **One-shot multipart (metadata guide):**
   `POST management-api.../collections/{cid}/documents` with `-F name= -F data=@ -F content_type= -F fields={json}`.

### C3.2 Inference plane search (`https://api.x.ai`)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `POST` | `/v1/documents/search` | **API key** | Hybrid/semantic/keyword search over `collection_ids` |

#### `SearchRequest` (OpenAPI)

| Field | Req | Notes |
|---|---|---|
| `query` | yes | embedded with collection’s embedding model |
| `source.collection_ids` | yes | array of collection IDs |
| `source.rag_pipeline` | no | `chroma_db` (default) \| `es` |
| `filter` | no | AIP-160 on document metadata |
| `limit` | no | default **10** top chunks |
| `retrieval_mode` | no | default hybrid: `{type: hybrid\|semantic\|keyword, ...}` |
| `instructions` | no | search instructions override |
| `group_by` | no | `{keys:[...], aggregate?}` diversify per metadata |
| `ranking_metric` | no | **Deprecated** — metric from collection creation |

`retrieval_mode` variants may include `reranker` and hybrid `search_multiplier` [1,100].

#### `SearchResponse`

```json
{ "matches": [ {
  "file_id", "chunk_id", "chunk_content", "score",
  "collection_ids": [], "fields": {}, "page_number"?
} ] }
```

### C3.3 Responses agent tool (`file_search`) — relationship

On `POST /v1/responses` tools array (OpenAPI `ModelTool`):

```json
{
  "type": "file_search",
  "vector_store_ids": ["collection_…"],
  "max_num_results": 10
}
```

| Detail | Spec |
|---|---|
| Max collections per tool | **10** `vector_store_ids` |
| OpenAI `filters` / `ranking_options` | **Rejected if set** (OpenAPI) |
| Server execution | yes — output item `file_search_call` with `queries`, `results[{file_id,filename,text,score?}]` |
| Billing | tool invocations: **$2.50 / 1k calls** as `collections_search` / `file_search` (pricing tools table) |
| vs `documents/search` | Same collections; agentic tool is model-driven; REST search is explicit query |

### C3.4 Collections product limits / formats

| Item | Documented value | Source |
|---|---|---|
| Max file size (Collections page) | **100MB** | collections guide |
| Max file size (Files upload OpenAPI) | **50 MB** | **contradiction** — see C6 |
| Credits required | yes, to upload/add | collections guide |
| Training on collection data | **not used** for training | privacy blurb |
| MIME | broad UTF-8 text + long list (pdf, office, html, code, …) | collections guide |
| Storage price | **$0.10 / GiB / day** | pricing |
| Download price | **$0.20 / GiB** (collections downloads) | pricing |

---

## C4. Models API — endpoint matrix (`api.x.ai`)

Auth: Bearer **API key**.

| Method | Path | Returns |
|---|---|---|
| `GET` | `/v1/models` | OpenAI-compatible list: `{ object:"list", data: Model[] }` — ids, aliases, pricing cents, context |
| `GET` | `/v1/models/{model_id}` | single `Model` (+ 404) |
| `GET` | `/v1/language-models` | `{ models: LanguageModel[] }` — chat/vision detail (modalities, fingerprint, search_price, long-context prices, aliases) |
| `GET` | `/v1/language-models/{model_id}` | single `LanguageModel` |
| `GET` | `/v1/embedding-models` | `{ models: EmbeddingModel[] }` |
| `GET` | `/v1/embedding-models/{model_id}` | single |
| `GET` | `/v1/image-generation-models` | list |
| `GET` | `/v1/image-generation-models/{model_id}` | single |
| `GET` | `/v1/video-generation-models` | list |
| `GET` | `/v1/video-generation-models/{model_id}` | single |

**Also (Management API, not inference):**
`GET https://management-api.x.ai/auth/teams/{teamId}/models` — team-available model names for ACL strings.

### C4.1 `Model` (minimal `/v1/models`) fields

`id`, `aliases[]`, `created`, `object:"model"`, `owned_by`, optional: `context_length`, `prompt_text_token_price`, `cached_prompt_text_token_price`, `prompt_image_token_price`, `completion_text_token_price`, long-context price fields, `long_context_threshold`, `image_price`.

**Price unit (OpenAPI):** USD **cents per 100 million tokens** (not per 1M) for token prices; `image_price` in USD cents per image.

### C4.2 `LanguageModel` extras

`fingerprint`, `version`, `input_modalities[]`, `output_modalities[]`, `search_price`, required long-context price fields, `aliases`.

### C4.3 Alias policy (models guide)

- `<name>` → latest stable
- `<name>-latest` → latest features
- `<name>-<date>` → pinned

Published text lineup (pricing table; live `GET /v1/models` is authoritative per key):
`grok-4.5`, `grok-4.3`, `grok-4.20-0309-reasoning`, `grok-4.20-0309-non-reasoning`, `grok-4.20-multi-agent-0309`, `grok-build-0.1`, plus imagine/voice models on other lists.

### C4.4 Relation to Files/Collections/Responses

| Need | Model API role |
|---|---|
| Responses `model` field | Must be id/alias from key’s allowed set (`GET /v1/models` or language-models) |
| Collection `index_configuration.model_name` | Embedding model id (e.g. from embedding-models list / example `grok-embedding-small`) |
| Image understanding attachments | language-model `input_modalities` includes `image` |
| Batch exclusion | `grok-4.5` not batchable (Part B) — still listed on models |

---

## C5. End-to-end dependency graph (Responses-scoped)

```
[Management key]  POST/GET/PUT/DELETE management-api /v1/collections*
        │
        │  POST .../documents/{file_id}   ←── file_id ──┐
        │  (index + metadata fields)                     │
        ▼                                                │
  collection_id  ──►  Responses tools:                   │
        type=file_search                                 │
        vector_store_ids=[collection_id]                 │
                                                         │
[API key]  POST api.x.ai/v1/files  ──────────────────────┘
        │
        ├─► Responses input: input_file.file_id | file_data | file_url
        ├─► GET content / public-url
        └─► POST api.x.ai/v1/documents/search { source.collection_ids }

[API key]  GET /v1/models|language-models|...  ──► Responses model selection
```

---

## C6. Contradictions (Files/Collections/Models)

1. **Max upload size:** Files OpenAPI/upload ref = **50 MB**; Collections product “Usage Limits” = **100MB**. Public-url 400 text also cites 50 MiB. Treat **50 MB as Files API hard limit** unless Collections direct-upload path is proven higher.
2. **`size_bytes` type:** Collection document metadata examples use **string**; Files `File.bytes` is **int64**.
3. **`PUT /v1/files/{id}`**, **`/v1/files:initialize`**, **`/v1/files:uploadChunks`:** appear in REST nav/markdown stubs **without request/response schemas** in captured docs/OpenAPI paths list (initialize/uploadChunks **not** in OpenAPI `paths`).
4. **Dual document POST shapes:** REST emphasizes `POST .../documents/{file_id}`; guides also show `POST .../documents` multipart — both first-party; OpenAPI on management host not in main `openapi.json`.
5. **Management collections absent from `openapi.json`:** inventory relies on REST markdown in `llms.txt` / docs, not the inference OpenAPI file.
6. **Pagination token semantics:** Files say token “always” returned; end when short page — confirm empty-next behavior live.
7. **Embedding model id** `grok-embedding-small` in collection examples vs whatever `GET /v1/embedding-models` returns for a given key — may drift.
8. **Price unit confusion risk:** OpenAPI token prices in **cents per 1e8 tokens** vs marketing **$ per 1M tokens** tables.

---

## C7. Explicit unknowns

1. Full schemas for `PUT /v1/files/{id}`, `files:initialize`, `files:uploadChunks` (resumable upload?).
2. Whether Collections direct multipart allows **100MB** while Files API stays 50MB.
3. Exact Management OpenAPI/protobuf if published separately.
4. Default embedding model when `index_configuration` omitted on create.
5. Behavior when File deleted but still referenced by collection.
6. `processing_status` vs `DOCUMENT_STATUS_*` equivalence.
7. Numeric rate limits for files/collections beyond public-url 1000 active URLs.
8. Whether `file_search` results ever include chunk_ids like `documents/search`.
9. Team-level model list parity between `GET /v1/models` and management `.../models`.
10. Complete enum values for upload_status / processing_status.
11. `rag_pipeline: es` availability and behavioral differences.
12. Whether purpose values other than `assistants` affect anything server-side (docs say no).

---

## C8. Implementation checklist (resource modules only)

### Files (`api.x.ai` + API key)
- [ ] Multipart upload; order `expires_after` before `file`; handle 413
- [ ] List with limit≤100, pagination_token, filter, sort
- [ ] Get/delete metadata; content download stream + format=original|text
- [ ] Public URL create/revoke + 1000 quota / 429
- [ ] Map `file_id` into Responses `input_file`
- [ ] Do not depend on undocumented PUT/chunked upload without capture

### Collections (management-api + Management key; search on api.x.ai)
- [ ] Provision Management key with Collections + AddFileToCollection
- [ ] CRUD collections; field_definitions; chunk/index config
- [ ] Two-step: upload file → add document with fields
- [ ] Optional one-shot multipart documents POST
- [ ] List/get/batchGet/patch-reindex/delete documents
- [ ] `POST /v1/documents/search` for non-agent RAG
- [ ] Responses: `file_search` + **collection ids in `vector_store_ids`** (max 10)
- [ ] Never send OpenAI-only file_search filters/ranking_options

### Models
- [ ] `GET /v1/models` + `/language-models` for Responses routing
- [ ] Use `aliases` when resolving user-facing names
- [ ] Embedding-models list for collection `model_name`
- [ ] Optional management team models for ACL

### Verification
- [ ] Round-trip file → attach Responses → delete → 404 content
- [ ] File → collection → documents/search → file_search tool turn
- [ ] Prove vector_store_ids == collection_id with one id
- [ ] Measure real max upload on both hosts
- [ ] Snapshot `GET /v1/models` JSON per environment

---

## C9. Sources added for Part C

| URL | Role |
|---|---|
| https://docs.x.ai/openapi.json | Files + documents/search + models schemas |
| https://docs.x.ai/developers/rest-api-reference/files | Files REST overview |
| https://docs.x.ai/developers/rest-api-reference/files/upload | POST /v1/files (+ stub chunk endpoints) |
| https://docs.x.ai/developers/rest-api-reference/files/manage | list/get/delete (+ stub PUT) |
| https://docs.x.ai/developers/rest-api-reference/files/download | content download |
| https://docs.x.ai/developers/files/managing-files | Files guide (TTL, pagination) |
| https://docs.x.ai/developers/files/public-urls | Public URL lifecycle |
| https://docs.x.ai/developers/files/collections | Collections product + MIME + 100MB claim |
| https://docs.x.ai/developers/files/collections/api | Management key + flows |
| https://docs.x.ai/developers/files/collections/metadata | field_definitions + filters |
| https://docs.x.ai/developers/rest-api-reference/collections | Collections REST overview (dual host) |
| https://docs.x.ai/developers/rest-api-reference/collections/collection | Full management endpoint catalog |
| https://docs.x.ai/developers/rest-api-reference/collections/search | documents/search ref |
| https://docs.x.ai/developers/tools/collections-search | file_search / vector_store_ids mapping |
| https://docs.x.ai/developers/model-capabilities/files/chat-with-files | input_file attach |
| https://docs.x.ai/developers/rest-api-reference/inference/models | Models REST |
| https://docs.x.ai/developers/models | Aliases + vision limits |
| https://docs.x.ai/developers/pricing | Storage/download + file_search tool price |
| https://docs.x.ai/developers/management-api-guide | Management key / team models |
| https://docs.x.ai/llms.txt | Aggregated REST markdown for collections |

**Capture method:** refreshed OpenAPI; pulled REST markdown via docs `.md` routes and `llms.txt` section dump for management collection catalog; no authenticated calls; only this research file modified.
