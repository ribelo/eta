---
kind: requirement
---
# xAI model catalogs

## Intent

Allow callers to discover the models and aliases available to their xAI
inference credential.

## Requirements

- When a caller lists generic models, the xAI provider shall send `GET /v1/models`. ^xaimod-yhhe
- When a caller retrieves a generic model, the xAI provider shall send `GET /v1/models/{model_id}`. ^xaimod-wv1p
- When a caller lists language models, the xAI provider shall send `GET /v1/language-models`. ^xaimod-uism
- When a caller retrieves a language model, the xAI provider shall send `GET /v1/language-models/{model_id}`. ^xaimod-gqkd
- When a caller lists embedding models, the xAI provider shall send `GET /v1/embedding-models`. ^xaimod-zokw
- When a caller retrieves an embedding model, the xAI provider shall send `GET /v1/embedding-models/{model_id}`. ^xaimod-yexz
- When a caller lists image-generation models, the xAI provider shall send `GET /v1/image-generation-models`. ^xaimod-0gq1
- When a caller retrieves an image-generation model, the xAI provider shall send `GET /v1/image-generation-models/{model_id}`. ^xaimod-sevi
- When a caller lists video-generation models, the xAI provider shall send `GET /v1/video-generation-models`. ^xaimod-1tjm
- When a caller retrieves a video-generation model, the xAI provider shall send `GET /v1/video-generation-models/{model_id}`. ^xaimod-imuz
- When xAI returns a generic model, the xAI provider shall preserve `id`, `aliases`, `created`, `object`, `owned_by`, `context_length`, `prompt_text_token_price`, `cached_prompt_text_token_price`, `prompt_image_token_price`, `completion_text_token_price`, `long_context_threshold`, and `image_price`. ^xaimod-i41q
- When xAI returns a language model, the xAI provider shall preserve `fingerprint`, `version`, `input_modalities`, `output_modalities`, `search_price`, and `aliases`. ^xaimod-l6mt
