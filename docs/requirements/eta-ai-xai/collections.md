---
kind: requirement
---
# xAI collections

## Intent

Manage xAI collections and their documents and search those collections from
the inference plane.

## Requirements

- When a caller creates a collection, the xAI provider shall send `POST /v1/collections` to `management-api.x.ai`. ^xaicol-3em3
- When a caller creates a collection, the xAI provider shall represent `collection_name`, `team_id`, `collection_description`, `index_configuration`, `chunk_configuration`, `metric_space`, `field_definitions`, and `version`. ^xaicol-kp99
- When xAI returns a collection, the xAI provider shall preserve `collection_id`, `collection_name`, `created_at`, `index_configuration`, `chunk_configuration`, `metric_space`, `documents_count`, and `field_definitions`. ^xaicol-uxmp
- When a caller lists collections, the xAI provider shall send `GET /v1/collections` to `management-api.x.ai`. ^xaicol-wprq
- When a caller configures a collection list, the xAI provider shall represent `limit`, `order`, `sort_by`, `pagination_token`, and `filter`. ^xaicol-eo1h
- When a caller requests a collection, the xAI provider shall send `GET /v1/collections/{collection_id}` to `management-api.x.ai`. ^xaicol-s4e7
- When a caller updates a collection, the xAI provider shall send `PUT /v1/collections/{collection_id}` to `management-api.x.ai`. ^xaicol-32gq
- When a caller deletes a collection, the xAI provider shall send `DELETE /v1/collections/{collection_id}` to `management-api.x.ai`. ^xaicol-wqwc
- When a caller adds an existing file to a collection, the xAI provider shall send `POST /v1/collections/{collection_id}/documents/{file_id}` to `management-api.x.ai`. ^xaicol-ncg2
- When a caller uploads a document directly to a collection, the xAI provider shall send multipart `name`, `data`, `content_type`, and `fields` to `POST /v1/collections/{collection_id}/documents` on `management-api.x.ai`. ^xaicol-25a1
- When a caller lists collection documents, the xAI provider shall send `GET /v1/collections/{collection_id}/documents` to `management-api.x.ai`. ^xaicol-kyt2
- When a caller configures a collection-document list, the xAI provider shall represent `limit`, `order`, `sort_by`, `pagination_token`, and `filter`. ^xaicol-hmj7
- When a caller requests collection-document metadata, the xAI provider shall send `GET /v1/collections/{collection_id}/documents/{file_id}` to `management-api.x.ai`. ^xaicol-ew4r
- When a caller reindexes a collection document, the xAI provider shall send `PATCH /v1/collections/{collection_id}/documents/{file_id}` to `management-api.x.ai`. ^xaicol-dhe2
- When a caller removes a document from a collection, the xAI provider shall send `DELETE /v1/collections/{collection_id}/documents/{file_id}` to `management-api.x.ai`. ^xaicol-3smv
- When a caller batch-retrieves collection documents, the xAI provider shall send `GET /v1/collections/{collection_id}/documents:batchGet` with `file_ids` to `management-api.x.ai`. ^xaicol-qwqj
- When xAI returns a collection document, the xAI provider shall preserve `file_metadata`, `fields`, `status`, `error_message`, and `last_indexed_at`. ^xaicol-9efa
- When a caller performs semantic document search, the xAI provider shall encode `retrieval_mode.type` as `semantic` in `POST /v1/documents/search` on `api.x.ai`. ^xaicol-nmq4
- When a caller performs keyword document search, the xAI provider shall encode `retrieval_mode.type` as `keyword` in `POST /v1/documents/search` on `api.x.ai`. ^xaicol-1zjd
- When a caller performs hybrid document search, the xAI provider shall encode `retrieval_mode.type` as `hybrid` in `POST /v1/documents/search` on `api.x.ai`. ^xaicol-5qhz
- When a caller performs document search, the xAI provider shall represent `query`, `source.collection_ids`, `source.rag_pipeline`, `filter`, `limit`, `instructions`, `group_by`, and retrieval-mode configuration. ^xaicol-snj8
- When xAI returns document-search matches, the xAI provider shall decode `file_id`, `chunk_id`, `chunk_content`, `score`, `collection_ids`, `fields`, and `page_number` into typed results. ^xaicol-gz06

## Open questions

- Does direct multipart collection upload support a different maximum size from
  the Files API?
- What is the published machine-readable schema for the Management Collections
  API?
