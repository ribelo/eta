---
kind: issue
status: change-1-complete
requirements:
  - crxcdc-vw4r
  - crxcdc-gszc
  - crxcdc-llol
  - crxcdc-dgf0
  - crxcdc-108i
  - crxcdc-9ut1
  - crxcdc-arnj
  - crxcdc-igo1
  - crxcdc-fy9i
  - crxcdc-i6hr
  - crxcdc-l8wg
  - crxcdc-12ru
  - crxcdc-rjfk
  - crxcdc-3724
---

# Fallible Eta Crux codec

## Problem Statement

An Eta Crux application supplies one `Codec.t` for each payload that crosses a
serialized session. Decoding can fail and returns a typed `decode_error`.
Encoding cannot fail: `Codec.make` takes `encode:('a -> bytes)`.

This forces every application encoder into one of two bad shapes. It raises an
exception, which becomes a defect and crashes the root for a condition the
application can describe. Or it invents a substitute payload, which sends wrong
bytes to the shell.

The gap also blocks typed projection delivery. A projection key or value is
encoded after commit, so the design needs one typed encode failure that fails
the delivery without inventing bytes.

## Solution

Make the shared codec fallible in both directions. `Codec.encode` returns
`(bytes, encode_error) result`, and `Codec.make` accepts an `encode` function of
the same shape.

Each caller of a codec then reports one exact typed outcome. An outbound request
encode failure returns `Requester.Encode_failed` and leaves no request behind. A
response decode failure returns `Requester.Decode_failed` and closes only that
request. An inbound response encode failure returns `Responder.Encode_failed`
and leaves the request pending, so its owner can answer again.

## Requirements

In this section, "the system" is the `eta_crux` package with its serialized
transport packages `eta_crux_json` and `eta_crux_sexp`.

### Codec surface

- The system shall accept an `encode` function of type `'a -> (bytes, Codec.encode_error) result` in `Codec.make`. ^crxcdc-vw4r
- The system shall return `(bytes, Codec.encode_error) result` from `Codec.encode`. ^crxcdc-gszc
- The system shall define `Codec.encode_error` as one record with one `message` field. ^crxcdc-llol

### Typed caller outcomes

- The system shall include `Encode_failed of Codec.encode_error` and `Decode_failed of Codec.decode_error` in `Requester.error`. ^crxcdc-dgf0
- The system shall define `Responder.error` as exactly `Not_pending` and `Encode_failed of Codec.encode_error`. ^crxcdc-108i
- If an outbound host-operation request encode returns an encode error, then the system shall return `Requester.Encode_failed` with that error. ^crxcdc-9ut1
- If an outbound host-operation request encode returns an encode error, then the system shall allocate no request identity, consume no request capacity, and emit no driver event. ^crxcdc-arnj
- If a host-operation response decode returns a decode error, then the system shall return `Requester.Decode_failed` with that error. ^crxcdc-igo1
- If a host-operation response decode returns a decode error, then the system shall close only that request and shall keep the session open. ^crxcdc-fy9i
- If an inbound request-export response encode returns an encode error, then the system shall return `Responder.Encode_failed` and shall keep that request pending. ^crxcdc-i6hr
- If an inbound endpoint or request payload decode returns a decode error, then the system shall answer `Malformed_payload`, enqueue nothing, keep the session open, and keep the root running. ^crxcdc-l8wg
- If a codec raises at an export or request boundary, then the system shall latch the failure origin and trigger of that boundary and shall retain the local exception cause. ^crxcdc-12ru

### Verification artifacts

- The system shall carry registry rows R-10 with gate `test_requester_encode_failed`, R-11 with gate `test_requester_decode_failed`, and R-12 with gate `test_responder_encode_failed` in the same change as the `eta_crux.mli` prose that states their laws. ^crxcdc-rjfk
- When this change is complete, the repository shall contain one full `bench/run.sh` result file in `bench/results/` as the recorded pre-projection performance baseline. ^crxcdc-3724

## Implementation Decisions

Provenance: [Identity, codec, and wire
contract](../../wayfinder/eta-crux-typed-projection-delivery/issues/10-identity-codec-and-wire-contract.md)
section "Shared codec effects", and change 1 plus task T0 of the [implementation
plan](../../wayfinder/eta-crux-typed-projection-delivery/issues/15-implementation-plan.md).

**Scope.** This change is a standalone breaking migration. It adds no
projection type and changes no delivery semantics.

**Modules.** `Codec`, `Requester`, and `Responder` in `lib/crux/eta_crux.mli`
with their `crux_*.ml` implementations. Every `Codec.make` caller in `lib/`,
`test/`, and `lib/crux/bench` compile-migrates in the same change.

**No compatibility path.** The old infallible `encode` signature is deleted.
The change adds no shim, no default encoder, and no `encode_exn`.

**Failure classes stay separate.** A returned encode error is a typed caller
outcome. A raising codec stays a defect with the local cause retained. The
change converts neither into the other.

**Inbound decode is unchanged.** `Malformed_payload` remains the answer for a
failed inbound endpoint or request payload decode.

**Baseline recording.** Task T0 runs `nix develop -c bash bench/run.sh` after
the migration is green and commits the result file. That file is the recorded
pre-projection reference for the later `projection_absent_allocation` gate, so
it must be recorded before any projection work starts.

## Testing Decisions

A good test observes the public `Eta_crux` surface: the value that `request` or
`resolve` returns, the request state after the failure, the session state, and
the driver event log. It asserts nothing about codec internals.

**Seams.**

1. The public `Eta_crux` requester and responder surface, driven through the
   existing `Eta_crux_test.Handle` and its serialized shell. Codec failure is
   injected by a test codec that returns `Error` on a chosen call.
2. The existing serialized session peer in `test/crux/wire`, used to prove that
   the session stays open and that no frame is written for a failed outbound
   encode.

**Named gates.** `test_requester_encode_failed`, `test_requester_decode_failed`,
and `test_responder_encode_failed`, in `test/crux/unit`.

**Prior art.** The existing R-family gates in `test/crux/unit`, in particular
`test_outbound_request_round_trip` and `qcheck_request_capacity`, and the
existing codec-driven gates E-02, E-03, and W-10, which compile-migrate here
with unchanged prose.

**Census discipline.** Each new gate ends with an available empty fiber census.

## Out of Scope

- Projection types, projection delivery, and projection wire frames. They belong
  to [Typed projection delivery](02-typed-projection-delivery.md).
- New benchmark workloads or performance gates.
- A change to inbound `Malformed_payload` answers.
- An `eta_schema` integration package. Applications adapt their own schema to
  `Codec.t`.

## Further Notes

Order matters. This change lands first, then task T0 records the baseline, then
[Typed projection delivery](02-typed-projection-delivery.md) lands. Recording the
baseline between the two changes isolates the projection allocation delta from
the codec delta.

T0 result: `bench/results/20260815T184109Z-b5c4e3d6.json`. The official
`bench/run.sh` hang on `eta_crux.capacity.serialized_handles` is reproduced on
HEAD before this change (`removed export survived replacement and major
collection`, or a hang after `capacity.request.1024`). The recorded file includes
every other `run.sh` suite and every other `bench_eta_crux` workload.
