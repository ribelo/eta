# Eta Bounded Channel Choice Lab

This lab compares bounded communication primitives for eta-http backpressure.

Run:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/channel_choice/channel_choice.exe
~~~

The candidates are deliberately small:

- mutex + Queue;
- mutex + fixed int ring;
- Eio.Stream as a baseline close-propagation check;
- Eta_stream.Mailbox as a nonblocking/drop baseline.

The decision target is not a general stream abstraction. eta-http needs a
bounded channel/permit primitive that supports blocking send, cancellation-safe
waiters, close propagation, and predictable allocation.
