# Eta Crux V1 wire protocol

## Boundary

This file defines the data contract for a serialized driver binding.
[Semantic laws](semantic-laws.md) defines sequencing, rejection, session, and
equivalence behavior.

A frame contains an unsigned 32-bit `seq`, one tag, and the fields for that tag.
Bytes are raw bytes in the semantic frame. A request token and an export handle
contain at most 64 bytes.

## Shared data

```ocaml
type delivery_reason =
  | Advancement
  | Session_replacement

type delivery_result =
  | Accepted
  | Failed of string

type closure_reason =
  | Initiator_cancelled
  | Owner_disposed
  | Root_stopped
  | Root_crashed
  | Session_closed

type endpoint_result =
  | Accepted
  | Full
  | Ingress_closed
  | Malformed_handle
  | Unknown_handle
  | Stale_handle
  | Revoked_handle
  | Malformed_payload

type request_start_result =
  | Started of bytes
  | Request_capacity_full
  | Ingress_capacity_full
  | Ingress_closed
  | Malformed_handle
  | Unknown_handle
  | Stale_handle
  | Revoked_handle
  | Malformed_payload
  | Closed of closure_reason

type request_identity_result =
  | Accepted
  | Not_pending
  | Malformed_request
  | Unknown_request
  | Stale_request

type request_resolve_result =
  | Identity of request_identity_result
  | Malformed_payload
```

`Failure.portable` is the portable crash payload. Application codecs supply the
root-output, request, response, and endpoint payload bytes.

## Frames

```ocaml
type frame =
  | Output_deliver of {
      seq : int32;
      reason : delivery_reason;
      output : bytes;
    }
  | Output_result of {
      seq : int32;
      reply_to : int32;
      result : delivery_result;
    }
  | Crash_notify of {
      seq : int32;
      failure : Failure.portable;
    }
  | Crash_result of {
      seq : int32;
      reply_to : int32;
      result : delivery_result;
    }
  | Endpoint_invoke of {
      seq : int32;
      handle : bytes;
      payload : bytes;
    }
  | Endpoint_result of {
      seq : int32;
      reply_to : int32;
      result : endpoint_result;
    }
  | Request_start of {
      seq : int32;
      handle : bytes;
      payload : bytes;
    }
  | Request_start_result of {
      seq : int32;
      reply_to : int32;
      result : request_start_result;
    }
  | Request_dispatch of {
      seq : int32;
      request : bytes;
      operation : string;
      payload : bytes;
    }
  | Request_dispatch_result of {
      seq : int32;
      reply_to : int32;
      accepted : bool;
    }
  | Request_resolve of {
      seq : int32;
      request : bytes;
      payload : bytes;
    }
  | Request_resolve_result of {
      seq : int32;
      reply_to : int32;
      result : request_resolve_result;
    }
  | Request_cancel of {
      seq : int32;
      request : bytes;
    }
  | Request_cancel_result of {
      seq : int32;
      reply_to : int32;
      result : request_identity_result;
    }
  | Request_resolved of {
      seq : int32;
      request : bytes;
      payload : bytes;
    }
  | Request_closed of {
      seq : int32;
      request : bytes;
      reason : closure_reason;
    }
```

`Request_resolved` and `Request_closed` are terminal notifications for an
inbound request. They have no result frame.

The operation name grammar is `[a-z][a-z0-9._-]*`. Its maximum UTF-8 length is
128 bytes. Names are unique in one adapter binding.

## Tags

| Constructor | Tag |
|---|---|
| `Output_deliver` | `output.deliver` |
| `Output_result` | `output.result` |
| `Crash_notify` | `crash.notify` |
| `Crash_result` | `crash.result` |
| `Endpoint_invoke` | `endpoint.invoke` |
| `Endpoint_result` | `endpoint.result` |
| `Request_start` | `request.start` |
| `Request_start_result` | `request.start_result` |
| `Request_dispatch` | `request.dispatch` |
| `Request_dispatch_result` | `request.dispatch_result` |
| `Request_resolve` | `request.resolve` |
| `Request_resolve_result` | `request.resolve_result` |
| `Request_cancel` | `request.cancel` |
| `Request_cancel_result` | `request.cancel_result` |
| `Request_resolved` | `request.resolved` |
| `Request_closed` | `request.closed` |

## JSON encoding

One JSON object represents one frame. `seq` and `tag` are the first encoded
fields. The remaining fields follow the record order above. Result variants use
a required `outcome` string and only the payload field for that outcome.

Unsigned 32-bit values use JSON integers. Bytes use unpadded base64url strings.
Text uses JSON strings. Booleans use JSON booleans.

## S-expression encoding

One flat list represents one frame. The first two atoms are `seq` and `tag`.
The remaining atoms follow the record order above. A result variant starts with
its outcome atom and then its optional payload atom.

Unsigned 32-bit values use decimal atoms. Booleans use `true` and `false`.
Bytes and arbitrary diagnostic text use unpadded base64url atoms. Closed
category values use their lowercase snake-case names.

## Protocol errors

`Wire.protocol_error` has these cases:

- `Frame_too_large`
- `Malformed_frame`
- `Unknown_tag`
- `Invalid_field`
- `Noncanonical_bytes`
- `Invalid_operation_name`
- `Bad_sequence`
- `Unknown_reply`
- `Wrong_result_family`
- `Sequence_exhausted`

Local payload decoder messages never enter a frame. A failed delivery carries
one adapter-owned, bounded, redacted diagnostic string.
