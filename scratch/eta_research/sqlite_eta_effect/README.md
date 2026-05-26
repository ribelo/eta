# SQLite Eta Effect Research

Question: where, on what thread, and through which Eta primitive should
sqlite3_step run?

SQLite is an embedded synchronous database. Even when the C stub releases the
OCaml runtime lock during sqlite3_step, the Eio scheduler thread is still in
the C call. A direct call can therefore pin the current Eio domain while SQLite
waits on disk or a lock.

The accepted design must:

- avoid starving other Eio fibers in the calling domain;
- propagate cancellation cleanly through sqlite3_interrupt, with the connection
  surviving;
- keep per-call overhead acceptable for the smallest realistic query;
- express transactions without leaking thread or connection identity into user
  code;
- map SQLITE_BUSY and writer contention onto Eta retry and scheduling
  primitives;
- use Eta.Pool, Eta.Channel, Eta.Semaphore, Resource.t, and Effect.blocking only
  where evidence shows they fit;
- leave room for a future PostgreSQL connector whose implementation can be
  nonblocking while presenting the same Eta-level SQL shape.

Riot reference note: Riot SQL uses actors for the pool/supervisor protocol, but
its SQLite driver executes sqlite3_step directly in the caller after checkout.
Eta is Eio-based, so actor parity is not the target. The target is equivalent
SQL capability and lifecycle semantics with an Eta-native scheduling model.

Eta primitive note: Eta.Channel is documented as same-domain and must not be
used as a cross-thread handoff channel. A connection-pinned worker design needs
a private thread-to-Eio wake-up path, such as a pipe/eventfd plus a protected
request queue, not Eta.Channel.
