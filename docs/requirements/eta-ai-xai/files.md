---
kind: requirement
---
# xAI files

## Intent

Manage inference-side files used by Responses inputs and collection ingestion
through the stable Files API.

## Requirements

- When a caller uploads a file, the xAI provider shall send a multipart request to `POST /v1/files`. ^xaifile-4w58
- When a caller configures uploaded-file expiry, the xAI provider shall encode `expires_after` before the `file` part. ^xaifile-d315
- When a caller supplies a file purpose, the xAI provider shall encode `purpose` in the multipart upload. ^xaifile-101g
- When xAI returns a file resource, the xAI provider shall preserve `id`, `object`, `bytes`, `created_at`, `expires_at`, `filename`, `purpose`, `public_url`, and `public_url_expires_at`. ^xaifile-9t4o
- When a caller lists files, the xAI provider shall send `GET /v1/files`. ^xaifile-f6md
- When a caller configures a file list, the xAI provider shall represent `limit`, `order`, `sort_by`, `pagination_token`, and `filter` query parameters. ^xaifile-alf7
- When a caller requests file metadata, the xAI provider shall send `GET /v1/files/{file_id}` and decode the file resource. ^xaifile-74qe
- When a caller deletes a file, the xAI provider shall send `DELETE /v1/files/{file_id}` and return the typed deletion result. ^xaifile-kp5x
- When a caller downloads original file content, the xAI provider shall send `GET /v1/files/{file_id}/content?format=original` and preserve the response content type and bytes. ^xaifile-e2kj
- When a caller downloads extracted text, the xAI provider shall send `GET /v1/files/{file_id}/content?format=text` and preserve the response content type and bytes. ^xaifile-js6y
- When a caller creates a public file URL, the xAI provider shall send `POST /v1/files/{file_id}/public-url` and return the typed public-URL resource. ^xaifile-l7uw
- When xAI creates a public file URL, the xAI provider shall preserve `public_url` and `expires_at`. ^xaifile-8ybi
- When a caller configures public-URL expiry, the xAI provider shall encode `expires_after` between 3600 and 2592000 seconds inclusive. ^xaifile-inca
- When a caller revokes a public file URL, the xAI provider shall send `POST /v1/files/{file_id}/public-url/revoke` and return the typed revocation result. ^xaifile-27kp

## Open questions

- What byte count does xAI mean by the Files API's `50 MB` label?
- What are the stable request and response schemas for `PUT /v1/files/{id}`,
  `POST /v1/files:initialize`, and `POST /v1/files:uploadChunks`?
