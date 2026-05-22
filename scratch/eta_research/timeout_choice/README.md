# Eta Timeout Taxonomy Choice Lab

This lab checks whether eta-http needs one timeout knob, new Eta runtime
support, or eta-http-level timeout wrappers built on existing Eta primitives.

Run:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/timeout_choice/timeout_choice.exe
~~~

The fixtures cover stage deadlines, total request timeout, body idle-progress
timeout, and Server-Sent Events heartbeat behavior.

See:

- results.md - evidence and verdict;
- defaults.md - initial eta-http default policy to validate during integration.
