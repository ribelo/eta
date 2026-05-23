# Eta-gzip-bomb

Status: deferred

Trigger: gzip or other response decompression support enters eta-http v1.

Task: add a malicious-server decompression bomb fixture to the H-Q envelope.
The fixture must prove decoded-byte caps, idle timeout behavior, typed
H-D-Errors mapping, and resource plateau after disconnect.

Reason: gzip is outside the current eta-http v1 implementation surface, so
decompression bombs are intentionally out of scope for H-Q2/H-Q5.
