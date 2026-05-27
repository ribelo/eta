# P-Scoped-3 Notes: Camelpie/WebSocket refactor under Branch C

## Procedure

Wrote the refactor diff from `Effect.Private.daemon` to `Supervisor.scoped` +
`Effect.acquire_release` for the WebSocket client (`lib/http/ws/ws_client.ml`).
This is the winning branch from P-Scoped-1/P-Scoped-2.

## Key findings

1. **Mechanical refactor is straightforward.** The daemon is replaced by
   `Supervisor.scoped` with one child (the reader loop) and an
   `acquire_release` for the close fence. +10 LOC in the library.

2. **Public API must change shape.** From handle-returning to callback-shaped.
   This is the core friction that motivated the lab.

3. **Compositional cost is real.** Multiple connections require nested
callbacks. This is the main UX regression vs. daemon.

4. **WebSocket-specific cleanup remains in consumer code.** A generic helper
   cannot centralize WebSocket close-frame logic, drain semantics, or
   finish-vs-cancel asymmetry. These are protocol-specific, not
   framework-generic.

5. **Typed failure propagation needs explicit handling.** The naive refactor
cancels the child without awaiting, dropping reader failures. A correct
implementation needs `cancel` + `await` + error handling, adding ~2 lines.

## Remaining friction not anticipated by consumer survey

- **Graceful close sequence:** The helper must send a WebSocket close frame
  BEFORE cancelling the reader, or the reader sees an abrupt EOF. This
  ordering is subtle and WebSocket-specific.
- **Queue drain on close:** After sending close frame, the helper should
  drain the incoming queue for a bounded time to catch the peer's close
  response. This is not needed for generic session cleanup.

## Conclusion

The refactor validates that Branch C is **viable but not free**. The cost is
acceptable for one consumer. The fact that WebSocket-specific cleanup cannot
be centralized strongly supports the Branch C verdict: document the recipe,
let each consumer own its protocol-specific cleanup.
