# Excerpt from docs/type-errors.md (entry 1)

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
