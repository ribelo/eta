# Portable Effect island optional branch

Status: not attempted.

Design C is conditional. The real 9vo ticket says to attempt a small
Effect.Portable.t DSL only if the Design B portable callback island cannot cover
typed failure, cancellation honesty, or useful composition.

Current Design B evidence covers:

- portable callbacks;
- ordered finite batch results;
- typed result-returning callbacks;
- all_settled-style collection;
- Portable.Atomic capture;
- compiler rejection of ref, Eio.Stream, Runtime, Logger, and raw Cause capture;
- ergonomic examples without PPX.

Because that covers the first useful island prototype, Design C remains
deferred. Reopen this directory only if a real island user story needs nested
portable composition that cannot be expressed as ordinary portable callbacks
returning result values.
