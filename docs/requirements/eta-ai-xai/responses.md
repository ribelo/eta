---
kind: requirement
---
# xAI Responses

## Intent

Expose xAI Responses as a lossless typed turn and stored-response capability
without collapsing it into Chat Completions.

## Requirements

- Eta AI shall expose an `Eta_ai.Responses.request` type parameterized by its provider-specific tool type. ^xairsp-0eyc
- Eta AI shall retain a distinct Chat Completions request type rather than adding Responses lifecycle fields to it. ^xairsp-2a4x
- The xAI Responses request shall represent `input` as text or typed input items. ^xairsp-mu67
- The xAI Responses request shall represent `model` as a model identifier. ^xairsp-g2je
- The xAI Responses request shall represent `instructions`, `previous_response_id`, `store`, and `include`. ^xairsp-mcgd
- The xAI Responses request shall represent `stream`. ^xairsp-7373
- The xAI Responses request shall represent `tools`, `tool_choice`, `parallel_tool_calls`, and `max_turns`. ^xairsp-32q9
- The xAI Responses request shall represent `max_output_tokens`, `temperature`, `top_p`, `top_k`, and `min_p`. ^xairsp-swws
- The xAI Responses request shall represent `text`, `reasoning`, `reasoning_effort`, `search_parameters`, and `service_tier`. ^xairsp-76r3
- The xAI Responses request shall represent `user` and `prompt_cache_key`. ^xairsp-wqli
- If an xAI Responses request contains more than 128 tools, then the xAI provider shall reject it before transport. ^xairsp-m3ns
- The xAI Responses tool type shall represent client-executed function tools with `name`, `parameters`, and `description`. ^xairsp-rxle
- The xAI Responses tool type shall represent server-executed web-search tools with `allowed_domains`, `excluded_domains`, `enable_image_search`, and `enable_image_understanding`. ^xairsp-j8v7
- The xAI Responses tool type shall represent server-executed X-search tools with `allowed_x_handles`, `excluded_x_handles`, `from_date`, `to_date`, `enable_image_understanding`, and `enable_video_understanding`. ^xairsp-dm4i
- The xAI Responses tool type shall represent server-executed code-interpreter tools. ^xairsp-6x0x
- The xAI Responses tool type shall represent server-executed file-search tools with `vector_store_ids` and `max_num_results`. ^xairsp-pa8e
- The xAI Responses tool type shall represent server-executed MCP tools with `server_url`, `server_label`, `server_description`, `allowed_tools`, `authorization`, and `headers`. ^xairsp-tces
- The xAI Responses tool type shall represent server-executed image-generation tools with `action`. ^xairsp-10r1
- The xAI Responses tool type shall reuse shared function-tool and JSON-schema primitives where their semantics match. ^xairsp-wtth
- If a file-search tool contains more than 10 `vector_store_ids`, then the xAI provider shall reject it before transport. ^xairsp-uog6
- When a file-search tool references `vector_store_ids`, the xAI provider shall encode each value as an xAI collection ID. ^xaicol-7emp
- The xAI provider shall support model input containing text. ^xairsp-j451
- The xAI provider shall support model input containing images. ^xairsp-ekvc
- The xAI provider shall support model input containing files. ^xairsp-3crj
- The xAI provider shall support model input containing prior model output items. ^xairsp-2ojb
- The xAI provider shall support model input containing function-call outputs. ^xairsp-5lgw
- The xAI provider shall support model input containing compaction items. ^xairsp-67np
- When the xAI provider encodes an `input_file` item, the xAI provider shall require exactly one of `file_id`, `file_data`, or `file_url`. ^xairsp-zlqu
- When the xAI provider decodes a response, the xAI provider shall preserve `id`, `object`, `created_at`, `completed_at`, `model`, `status`, `store`, and `previous_response_id`. ^xairsp-d1wh
- When the xAI provider decodes a response, the xAI provider shall preserve tools, tool choice, parallel-tool-call state, text configuration, reasoning configuration, service tier, and incomplete details. ^xairsp-htey
- When the xAI provider decodes response usage, the xAI provider shall preserve input, output, total, cached, and reasoning token counts. ^xairsp-1ms1
- When the xAI provider decodes response usage, the xAI provider shall preserve source counts, server-side tool counts, server-side tool usage details, cost ticks, nano-USD cost, and context details. ^xairsp-09yi
- The xAI Responses output-item type shall represent message items. ^xairsp-zg1j
- The xAI Responses output-item type shall represent reasoning items. ^xairsp-bk4b
- When the xAI provider decodes a reasoning item, the xAI provider shall preserve `summary`, `content`, and `encrypted_content`. ^xairsp-pszf
- The xAI Responses output-item type shall represent function-call items. ^xairsp-xnkz
- The xAI Responses output-item type shall represent web-search-call items. ^xairsp-2q8h
- The xAI Responses output-item type shall represent code-interpreter-call items. ^xairsp-yoi4
- The xAI Responses output-item type shall represent file-search-call items. ^xairsp-jbob
- The xAI Responses output-item type shall represent MCP-call items. ^xairsp-5atp
- The xAI Responses output-item type shall represent image-generation-call items. ^xairsp-ulto
- When the xAI provider decodes a URL citation annotation, the xAI provider shall preserve `url`, `title`, `start_index`, and `end_index`. ^xairsp-fi84
- If xAI returns an output item outside the typed output-item set, then the xAI provider shall preserve it as an `Unknown` item containing the raw JSON. ^xairsp-2j76
- When a caller requests the provider-neutral view of an xAI response, the xAI provider shall project the typed response explicitly to `Eta_ai.response`. ^xairsp-a6oy
- When xAI requests a function call, the xAI provider shall return the typed call without executing application code. ^xairsp-xtcz
- When an application submits a function-call result, the xAI provider shall encode it as a typed `function_call_output` input item. ^xairsp-wzzx
- When a caller creates a response, the xAI provider shall send `POST /v1/responses`. ^xairsp-7sih
- When a caller retrieves a stored response, the xAI provider shall send `GET /v1/responses/{response_id}`. ^xairsp-mh6a
- When a caller deletes a stored response, the xAI provider shall send `DELETE /v1/responses/{response_id}`. ^xairsp-ogq1
- When a caller lists stored response input items, the xAI provider shall send `GET /v1/responses/{response_id}/input_items`. ^xairsp-lfuu
- When a caller compacts response context, the xAI provider shall send `POST /v1/responses/compact`. ^xairsp-h88u
- When xAI returns a compaction item, the xAI provider shall preserve its `encrypted_content` as opaque data. ^xairsp-rsfa
- When xAI streams a response over HTTP SSE, the xAI provider shall expose an xAI-specific pull stream. ^xairsp-ks0s
- When an xAI Responses SSE stream emits `data: [DONE]`, the xAI provider shall finish the pull stream. ^xairsp-t1ui
- The xAI Eio transport shall expose Responses WebSocket mode separately from Realtime speech sessions. ^xairsp-k16t
- When a caller creates a response over WebSocket, the xAI Eio transport shall encode a `response.create` client message. ^xairsp-jnme
- When a caller warms a Responses WebSocket connection, the xAI Eio transport shall encode `response.create` with `generate` set to `false`. ^xairsp-0bkw
- While a Responses WebSocket connection is open, the xAI Eio transport shall submit response requests serially. ^xairsp-n7tp
- When a Responses WebSocket connection reaches 25 minutes, the xAI Eio transport shall close the connection and release its event stream. ^xairsp-abkp
- If xAI returns `previous_response_not_found` over a Responses WebSocket connection, then the xAI Eio transport shall return a typed failure preserving that provider code. ^xairsp-znmo
- If xAI returns `websocket_connection_limit_reached` over a Responses WebSocket connection, then the xAI Eio transport shall return a typed failure preserving that provider code. ^xairsp-bewq
- The xAI Responses stream-event type shall contain typed variants only for event schemas verified against xAI's Responses protocol. ^xairsp-pth1
- If xAI streams an event outside the typed Responses event set, then the xAI provider shall preserve it as an `Unknown` event containing the raw JSON. ^xairsp-u7pm
- When a caller requests provider-neutral streaming events, the xAI provider shall project each typed xAI stream event explicitly to zero or more `Eta_ai.stream_event` values. ^xairsp-ij8o

## Open questions

- What is the canonical xAI Responses SSE event taxonomy and the field schema
  for each event?
- Does `x_search_call` have a stable dedicated output-item schema?
- What are the complete schemas and execution constraints for `shell` tools,
  `shell_call` items, `shell_call_output` items, and `custom_tool_call` items?
- Which models accept each `reasoning.effort` value?
- Is `service_tier: auto` supported in addition to `default` and `priority`?
- Is image input `detail` part of the stable xAI Responses wire schema?
