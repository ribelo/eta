---
kind: requirement
---
# URL query-component encoding

## Intent

Provide one RFC 3986 query-component encoder for every Eta HTTP and provider
adapter that constructs URLs.

## Requirements

- The `Eta_http.Core.Url` module shall expose an authoritative query-component percent encoder. ^urlqry-0nyd
- When the query-component encoder receives an ASCII letter, ASCII digit, hyphen, period, underscore, or tilde, the encoder shall preserve that octet. ^urlqry-rrny
- When the query-component encoder receives any other octet, the encoder shall emit its uppercase `%HH` representation. ^urlqry-p1y6
- When the query-component encoder receives a space, the encoder shall emit `%20`. ^urlqry-081f
- When the query-component encoder receives UTF-8 text, the encoder shall percent-encode each non-unreserved UTF-8 octet independently. ^urlqry-3zpz
- When OpenAI Codex, Kimi, OpenAI Realtime Eio, or xAI Eio constructs query components, the adapter shall use `Eta_http.Core.Url` query-component encoding. ^urlqry-8bzi
- The `Eta_http.Core.Url` module shall expose a query builder that omits absent fields and encodes every included name and value with its query-component encoder. ^urlqry-ggrc
- When the URL query builder includes fields, the builder shall preserve their input order. ^urlqry-21lq
- When the URL query builder receives repeated present names, the builder shall preserve every repeated field. ^urlqry-iu89
