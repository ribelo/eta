# DX-E7b journal

## Sealed predictions

Sealed before any source, test, example, or durable API documentation change.

1. **Signature generation.** A `sig_type_decl` generator that emits
   `val pp_<type> : Format.formatter -> <type> -> unit`, while applying the same
   declaration validation as the structure generator, will make
   `[@@deriving eta_error]` usable in an `.mli` without changing generated `.ml`
   behavior.
2. **Consumer evidence.** A paired `.ml`/`.mli` test deriving the same `err`
   alias and calling `pp_err` from another compilation unit will fail before the
   signature generator and pass after it; this is stronger evidence than an
   expansion snapshot alone.
3. **Render escape hatch.** The existing implementation already accepts an
   identifier-valued `[@eta.render]` on a one-payload tag. A record payload case
   will expand to `%a` with the custom printer, while the same payload without
   the attribute will be rejected with the existing unsupported-payload
   what/where/what-next diagnostic.
4. **Contract precision.** The implementation already rejects private aliases,
   inherited rows, open rows, and restricted rows. Documentation and the generic
   “closed” rejection text can be made accurate as “public, explicit-tag closed
   polymorphic-variant alias” without expanding payload or row support.
5. **Example reversions.** Both named examples are infallible at the typed-error
   level. Their invented variants, deriving annotations, and derived-printer
   wiring can be removed; if the runtime error branch still needs a `Cause`
   printer, an explicit uninhabited typed-error renderer will be sufficient.
6. **Risk and gates.** The highest implementation risk is constructing a
   ppxlib signature AST whose type refers correctly to the declaration under
   derivation. Existing PPX expansion snapshots may renumber generated symbols
   only if shared structure-generation code changes; otherwise the exact Nix
   gates should remain green.
