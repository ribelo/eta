# tls_frag Findings

Run:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/tls_frag/run.exe
```

## Current Status

All probes pass on the default Eio backend.

The original apparent body-fragmentation hangs were caused by probe completion
conditions:

- H1 body probes sent keep-alive requests and then waited for connection close.
  They now send `Connection: close`.
- H2 probes waited for connection close even though a valid H2 response keeps
  the connection open. They now stop on response `HEADERS`, `RST_STREAM`, or
  `GOAWAY`.
- The H2C isolation probe half-closes its send side after the fragmented DATA
  payload so the existing close-drain helper has a proper completion signal.

## Passing Coverage Kept

- H1 request line/headers one byte per TLS record.
- H1 fixed request body one byte per TLS record.
- H1 ignored fixed request body one byte per TLS record.
- H2 preface/SETTINGS/HEADERS one byte per TLS record.
- H2 DATA payload bytes one byte per TLS record.
- H2 DATA frame header+payload one byte per TLS record.
- Entire H2 request one byte per TLS write.
- Slow H2 preface.
- H2C DATA payload one byte per plain TCP write.
- Shutdown during TLS handshake, H2 headers, H2 DATA, and H1 trailers.
- ALPN `h2` sanity check.
