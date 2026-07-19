# DX-E9b Review Packet Manifest

Blinded files for independent review (orchestrator labels them):

| File | Role |
| --- | --- |
| `transfer.ml` | Order-sensitive debit/credit transfer written with `and*` (the safe shape). |
| `loads.ml` | Concurrent user/perms loads written with `Effect.par`. |
| `QUESTIONS.md` | Fixed questions; either side can win if answers are wrong. |

Scope: top-level `Eta.Syntax` operators and `Effect.par` only. No submodule
split. No compatibility shim for concurrent `and*`.
