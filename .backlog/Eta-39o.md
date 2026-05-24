---
id: Eta-39o
title: "Major: Extract shared provider codec helpers across eta-ai-* packages"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:44:10.280Z
created_by: backlog
updated_at: 2026-05-24T11:21:47Z
close_reason: "Closed by remediation. Chose Option B and added eta-ai-openai-codec as a leaf shared codec package to avoid coupling OpenRouter/OpenAI-compatible providers to the full OpenAI provider. Moved content/message/input/tool/structured-output/result helpers into the shared codec with shape parameters, updated OpenAI, OpenAI-compatible, and OpenRouter providers to consume it, and regenerated package metadata. Verified with nix develop -c dune runtest packages/eta-ai-openai/test packages/eta-ai-openai-compat/test packages/eta-ai-openrouter/test --force."
dependencies:
  - issue_id: Eta-39o
    depends_on_id: Eta-6j9
    type: parent-child
    created_at: 2026-05-24T09:44:26.132Z
    created_by: backlog
---

# Major: Extract shared provider codec helpers across eta-ai-* packages

## description

Issue: codec helpers are duplicated 2-4x across the OpenAI-flavored providers. Verified via grep:

- content_text: 4 copies (eta-ai-openai/eta_ai_openai_responses.ml:5, eta_ai_openai_chat.ml:5, eta-ai-openrouter/eta_ai_openrouter.ml:53, implicit in eta-ai-openai-compat through contents_text).
- contents_text: 4 copies.
- message_item: 2 copies (responses.ml:12, openrouter.ml:57).
- function_call_item: 2 copies (responses.ml:19, openrouter.ml:64).
- input_items: 2 copies (responses.ml:28, openrouter.ml:73).
- tool_json: 4 copies (responses.ml:47, chat.ml:62, openrouter.ml:92, openai-compat.ml:104).
- structured_output_json (a.k.a. structured_format_json in openai-responses): 4 copies.
- structured_output smart constructor: 3 copies (openai-common.ml:28, openrouter.ml:43, openai-compat.ml:33).
- result_all: 3 copies (openai-common.ml:40, openrouter.ml:110, openai-compat.ml:127).

Locations:
- packages/eta-ai-openai/eta_ai_openai_common.ml (already exists, 103 lines, holds some shared helpers — but not enough)
- packages/eta-ai-openai/eta_ai_openai_chat.ml
- packages/eta-ai-openai/eta_ai_openai_responses.ml
- packages/eta-ai-openrouter/eta_ai_openrouter.ml
- packages/eta-ai-openai-compat/eta_ai_openai_compat.ml

## design

No RED test. The existing provider-codec golden tests (each provider's test/ directory) are the regression gate.

Fix shape:
- Decide on the home for the shared helpers. Two reasonable options:
  A) Expand packages/eta-ai-openai/eta_ai_openai_common.ml to hold all shared codec primitives (content_text, contents_text, message_item, function_call_item, input_items, tool_json, structured_output_json, structured_output, result_all). Have OpenAI Chat, OpenAI Responses, OpenRouter, and OpenAI-compat depend on it. This couples non-OpenAI 'OpenAI-compatible' providers to the OpenAI package.
  B) Create packages/eta-ai-openai-codec/ as a leaf package providing the shared codec, depended on by all OpenAI-flavored providers including eta-ai-openai itself. Cleaner separation, one extra package.
  Pick A unless explicit dependency-ergonomic concerns push to B; document the choice.
- Keep provider modules focused on actual differences: endpoint shape, model lists, provider-specific request/response fields, error mapping. The codec helpers move; the provider files shrink.
- Where two providers' helper bodies look identical but use slightly different require_json / schema_value functions, parameterize the helper on the validator rather than duplicate the body. Audit by diff after extraction.

## acceptance criteria

After the refactor, each helper listed above has exactly one definition (or one parameterized definition with explicit per-provider arguments). Provider modules consume the shared helpers. Existing golden / codec tests in each provider package pass unchanged. Per-provider files shrink in line count; no provider-specific codec drift sneaks back in.
