# Backend Split

`test/http/tls` is negative compile-time coverage for TLS configuration. It
runs `run_negative_compile.sh` against fixtures that must fail to compile.

This is not runtime behavior and is not meaningful to instantiate across
runtime backends. Positive backend-neutral TLS policy checks live in `test/http_common`;
Eio/OpenSSL integration checks live in `test/http`.
