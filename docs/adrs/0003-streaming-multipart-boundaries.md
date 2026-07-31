# ADR 0003: Streaming Multipart Boundaries

Status: accepted.

## Context

ADR 0002 made `eta_http` the sole owner of multipart framing and selected a
collision-free boundary after inspecting every buffered payload. OpenAI audio
uploads also accept replayable and one-shot pull sources. A one-shot source's
future bytes are unavailable when the request headers, including the boundary,
must be sent. Proving noncollision first would require reading and retaining or
spooling the complete upload, which would defeat the chosen streaming contract.

## Decision

`Eta_http.Multipart` also owns streaming multipart construction. It selects a
fresh high-entropy boundary with the Eta-owned prefix, validates all available
metadata and text fields before returning a body, and does not preread or spool
the file source.

The streaming body scans file bytes incrementally for the reserved MIME delimiter
prefix derived from that boundary. It retains only the bounded suffix needed to
detect the prefix across the header/source boundary or source chunks. If the
prefix occurs, the body fails before emitting the bytes that would complete it.
The transport therefore aborts with a typed error instead of sending ambiguous
multipart framing. Otherwise the body emits every file byte exactly once and in
order, although it may repartition source chunks.

Replayable sources create a fresh reader for each body attempt. One-shot sources
remain one-shot. Known source lengths produce an exact content length without
opening the source; unknown lengths remain streaming bodies of unknown length. A
known-length one-shot source remains non-replayable while carrying its length to
the transport. The body fails if a source emits fewer or more bytes than its
declared length.

The pull callback exposes no close operation. The caller therefore owns any
resource captured by a reader and must arrange its lifetime across completion,
cancellation, source failure, and boundary-collision failure.

Buffered multipart construction keeps ADR 0002's deterministic,
content-derived, collision-free boundary.

## Rejected

- Preread the source into memory. This would impose an undocumented total memory
  bound and remove pull backpressure.
- Spool the source to a temporary file. This would add filesystem ownership and
  failure modes to a transport-neutral encoder.
- Let each provider implement streaming multipart. Framing and injection safety
  remain HTTP concerns.
- Trust a random boundary without scanning. High entropy makes collision rare;
  incremental detection makes a collision safe.
- Require callers to prove boundary noncollision. The encoder owns its framing
  invariant.
