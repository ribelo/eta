---
kind: requirement
---
# HTTP multipart encoding

## Intent

Provide one multipart/form-data encoder for Eta clients so framing, injection
protection, and boundary safety do not drift between providers.

## Requirements

- The `eta_http` package shall expose one multipart/form-data encoder for text fields and buffered or pull-streamed binary files. ^httpmp-iwop
- If a multipart disposition name or filename contains carriage return, line feed, or a double quote, then the multipart encoder shall reject the part. ^httpmp-7wdx
- If a multipart content type contains carriage return or line feed, then the multipart encoder shall reject the part. ^httpmp-2dee
- When the multipart encoder selects a boundary for buffered parts, the encoder shall ensure that the boundary does not occur in any encoded field metadata, field value, or file data. ^httpmp-r4jh
- When the multipart encoder encodes file data, the encoder shall preserve every input byte in order. ^httpmp-2x03
- When the multipart encoder succeeds for buffered parts, the encoder shall return the selected boundary and a `bytes list` suitable for `Eta_http.Request.Fixed`. ^httpmp-2usd
- When OpenAI transcription or translation constructs multipart/form-data, the OpenAI provider shall use the `eta_http` multipart encoder. ^httpmp-bniy
- When xAI Files, Collections, or speech-to-text constructs multipart/form-data, the xAI provider shall use the `eta_http` multipart encoder. ^httpmp-7v53
- If multipart input is unsafe or cannot be encoded during construction, then the multipart encoder shall return a typed `Eta_http.Multipart.error`. ^httpmp-brma
- When the multipart encoder receives identical buffered parts, the encoder shall select the same collision-free boundary. ^httpmp-64ta
- The multipart encoder shall expose text-field parts with a name and value and binary-file parts with a name, filename, content type, and either a byte payload or a pull source. ^httpmp-nnk1
- When the multipart encoder selects a boundary, the encoder shall use an Eta-owned fixed boundary prefix. ^httpmp-ikp5
- If the multipart encoder receives no parts, then the multipart encoder shall return a typed empty-multipart error. ^httpmp-r7u0
- When the multipart encoder constructs a pull-streamed body, the encoder shall not preread or spool the file source. ^httpmp-qp7m
- When the multipart encoder constructs a pull-streamed body, the encoder shall select a fresh high-entropy boundary and reject a collision with known metadata before returning the body. ^httpmp-w8kx
- While a multipart body emits a pull-streamed file, the encoder shall detect the reserved MIME boundary prefix across the header/source boundary and arbitrary source partitions and fail before emitting the bytes that would complete a collision. ^httpmp-v3na
- When every pull source has a known length, the multipart encoder shall compute the exact body length without opening any source. ^httpmp-u6ds
- When a pull source is replayable, each multipart body attempt shall open a fresh source reader. ^httpmp-r9ce
- If a pull source raises, collides with the reserved boundary prefix, or emits a byte count different from its declared length, then the multipart body shall fail with a typed `Eta_http.Error.t`. ^httpmp-f2jk
- When a one-shot pull source has a known length, the multipart body shall carry that length to the transport without becoming replayable. ^httpmp-k4xb
