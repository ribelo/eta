# Eta type errors, translated

The 2am page. Each entry quotes the exact compiler or runtime output
(snapshot-locked in `test/type_errors/`), then says what you tried, why Eta
forbids it, and the two canonical fixes. If the quoted text here no longer
matches what your compiler prints, the snapshot corpus in
`test/type_errors/` is the source of truth — and CI should have failed.

---

## 1. `This field value has type … which is less general than "'s. …"`

```
Error: This field value has type
         "('a, 'b) Eta.Supervisor.t ->
         ('a, ('a, 'b, int) Eta.Supervisor.child, 'b) Eta.Supervisor.Scope.t"
       which is less general than
         "'s. ('s, 'c) Eta.Supervisor.t -> ('s, 'd, 'c) Eta.Supervisor.Scope.t"
```

**What you tried.** Returning a `Supervisor` child handle from the
`scoped { run = … }` body — directly (`pure child`) or indirectly (storing
it in a `ref`, a record field, or a closure that escapes). The message never
mentions your escape route; it only says the body isn't general enough. In
the `ref`-leak variant the message doesn't even contain the word `child`.

**Why Eta forbids it.** `'s` is a fresh brand stamped on every `scoped`
block. Children carry the brand so a handle can only be used while its
supervisor is alive. If the brand escaped, you could `await` a child whose
nursery has already torn down — a use-after-free the type system prevents.

**Fix 1 (usual).** Keep the handle inside the body and return a *value*:
`let* result = await child in pure result`.
**Fix 2.** If you need the child's outcome later, return the whole
`Supervisor.scoped` computation to the caller and let them run it — the
handle never leaves the nursery either way.

---

## 2. `expected [%eta.sync "name" body]` / `[%eta.result "name" body]`

```
Error: expected [%eta.sync "name" body]
Error: expected [%eta.result "name" body]
```

**What you tried.** `[%eta.sync 123]`, `[%eta.result 123]`, a bare name, or any
payload that isn't a string literal applied to a body.

**Why Eta forbids it.** The extension exists to name a synchronous step for
tracing; without a literal name there is nothing to put on the span. The
message names the form you wrote (`sync` vs `result`).

**Fix 1.** `[%eta.sync "deserialize" (decode buf)]` or
`[%eta.result "db.find" (Db.find db id)]` — string literal first, body second.
**Fix 2.** If you don't want a name, drop the extension:
`Effect.sync (fun () -> decode buf)` or `Effect.sync_result (fun () -> ...)`.

---

## 3. `eta.sql.table expects a record type declaration`

```
Error: eta.sql.table expects a record type declaration
```

**What you tried.** `[%%eta.sql.table type t = int]` (or a variant, alias,
or anything that isn't a record).

**Why Eta forbids it.** The extension generates one module per table row;
only a record's fields map to columns.

**Fix 1.** Make it a record: `[%%eta.sql.table type t = { id : int }]`.
**Fix 2.** A single-column table is still a record — wrap the scalar:
`type t = { value : int }`.

---

## 4. `eta.sql.table supports int, int64, string, bool, float, bytes, and option fields`

```
Error: eta.sql.table supports int, int64, string, bool, float, bytes, and
       option fields
```

**What you tried.** A field of type `string list`, a nested record, your own
abstract type, or anything outside the listed six (+ `option`).

**Why Eta forbids it.** The codegen only emits column codecs it can prove
round-trip through SQLite. It refuses to guess yours.

**Fix 1 (usual).** Store a supported encoding (`string` for JSON/text,
`bytes` for binary) and convert in your application layer.
**Fix 2.** Split the shape across two tables with a foreign key.

---

## 5. `attribute primary_key does not take a payload` / `unsupported eta.sql.table column attribute: bogus`

```
Error: attribute primary_key does not take a payload
Error: unsupported eta.sql.table column attribute: bogus
```

**What you tried.** `[@primary_key true]`, `[@not_null "yes"]`, or an
attribute name that doesn't exist.

**Why Eta forbids it.** Flag attributes (`primary_key`, `not_null`,
`unique`) are bare switches — their presence is the value. Anything else is
either a typo or a payload the attribute can't use.

**Fix 1.** Drop the payload: `id : int [@primary_key]`.
**Fix 2.** Check the spelling against the supported set: `primary_key`,
`not_null`, `unique`, `default`, `references`, `on_delete`, `on_update`
(the last four take payloads).

---

## 6. `eta.sql.table all projection supports at most 8 fields`

```
Error: eta.sql.table all projection supports at most 8 fields
```

**What you tried.** A record with nine or more fields.

**Why Eta forbids it.** The generated `all` projection is built from
pre-generated tuple combinators that stop at 8.

**Fix 1 (usual).** Split the table: a wide table is usually two tables
(core row + details) joined by key.
**Fix 2.** Keep ≤ 8 fields in the `[%%eta.sql.table]` record and hand-write
the extra columns with `Eta_sql.Eta_schema.column`.

---

## 7. Nothing at all — the cross-domain hang

Real output from the snapshot corpus (`test/type_errors/`, runtime probes;
the Channel handle is shared across two `eta_par` Island worker domains):

```
===== try-send =====
worker try_send: Ok(Sent)
main try_recv: Ok(Item "from-worker")
exit=0
===== blocking-pair =====
exit=124
```

`exit=124` is twelve seconds of silence followed by our timeout killing the
probe. The non-blocking call crossed domains fine; the first blocking pair
never woke up.

**What you tried.** Capturing a `Channel` (or `Pubsub`, or `Pool`) handle in
an `Eta_par.Island.run` / `Domain.spawn` callback and running channel
effects against it from the other domain — usually via a second runtime you
built there.

**Why Eta forbids it.** It doesn't — that's the trap. `Channel`, `Pubsub`,
and `Pool` are *same-domain* primitives: a fiber blocked on one parks on
its own runtime's scheduler, and a wakeup from another domain is never
delivered. Non-blocking calls (`try_send`) can look like they work; the
first blocking call hangs silently. `Queue` is the designed cross-domain
primitive and completes the same probe cleanly.

**Fix 1.** Cross domains with `Eta.Queue` (documented cross-domain); keep
`Channel`/`Pubsub`/`Pool` handles on the domain and runtime that created
them.
**Fix 2.** Offload only plain values and pure callbacks through
`Island.run`; move the channel traffic back to the owning domain with the
returned value.

---

## 8. Nothing at all — the escaped resource handle

**What you tried.** Returning the handle from
`Effect.with_resource ~acquire ~release (fun conn -> Effect.pure conn)` or
from `Pool.with_resource`, then using it later. This **compiles**. There is
no error message — this entry exists so you don't go looking for one.

**Why Eta allows it.** Handle lifetimes here are runtime-managed, not
rank-2 branded (that's only `Supervisor` children). When the body returns,
`release` runs (or the connection goes back to the pool); your escaped
reference now aliases a closed resource — or whatever the *next* borrower
is doing with it.

**Fix 1 (usual).** Return data, not handles: extract what you need inside
the body and return that.
**Fix 2.** If the resource must outlive one callback, acquire it under a
wider `Effect.with_scope` (or keep it pooled and re-borrow per use) instead
of smuggling the handle out of the bracket.
