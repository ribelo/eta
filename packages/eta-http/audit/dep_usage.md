# Dependency Usage Audit

Run: `bash packages/eta-http/audit/run.sh`
Last updated: 2026-05-23T15:08:15Z
Current sites: 71

Every eta-http call site for an allowed external dependency is listed here.
The catalog is not a gate; it is the truth-of-record.

Search:

```sh
rg -n -t ocaml 'H2\.|Hpack\.|Tls\.|Tls_eio\.|Eio\.|Cstruct\.|X509\.|Ca_certs\.|Mirage_crypto|Domain_name\.|Ipaddr\.|Bigstringaf\.|Eqaf\.' packages/eta-http
```

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| `tls/config.ml:19` | `tls` | Build the ADR 0002 client config with the pinned version/cipher policy. | structural | high; this is the TLS substrate chokepoint. |
| `tls/config.mli:3` | `tls` | Expose the policy TLS version type. | structural | high; public invariant documents the TLS substrate type. |
| `tls/config.mli:6` | `tls` | Expose the policy cipher-suite type. | structural | high; public invariant documents the TLS substrate type. |
| `tls/config.mli:13` | `domain-name` | Accept typed hostnames for SNI/hostname verification. | structural | medium; replacing requires another X.509-compatible hostname representation. |
| `tls/config.mli:14` | `ipaddr` | Accept typed IP literals for certificate validation. | structural | medium; replacing requires another X.509-compatible IP representation. |
| `tls/config.mli:16` | `x509` | Accept the TLS stack authenticator. | structural | high; authenticator is owned by the TLS/X.509 stack. |
| `tls/config.mli:18` | `tls` | Return a TLS client config. | structural | high; this is the TLS substrate boundary. |
| `test/tls/negative_dhe_cipher_override.ml:2` | `ca-certs` | Build an authenticator for the compile-fail policy fixture. | test-only | low; fixture can use any valid authenticator. |
| `client/client.mli:23` | `eio` | Accept the caller-owned switch for the pooled S1 h1 client. | structural | medium; connection lifetime is switch-scoped. |
| `client/client.mli:24` | `eio` | Accept the caller-owned network capability for the pooled S1 h1 client. | structural | medium; eta-http must not own ambient network authority. |
| `client/client.mli:25` | `x509` | Accept the TLS authenticator for the pooled S1 h1 client. | structural | high; certificate validation stays in the TLS/X.509 stack. |
| `test/tls/negative_tls13_override.ml:2` | `ca-certs` | Build an authenticator for the compile-fail policy fixture. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:165` | `eio` | Build an in-memory flow sink for the h1 direct-writer parity test. | test-only | low; keeps transport writer output covered without a socket. |
| `test/test_eta_http.ml:276` | `eio` | Build a deterministic mock TCP address for DNS resolver tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:314` | `eio` | Build a deterministic mock TCP address for connect success tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:327` | `eio` | Build a deterministic mock TCP address for connect failure tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:445` | `eio` | Build a deterministic mock TCP address for the public h1 client path test. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:460` | `ca-certs` | Build an authenticator for the public h1 client path test. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:495` | `eio` | Build a deterministic mock TCP address for h1 pool reuse tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:512` | `ca-certs` | Build an authenticator for h1 pool reuse tests. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:548` | `eio` | Build a deterministic mock TCP address for h1 pool health-rejection tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:555` | `ca-certs` | Build an authenticator for h1 pool health-rejection tests. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:589` | `eio` | Build a deterministic mock TCP address for the h1 body-EOF release test. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:596` | `ca-certs` | Build an authenticator for the h1 body-EOF release test. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:627` | `eio` | Build a deterministic mock TCP address for the h1 body-discard release test. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:634` | `ca-certs` | Build an authenticator for the h1 body-discard release test. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:658` | `tls` | Verify policy ciphers exclude FFDHE key exchange. | test-only | low; inspection can move to a helper if needed. |
| `test/test_eta_http.ml:662` | `ca-certs` | Build an authenticator for the TLS policy invariant test. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:666` | `tls` | Exercise the public eta-http TLS config builder. | test-only | low; test subject. |
| `test/test_eta_http.ml:667` | `tls` | Inspect the generated client config. | test-only | low; invariant test inspection. |
| `test/test_eta_http.ml:671` | `tls` | Assert the generated config is TLS 1.2 only. | test-only | low; invariant test inspection. |
| `test/test_eta_http.ml:675` | `tls` | Assert the generated config uses exactly the policy ciphers. | test-only | low; invariant test inspection. |
| `test/test_eta_http.ml:681` | `tls` | Assert the generated config has no TLS 1.3 ciphers. | test-only | low; invariant test inspection. |
| `h1/client.mli:22` | `eio` | Expose the request-on-flow test seam over an Eio two-way flow. | structural | medium; this is the h1 transport boundary. |
| `h1/client.mli:36` | `eio` | Expose the pool health-check flow hook for deterministic tests and probes. | structural | medium; keeps health checks at the h1 transport boundary. |
| `h1/client.mli:38` | `eio` | Accept the caller-owned switch for h1 pool construction. | structural | medium; pool connection lifetime is switch-scoped. |
| `h1/client.mli:39` | `eio` | Accept the caller-owned network capability for h1 pool construction. | structural | medium; eta-http must not own ambient network authority. |
| `h1/client.mli:40` | `x509` | Accept the TLS authenticator for HTTPS h1 pool connections. | structural | high; certificate validation stays in the TLS/X.509 stack. |
| `h1/client.mli:57` | `eio` | Accept the caller-owned switch for direct h1 connect/request execution. | structural | medium; connection lifetime is switch-scoped. |
| `h1/client.mli:58` | `eio` | Accept the caller-owned network capability for direct h1 connect/request execution. | structural | medium; eta-http must not own ambient network authority. |
| `h1/client.mli:59` | `x509` | Accept the TLS authenticator for direct HTTPS h1 requests. | structural | high; certificate validation stays in the TLS/X.509 stack. |
| `h1/client.ml:11` | `eio` | Define the h1 flow boundary as an Eio two-way closeable flow. | structural | medium; h1 transport is Eio-backed in v1. |
| `h1/client.ml:71` | `eio` | Close the response flow when a non-pooled body stream is released. | structural | medium; pooled paths use pool release instead. |
| `h1/client.ml:78` | `eio` | Close pooled connection flows when Eta.Pool closes an entry. | structural | medium; pool owns idle resource release. |
| `h1/write.ml:22` | `eio` | Write h1 request fragments directly to a flow sink. | structural | medium; this is the S1 transport writer path. |
| `h1/write.ml:25` | `eio` | Write fixed request-body chunks without building a complete request string. | structural | medium; body chunk ownership remains caller-owned. |
| `h1/write.mli:45` | `eio` | Expose the direct h1 writer sink boundary. | structural | medium; this keeps the transport writer measurable without a full request string. |
| `h1/client.ml:131` | `eio` + `cstruct` | Read transport bytes into the S1 32 KiB response read buffer. | structural | medium; Eio exposes flow reads through `Cstruct.t`. |
| `h1/client.ml:135` | `cstruct` | Copy bytes from the Eio read buffer into the parser-owned `bytes` buffer. | replaceable | medium; a future parser over `Cstruct.t`/bigstring could remove this copy. |
| `h1/client.ml:142` | `cstruct` | Allocate the temporary body read buffer for fixed-length S1 eager bodies. | replaceable | medium; S3 streaming bodies should replace this eager body path. |
| `h1/client.ml:148` | `eio` + `cstruct` | Read remaining fixed-length body bytes after the header buffer is consumed. | replaceable | medium; S3 streaming bodies should replace this eager body path. |
| `h1/client.ml:152` | `cstruct` | Copy body read bytes into the S1 eager body buffer. | replaceable | medium; S3 streaming bodies should replace this eager body path. |
| `h1/client.ml:191` | `cstruct` | Allocate the 32 KiB transport read buffer used by the h1 parser loop. | structural | medium; tied to Eio's flow read API. |
| `h1/client.ml:264` | `eio` | Create a one-byte buffered reader for the idle-connection health probe. | replaceable | medium; R5 stale-idle proof passes, but a future parser may replace this probe. |
| `h1/client.ml:265` | `eio` | Probe idle h1 connections without sending application bytes. | replaceable | medium; R5 stale-idle proof passes, but a future parser may replace this probe. |
| `transport/connect.ml:13` | `eio` | Define the TCP flow boundary as an Eio two-way closeable flow. | structural | medium; transport is Eio-backed in v1. |
| `transport/connect.ml:40` | `eio` | Resolve stream socket addresses through Eio.Net.getaddrinfo_stream. | structural | medium; this is the v1 DNS boundary. |
| `transport/connect.ml:50` | `eio` | Open TCP stream sockets through the caller-owned Eio network. | structural | medium; transport is Eio-backed in v1. |
| `transport/connect.ml:73` | `ipaddr` | Detect IP-literal peers for certificate validation. | structural | medium; replacing requires another X.509-compatible IP representation. |
| `transport/connect.ml:76` | `domain-name` | Parse DNS host peers for SNI and hostname verification. | structural | medium; replacing requires another X.509-compatible hostname representation. |
| `transport/connect.ml:79` | `domain-name` | Validate DNS host peers before SNI and hostname verification. | structural | medium; replacing requires another X.509-compatible hostname representation. |
| `transport/connect.ml:92` | `tls-eio` | Wrap host-name TCP flows in the TLS client. | structural | high; this is the TLS substrate chokepoint consumer. |
| `transport/connect.ml:98` | `tls-eio` | Wrap IP-literal TCP flows in the TLS client. | structural | high; this is the TLS substrate chokepoint consumer. |
| `transport/connect.mli:11` | `eio` | Expose the TCP flow boundary as an Eio two-way closeable flow. | structural | medium; transport is Eio-backed in v1. |
| `transport/connect.mli:16` | `eio` | Accept an explicit Eio network capability instead of ambient DNS authority. | structural | medium; keeps DNS authority owned by the caller runtime. |
| `transport/connect.mli:19` | `eio` | Return Eio stream socket addresses from DNS resolution. | structural | medium; callers pass these to the TCP connection step. |
| `transport/connect.mli:20` | `eio` | Document the Eio DNS primitive used by the resolver boundary. | structural | low; comment-only dependency mention. |
| `transport/connect.mli:26` | `eio` | Accept the caller-owned switch for TCP connection lifetime. | structural | medium; connections are switch-scoped. |
| `transport/connect.mli:27` | `eio` | Accept the caller-owned network capability for TCP connect. | structural | medium; eta-http must not own ambient network authority. |
| `transport/connect.mli:38` | `x509` | Accept the TLS authenticator for TLS connection setup. | structural | high; certificate validation stays in the TLS/X.509 stack. |
| `transport/connect.mli:42` | `tls-eio` | Return the TLS-wrapped Eio flow from the transport layer. | structural | high; this is the TLS substrate boundary. |
