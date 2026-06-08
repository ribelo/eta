# H-S3 Pivot

## Question

Which TLS pivot can support an eta-http v1 production client TLS claim?

## Current Hypothesis Space

| Option | Status | Current evidence |
| --- | --- | --- |
| Option 1: fixed tls 2.1 stack under OxCaml | Active but blocked | opam solver can select tls/tls-eio 2.1.0, x509 1.0.6, mirage-crypto 2.1.0, but digestif 1.3.0 still fails under OxCaml. |
| Option 2: narrowed older-branch policy | Active | First proof uses tls 0.17.5 with TLS 1.2 only and ECDHE AEAD ciphers only, excluding DHE suites and the affected TLS 1.3 KeyUsage path. |
| Option 3: different substrate | Deferred | Not tested yet; remains available if Option 2 cannot pass the H-S3 rerun bar. |

## Commands

    nix develop .#oxcaml -c bash -lc 'opam install --yes digestif.1.3.0 2>&1'
    nix develop .#oxcaml -c dune exec scratch/eta_http_research/h_s3_pivot/badssl_rerun.exe
