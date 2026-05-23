# Dependency Usage Audit

Run: `bash packages/eta-http/audit/run.sh`
Last updated: 2026-05-23T19:11:00Z
Current sites: 283

Every eta-http call site for an allowed external dependency is listed here.
The catalog is not a gate; it is the truth-of-record.

Search:

```sh
rg -n -t ocaml 'H2\.|Hpack\.|Tls\.|Tls_eio\.|Eio\.|Cstruct\.|X509\.|Ca_certs\.|Mirage_crypto|Domain_name\.|Ipaddr\.|Bigstringaf\.|Eqaf\.|Gz\.|De\.' packages/eta-http | rg -v 'Eta_http\.H2\.'
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
| `client/client.mli:33` | `eio` | Accept the caller-owned switch for the S2 auto-dispatch client. | structural | medium; connection lifetime is switch-scoped. |
| `client/client.mli:34` | `eio` | Accept the caller-owned network capability for the S2 auto-dispatch client. | structural | medium; eta-http must not own ambient network authority. |
| `client/client.mli:35` | `x509` | Accept the TLS authenticator for the S2 auto-dispatch client. | structural | high; certificate validation stays in the TLS/X.509 stack. |
| `body/transducer.ml:22` | `bigstringaf` | Copy eta-http byte chunks into the bigstring input shape expected by `decompress`. | structural | medium; `decompress` consumes bigstrings for streaming gzip. |
| `body/transducer.ml:26` | `bigstringaf` | Copy gzip output bigstrings back into eta-http byte chunks. | structural | medium; `decompress` emits through a bigstring output buffer. |
| `body/transducer.ml:33` | `decompress` | Allocate the gzip decoder output buffer through `De.bigstring_create`. | structural | medium; gzip codec buffers are owned by `decompress`. |
| `body/transducer.ml:34` | `decompress` | Read the gzip decoder output-buffer length. | structural | low; tied to `decompress` buffer accounting. |
| `body/transducer.ml:35` | `decompress` | Create the streaming gzip decoder over a manual source. | structural | high; gzip format and CRC validation are owned by `decompress`. |
| `body/transducer.ml:50` | `decompress` | Read decoder output-buffer remaining bytes to size emitted chunks. | structural | medium; tied to `decompress` streaming API. |
| `body/transducer.ml:64` | `decompress` | Advance the gzip decoder state machine. | structural | high; gzip framing and checksums are owned by `decompress`. |
| `body/transducer.ml:70` | `decompress` | Mark the decoder output buffer flushed after copying a chunk. | structural | medium; tied to `decompress` streaming API. |
| `body/transducer.ml:73` | `decompress` | Resume decoding after an empty flush. | structural | medium; tied to `decompress` streaming API. |
| `body/transducer.ml:89` | `decompress` | Feed an input chunk into the gzip decoder. | structural | high; gzip decode is delegated to `decompress`. |
| `body/transducer.ml:94` | `decompress` | Signal gzip decoder input EOF. | structural | high; truncated-stream detection is owned by `decompress` plus eta-http error mapping. |
| `body/transducer.ml:102` | `decompress` | Allocate the gzip encoder output buffer. | structural | medium; gzip codec buffers are owned by `decompress`. |
| `body/transducer.ml:103` | `decompress` | Read the gzip encoder output-buffer length. | structural | low; tied to `decompress` buffer accounting. |
| `body/transducer.ml:104` | `decompress` | Allocate the DEFLATE queue used by the gzip encoder. | structural | high; compression internals are owned by `decompress`. |
| `body/transducer.ml:105` | `decompress` | Allocate the LZ77 window used by the gzip encoder. | structural | high; compression internals are owned by `decompress`. |
| `body/transducer.ml:108` | `decompress` | Create the streaming gzip encoder over manual source/destination buffers. | structural | high; gzip framing and CRC emission are owned by `decompress`. |
| `body/transducer.ml:109` | `decompress` | Provide the first gzip encoder output buffer. | structural | medium; tied to `decompress` streaming API. |
| `body/transducer.ml:114` | `decompress` | Read encoder output-buffer remaining bytes to size emitted chunks. | structural | medium; tied to `decompress` streaming API. |
| `body/transducer.ml:123` | `decompress` | Advance the gzip encoder state machine. | structural | high; gzip framing and CRC emission are owned by `decompress`. |
| `body/transducer.ml:127` | `decompress` | Provide a fresh output buffer after an encoder flush. | structural | medium; tied to `decompress` streaming API. |
| `body/transducer.ml:130` | `decompress` | Resume encoding after an empty flush. | structural | medium; tied to `decompress` streaming API. |
| `body/transducer.ml:146` | `decompress` | Feed an input chunk into the gzip encoder. | structural | high; gzip encode is delegated to `decompress`. |
| `body/transducer.ml:151` | `decompress` | Signal gzip encoder input EOF. | structural | high; gzip trailer emission is owned by `decompress`. |
| `client/client.ml:83` | `h2` | Render h2 client errors from the ocaml-h2 substrate. | structural | high; h2 error variants originate in `ocaml-h2`. |
| `client/client.ml:100` | `h2` | Build h2 request headers with the ocaml-h2 header representation. | structural | high; h2 header encoding is substrate-owned. |
| `client/client.ml:115` | `h2` | Build the ocaml-h2 request value for the auto-dispatch h2 route. | structural | high; h2 request serialization is substrate-owned. |
| `client/client.ml:125` | `h2` | Write fixed request-body chunks through the h2 body writer. | structural | high; DATA scheduling is owned by `ocaml-h2`. |
| `client/client.ml:128` | `h2` | Convert h2 response headers back to eta-http headers. | structural | high; header decode is owned by `ocaml-h2`. |
| `client/client.ml:167` | `h2` | Convert h2 response status to an integer status code. | structural | high; response metadata comes from `ocaml-h2`. |
| `client/client.ml:173` | `h2` | Close no-body h2 response readers for HEAD/204/304 handling. | structural | high; h2 body-reader lifecycle is substrate-owned. |
| `client/client.ml:175` | `h2` | Check h2 body-reader closure before scheduling reads. | structural | high; h2 body-reader lifecycle is substrate-owned. |
| `client/client.ml:178` | `h2` | Schedule h2 body reads into the eager S2 response buffer. | structural | high; h2 body delivery is callback-driven by `ocaml-h2`. |
| `client/client.ml:185` | `h2` | Close oversized h2 response bodies at the h2 reader boundary. | structural | high; local cancellation maps to h2 body-reader close. |
| `client/client.ml:194` | `bigstringaf` | Copy h2 body chunks from ocaml-h2 bigstrings into the S2 eager body buffer. | structural | medium; `ocaml-h2` delivers body chunks as bigstrings. |
| `client/client.ml:257` | `eio` | Close the h2 transport flow during auto-dispatch cleanup. | structural | medium; transport is Eio-backed in v1. |
| `client/client.ml:285` | `h2` | Close the h2 request-body writer after fixed body submission. | structural | high; request-body lifecycle is owned by `ocaml-h2`. |
| `client/client.ml:365` | `eio` | Close auto-dispatch h1 fallback flows when response bodies release. | structural | medium; transport is Eio-backed in v1. |
| `test/tls/negative_tls13_override.ml:2` | `ca-certs` | Build an authenticator for the compile-fail policy fixture. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:165` | `eio` | Build an in-memory flow sink for the h1 direct-writer parity test. | test-only | low; keeps transport writer output covered without a socket. |
| `test/test_eta_http.ml:276` | `eio` | Build a deterministic mock TCP address for DNS resolver tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:314` | `eio` | Build a deterministic mock TCP address for connect success tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:327` | `eio` | Build a deterministic mock TCP address for connect failure tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:445` | `eio` | Build a deterministic mock TCP address for h1 pool reuse tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:460` | `ca-certs` | Build an authenticator for h1 pool reuse tests. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:495` | `eio` | Build a deterministic mock TCP address for h1 pool health-rejection tests. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:512` | `ca-certs` | Build an authenticator for h1 pool health-rejection tests. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:548` | `eio` | Build a deterministic mock TCP address for the h1 body-EOF release test. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:555` | `ca-certs` | Build an authenticator for the h1 body-EOF release test. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:589` | `eio` | Build a deterministic mock TCP address for the h1 body-discard release test. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:596` | `ca-certs` | Build an authenticator for the h1 body-discard release test. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:637` | `eio` | Build a deterministic mock TCP address for the h1 request-cancellation release test. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:644` | `ca-certs` | Build an authenticator for the h1 request-cancellation release test. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:688` | `eio` | Build a deterministic mock TCP address for the public h1 client path test. | test-only | low; can move behind a helper if tests grow. |
| `test/test_eta_http.ml:695` | `ca-certs` | Build an authenticator for the public h1 client path test. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:719` | `tls` | Verify policy ciphers exclude FFDHE key exchange. | test-only | low; inspection can move to a helper if needed. |
| `test/test_eta_http.ml:723` | `ca-certs` | Build an authenticator for the TLS policy invariant test. | test-only | low; fixture can use any valid authenticator. |
| `test/test_eta_http.ml:727` | `tls` | Exercise the public eta-http TLS config builder. | test-only | low; test subject. |
| `test/test_eta_http.ml:728` | `tls` | Inspect the generated client config. | test-only | low; invariant test inspection. |
| `test/test_eta_http.ml:732` | `tls` | Assert the generated config is TLS 1.2 only. | test-only | low; invariant test inspection. |
| `test/test_eta_http.ml:736` | `tls` | Assert the generated config uses exactly the policy ciphers. | test-only | low; invariant test inspection. |
| `test/test_eta_http.ml:742` | `tls` | Assert the generated config has no TLS 1.3 ciphers. | test-only | low; invariant test inspection. |
| `test/test_eta_http.ml:878` | `bigstringaf` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:879` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:882` | `cstruct` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:883` | `cstruct` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:888` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:893` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:894` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:898` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:902` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:904` | `eio` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:921` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:926` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:927` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:931` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:935` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:975` | `cstruct` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:982` | `bigstringaf` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:983` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:993` | `bigstringaf` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:994` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1001` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1004` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1008` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1012` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1015` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1020` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1024` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1027` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1032` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1050` | `bigstringaf` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1051` | `cstruct` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1074` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1077` | `bigstringaf` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1086` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1118` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1123` | `bigstringaf` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1131` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1132` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1143` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1152` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1153` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1157` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1160` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1163` | `bigstringaf` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1171` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1174` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1175` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1177` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1180` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1185` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1186` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1190` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1193` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1196` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1198` | `eio` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1205` | `eio` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1236` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1237` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1238` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1281` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1282` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1285` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1305` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1322` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1324` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1326` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1327` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1379` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1380` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1383` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1385` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1387` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1394` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1395` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1407` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1408` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1412` | `bigstringaf` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1422` | `h2` | Exercise the current h2 writer/read/mux integration fixture against real `ocaml-h2` bytes. | test-only | low; fixture site documented by the S2 h2 probe notes. |
| `test/test_eta_http.ml:1480` | `h2` | Exercise the GOAWAY cutoff fixture against real `ocaml-h2` client state. | test-only | low; fixture site documented by the S2 GOAWAY probe note. |
| `test/test_eta_http.ml:1483` | `h2` | Report GOAWAY fixture client-write progress back to `ocaml-h2`. | test-only | low; fixture site documented by the S2 GOAWAY probe note. |
| `test/test_eta_http.ml:1487` | `h2` | Report GOAWAY fixture client writer close back to `ocaml-h2`. | test-only | low; fixture site documented by the S2 GOAWAY probe note. |
| `test/test_eta_http.ml:1501` | `h2` | Assert the h2 client is still open immediately after raw GOAWAY input. | test-only | low; fixture site documented by the S2 GOAWAY probe note. |
| `test/test_eta_http.ml:1504` | `h2` | Assert the h2 client is closed after flushing GOAWAY follow-up writes. | test-only | low; fixture site documented by the S2 GOAWAY probe note. |
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
| `h1/client.ml:105` | `eio` | Write streaming request-body chunks to the h1 transport flow. | structural | medium; h1 request streaming is Eio-backed in v1. |
| `h1/client.ml:108` | `eio` | Write chunked-transfer framing for streaming request bodies. | structural | medium; h1 request streaming is Eio-backed in v1. |
| `h1/write.ml:22` | `eio` | Write h1 request fragments directly to a flow sink. | structural | medium; this is the S1 transport writer path. |
| `h1/write.ml:25` | `eio` | Write fixed request-body chunks without building a complete request string. | structural | medium; body chunk ownership remains caller-owned. |
| `h1/write.mli:45` | `eio` | Expose the direct h1 writer sink boundary. | structural | medium; this keeps the transport writer measurable without a full request string. |
| `h1/client.ml:131` | `eio` + `cstruct` | Read transport bytes into the S1 32 KiB response read buffer. | structural | medium; Eio exposes flow reads through `Cstruct.t`. |
| `h1/client.ml:135` | `cstruct` | Copy bytes from the Eio read buffer into the parser-owned `bytes` buffer. | replaceable | medium; a future parser over `Cstruct.t`/bigstring could remove this copy. |
| `h1/client.ml:142` | `cstruct` | Allocate the temporary body read buffer for fixed-length S1 eager bodies. | replaceable | medium; S3 streaming bodies should replace this eager body path. |
| `h1/client.ml:148` | `eio` + `cstruct` | Read remaining fixed-length body bytes after the header buffer is consumed. | replaceable | medium; S3 streaming bodies should replace this eager body path. |
| `h1/client.ml:152` | `cstruct` | Copy body read bytes into the S1 eager body buffer. | replaceable | medium; S3 streaming bodies should replace this eager body path. |
| `h1/client.ml:191` | `cstruct` | Allocate the 32 KiB transport read buffer used by the h1 parser loop. | structural | medium; tied to Eio's flow read API. |
| `h1/client.ml:261` | `cstruct` | Store the reusable h1 streaming-response scratch buffer. | structural | medium; Eio flow reads use `Cstruct.t`. |
| `h1/client.ml:262` | `cstruct` | Expose the h1 streaming source read callback over `Cstruct.t`. | structural | medium; Eio flow reads use `Cstruct.t`. |
| `h1/client.ml:270` | `cstruct` | Allocate the h1 streaming-response scratch buffer. | structural | medium; replaces the S1 eager body buffer with bounded streaming reads. |
| `h1/client.ml:271` | `eio` | Read h1 streaming body bytes from the transport flow. | structural | medium; h1 response streaming is Eio-backed in v1. |
| `h1/client.ml:267` | `eio` | Create a one-byte buffered reader for the idle-connection health probe. | replaceable | medium; R5 stale-idle proof passes, but a future parser may replace this probe. |
| `h1/client.ml:268` | `eio` | Probe idle h1 connections without sending application bytes. | replaceable | medium; R5 stale-idle proof passes, but a future parser may replace this probe. |
| `h2/writer.ml:10` | `h2` + `bigstringaf` | Accept h2 writer iovecs over `Bigstringaf` buffers from `ocaml-h2`. | structural | high; this is the h2 Sans-IO writer substrate. |
| `h2/writer.ml:11` | `cstruct` | View h2 bigstring iovecs as `Cstruct.t` slices for Eio writes without copying. | structural | medium; Eio flow writes accept cstruct vectors. |
| `h2/writer.ml:16` | `h2` | Measure the h2 iovec vector before deciding whether to call Eio write. | structural | low; keeps empty-write behavior explicit at the h2 boundary. |
| `h2/writer.ml:17` | `eio` | Write h2 iovec slices to the socket flow with `Eio.Flow.single_write`. | structural | medium; this is the h2 transport writer path. |
| `h2/writer.ml:20` | `h2` | Pull the next client h2 write operation from `ocaml-h2`. | structural | high; `ocaml-h2` owns frame serialization. |
| `h2/writer.ml:23` | `h2` | Report successful partial/full writes back to `ocaml-h2`. | structural | high; `ocaml-h2` owns writer state advancement. |
| `h2/writer.ml:27` | `h2` | Report sink closure back to `ocaml-h2`. | structural | high; `ocaml-h2` owns writer shutdown state. |
| `h2/writer.ml:34` | `h2` | Register the h2 writer wakeup callback and bridge it through Eta.Channel close. | structural | high; `ocaml-h2` owns wakeup notification. |
| `h2/writer.ml:40` | `h2` | Pull write operations in the Eta-effect writer loop. | structural | high; `ocaml-h2` owns writer state progression. |
| `h2/writer.ml:45` | `h2` | Report effect-writer progress back to `ocaml-h2`. | structural | high; `ocaml-h2` owns writer state advancement. |
| `h2/writer.ml:50` | `h2` | Report effect-writer closure back to `ocaml-h2`. | structural | high; `ocaml-h2` owns writer shutdown state. |
| `h2/writer.mli:10` | `h2` + `bigstringaf` + `cstruct` | Expose h2 iovec-to-cstruct conversion for focused tests and adapter reuse. | structural | medium; public within eta-http h2 adapter surface. |
| `h2/writer.mli:12` | `eio` | Accept an Eio sink flow for h2 iovec writes. | structural | medium; transport is Eio-backed in v1. |
| `h2/writer.mli:13` | `h2` + `bigstringaf` | Expose the h2 iovec input type for writer draining. | structural | high; this is the `ocaml-h2` writer substrate. |
| `h2/writer.mli:17` | `eio` | Accept an Eio sink flow for h2 client writer draining. | structural | medium; transport is Eio-backed in v1. |
| `h2/writer.mli:18` | `h2` | Accept a client `ocaml-h2` connection for writer draining. | structural | high; `ocaml-h2` owns h2 frame serialization. |
| `h2/writer.mli:22` | `h2` + `bigstringaf` | Expose the h2 iovec input type for the Eta-effect writer loop. | structural | high; this is the `ocaml-h2` writer substrate. |
| `h2/writer.mli:23` | `h2` | Accept a client `ocaml-h2` connection for the Eta-effect writer loop. | structural | high; `ocaml-h2` owns h2 frame serialization. |
| `h2/security.mli:27` | `bigstringaf` | Expose raw h2 read-buffer observation for frame-envelope checks. | structural | medium; the h2 adapter buffer is a `Bigstringaf.t` because `ocaml-h2` reads that shape. |
| `h2/security.ml:150` | `bigstringaf` | Inspect raw server-to-client frame bytes before feeding `ocaml-h2`. | structural | medium; the scanner must observe the same bigstring buffer handed to the substrate. |
| `h2/multiplexer.mli:12` | `h2` | Expose the request-body writer returned by a mux-opened h2 stream. | structural | high; `ocaml-h2` owns request-body DATA scheduling. |
| `h2/multiplexer.mli:24` | `h2` | Accept the `ocaml-h2` client config for mux construction. | structural | high; h2 SETTINGS and protocol knobs live in `ocaml-h2`. |
| `h2/multiplexer.mli:26` | `h2` | Accept the optional h2 push handler while keeping push disabled by default. | structural | medium; mirrors the substrate API for R8 policy. |
| `h2/multiplexer.mli:27` | `h2` | Accept the connection-level h2 error handler for mux construction. | structural | high; connection errors originate in `ocaml-h2`. |
| `h2/multiplexer.mli:31` | `h2` | Expose the underlying client connection for low-level adapter tests. | structural | medium; future public h2 client code should avoid this test seam. |
| `h2/multiplexer.mli:41` | `h2` | Accept a request built with the h2 substrate request type. | structural | high; request serialization is owned by `ocaml-h2`. |
| `h2/multiplexer.mli:42` | `h2` | Surface stream-level h2 errors with the eta-http stream handle. | structural | high; stream errors originate in `ocaml-h2`. |
| `h2/multiplexer.mli:43` | `h2` | Surface h2 responses and body readers with the eta-http stream handle. | structural | high; response callbacks originate in `ocaml-h2`. |
| `h2/multiplexer.mli:46` | `h2` | Accept a client `ocaml-h2` connection for read-adapter state. | structural | high; `ocaml-h2` owns h2 frame parsing and stream callbacks. |
| `h2/multiplexer.mli:47` | `h2` | Expose the client connection from the read-adapter state. | structural | medium; low-level adapter seam. |
| `h2/multiplexer.mli:50` | `eio` | Accept an Eio source flow for h2 client read draining. | structural | medium; transport is Eio-backed in v1. |
| `h2/multiplexer.ml:13` | `h2` | Store the request-body writer returned by a mux-opened h2 stream. | structural | high; `ocaml-h2` owns request-body DATA scheduling. |
| `h2/multiplexer.ml:17` | `h2` | Store the client `ocaml-h2` connection in mux state. | structural | high; `ocaml-h2` owns h2 frame parsing and stream callbacks. |
| `h2/multiplexer.ml:19` | `h2` | Track response body readers by stream id so release can close them. | structural | high; h2 body cancellation is a substrate operation. |
| `h2/multiplexer.ml:27` | `h2` | Create the underlying h2 client connection. | structural | high; this is the h2 Sans-IO substrate boundary. |
| `h2/multiplexer.ml:53` | `h2` | Check and close the h2 body reader during eta-http stream release. | structural | high; local cancellation maps to h2 body-reader close. |
| `h2/multiplexer.ml:61` | `h2` | Shutdown the underlying h2 client connection. | structural | high; h2 connection shutdown is substrate-owned. |
| `h2/multiplexer.ml:66` | `h2` | Gate new mux requests when the h2 client is closed. | structural | high; prevents post-close request hangs. |
| `h2/multiplexer.ml:74` | `h2` | Open a real h2 client request after eta-http admission succeeds. | structural | high; `ocaml-h2` owns stream creation and callbacks. |
| `h2/multiplexer.ml:85` | `h2` | Store the client `ocaml-h2` connection in read-adapter state. | structural | high; `ocaml-h2` owns h2 frame parsing and stream callbacks. |
| `h2/multiplexer.ml:86` | `bigstringaf` | Store the reusable h2 read buffer as a bigstring. | structural | medium; `ocaml-h2` reads from `Bigstringaf.t`. |
| `h2/multiplexer.ml:100` | `bigstringaf` | Allocate the h2 client read buffer. | structural | medium; buffer is the Eio-to-`ocaml-h2` handoff. |
| `h2/multiplexer.ml:110` | `bigstringaf` | Inspect read-buffer capacity before filling from Eio. | structural | low; local buffer bookkeeping. |
| `h2/multiplexer.ml:114` | `bigstringaf` | Compact pending h2 parser bytes before the next Eio read. | structural | medium; preserves incomplete frame prefixes. |
| `h2/multiplexer.ml:121` | `h2` | Feed pending bytes into `H2.Client_connection.read`. | structural | high; `ocaml-h2` owns frame parsing and stream-state callbacks. |
| `h2/multiplexer.ml:133` | `h2` | Propagate source EOF through `H2.Client_connection.read_eof`. | structural | high; `ocaml-h2` owns reader shutdown state. |
| `h2/multiplexer.ml:145` | `cstruct` | View the spare read-buffer suffix as an Eio-readable cstruct. | structural | medium; Eio flow reads accept cstructs. |
| `h2/multiplexer.ml:150` | `eio` | Read h2 response bytes from the transport source. | structural | medium; this is the h2 transport read path. |
| `h2/multiplexer.ml:156` | `h2` | Check the next client h2 read operation before feeding bytes. | structural | high; `ocaml-h2` owns reader state progression. |
| `transport/connect.ml:13` | `eio` | Define the TCP flow boundary as an Eio two-way closeable flow. | structural | medium; transport is Eio-backed in v1. |
| `transport/connect.ml:40` | `eio` | Resolve stream socket addresses through Eio.Net.getaddrinfo_stream. | structural | medium; this is the v1 DNS boundary. |
| `transport/connect.ml:50` | `eio` | Open TCP stream sockets through the caller-owned Eio network. | structural | medium; transport is Eio-backed in v1. |
| `transport/connect.ml:73` | `ipaddr` | Detect IP-literal peers for certificate validation. | structural | medium; replacing requires another X.509-compatible IP representation. |
| `transport/connect.ml:76` | `domain-name` | Parse DNS host peers for SNI and hostname verification. | structural | medium; replacing requires another X.509-compatible hostname representation. |
| `transport/connect.ml:79` | `domain-name` | Validate DNS host peers before SNI and hostname verification. | structural | medium; replacing requires another X.509-compatible hostname representation. |
| `transport/connect.ml:92` | `tls-eio` | Wrap host-name TCP flows in the TLS client. | structural | high; this is the TLS substrate chokepoint consumer. |
| `transport/connect.ml:98` | `tls-eio` | Wrap IP-literal TCP flows in the TLS client. | structural | high; this is the TLS substrate chokepoint consumer. |
| `transport/connect.ml:105` | `tls-eio` | Read the completed TLS epoch to observe negotiated ALPN. | structural | high; ALPN is reported by the TLS substrate. |
| `transport/connect.ml:107` | `tls` | Extract the negotiated ALPN protocol from the TLS epoch. | structural | high; protocol negotiation metadata is owned by the TLS substrate. |
| `transport/connect.mli:11` | `eio` | Expose the TCP flow boundary as an Eio two-way closeable flow. | structural | medium; transport is Eio-backed in v1. |
| `transport/connect.mli:16` | `eio` | Accept an explicit Eio network capability instead of ambient DNS authority. | structural | medium; keeps DNS authority owned by the caller runtime. |
| `transport/connect.mli:19` | `eio` | Return Eio stream socket addresses from DNS resolution. | structural | medium; callers pass these to the TCP connection step. |
| `transport/connect.mli:20` | `eio` | Document the Eio DNS primitive used by the resolver boundary. | structural | low; comment-only dependency mention. |
| `transport/connect.mli:26` | `eio` | Accept the caller-owned switch for TCP connection lifetime. | structural | medium; connections are switch-scoped. |
| `transport/connect.mli:27` | `eio` | Accept the caller-owned network capability for TCP connect. | structural | medium; eta-http must not own ambient network authority. |
| `transport/connect.mli:38` | `x509` | Accept the TLS authenticator for TLS connection setup. | structural | high; certificate validation stays in the TLS/X.509 stack. |
| `transport/connect.mli:42` | `tls-eio` | Return the TLS-wrapped Eio flow from the transport layer. | structural | high; this is the TLS substrate boundary. |
| `transport/connect.mli:52` | `tls-eio` | Accept the TLS-wrapped Eio flow when reading negotiated ALPN. | structural | high; ALPN is exposed by the TLS substrate flow. |
