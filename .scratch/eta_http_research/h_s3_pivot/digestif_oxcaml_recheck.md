# Digestif / OxCaml Recheck

Date: 2026-05-23

Question: is the digestif failure that blocks tls-eio 2.1.0 still real,
already solved, publicly described upstream, or scheduled for resolution?

## Verdict

The problem is still unsolved for Eta's configured public toolchain. After
updating the configured opam repositories, the only available OxCaml compiler
variant is 5.2.0+ox and the newest available digestif release is 1.3.0. The
existing H-S3 reproduction shows digestif.1.3.0 failing before Eta wires it into
anything.

## Evidence

Configured compiler and repositories:

    flake.nix: oxCamlSwitch = "5.2.0+ox"
    opam switch: 5.2.0+ox
    ocamlc -version: 5.2.0+ox
    opam repos: ox=git+https://github.com/oxcaml/opam-repository.git, default=https://opam.ocaml.org

Available versions after opam update:

    ocaml-variants with +ox: 5.2.0+ox
    digestif: 0.5, 0.6.1, 0.9.0, 1.1.2, 1.3.0

digestif.1.3.0 metadata:

    homepage: https://github.com/mirage/digestif
    bug-reports: https://github.com/mirage/digestif/issues
    dev-repo: git+https://github.com/mirage/digestif.git
    x-commit-hash: 0763eb3b34ac8881925c4f50055f4bff3808aed4

Existing H-S3 reproduction:

    nix develop .#oxcaml -c bash -lc 'opam install --yes digestif.1.3.0 2>&1'

    [ERROR] The compilation of digestif.1.3.0 failed at "dune build -p digestif -j 31".
    File "src-ocaml/baijiu_rmd160.ml", line 348, characters 15-22:
    Error: This expression has type
             "bytes @ local -> int -> bytes @ local -> int -> int -> unit"
           but an expression was expected of type
             "By.t @ local -> (int -> By.t -> int -> int -> unit)"

A 2026-05-23 retry was blocked by an unrelated active opam switch lock, so this
addendum does not replace the captured failure transcript.

## Upstream Search

gh search issues could not be used because the local GitHub token returns 401
Bad credentials. Fallback was unauthenticated GitHub Search API via curl.

Search results:

    repo:mirage/digestif oxcaml           -> 0
    repo:mirage/digestif "5.2.0+ox"       -> 0
    repo:mirage/digestif baijiu_rmd160    -> 0
    repo:mirage/digestif "local" "mode"   -> 0
    repo:oxcaml/oxcaml digestif           -> 0
    repo:ocaml-flambda/ocaml-jst digestif -> 0
    global baijiu_rmd160                  -> 0
    global digestif oxcaml                -> 1
    global digestif "5.2.0+ox"            -> 1

The single global hit is an independent downstream workaround:

    https://github.com/cezarc1/websocket-stt-bench/pull/1

It says that websocket-async/cohttp-async pull digestif, digestif does not
compile on OxCaml 5.2.0+ox, and the project hand-rolled transport instead. It
does not link an upstream fix or schedule.

## Unreleased Upstream State

mirage/digestif HEAD is 46968733c813b53271f9dc091c3bf06c12d16814. The v1.3.0
release commit is 0763eb3b34ac8881925c4f50055f4bff3808aed4.

Recent commits after v1.3.0 are documentation and CI maintenance:

    2025-05-21 Merge pull request #162 from kit-ty-kate/patch-1
    2025-05-21 Fix the documentation of Digestif.S.hmac_feed_bytes
    2025-04-17 Merge pull request #161 from jonahbeckford/upgrade-setup-ocaml
    2025-04-17 Merge pull request #160 from jonahbeckford/remove-dkml

No visible commit message mentions OxCaml, modes, baijiu_rmd160, or a compiler
compatibility fix.

## Bayesian Update

Hypothesis A: the issue is solved in released packages. Posterior: very low.
The current public opam repositories expose no newer digestif and the captured
build transcript fails on the newest release.

Hypothesis B: Eta is behind on OxCaml. Posterior: low for the configured public
path. The updated OxCaml opam repository exposes only 5.2.0+ox. Private or
unpublished compiler snapshots remain unknown.

Hypothesis C: the issue is publicly tracked upstream with a visible ETA.
Posterior: low. No digestif or OxCaml issue/PR surfaced; the only hit is a
downstream workaround. Confidence is bounded by unauthenticated GitHub search
and the bad local gh token.

Hypothesis D: this is an Eta design consequence. Posterior: very low. The
failure happens while compiling digestif itself before Eta depends on any
particular digestif API shape.

## Decision Impact

Keep ADR 0002's v1 decision: do not block eta-http on tls-eio 2.1.0 under the
current OxCaml switch. Ship the constrained older tls-eio 0.17.5 policy for v1
only with TLS 1.2 + ECDHE AEAD + caller-owned revocation, and keep the newer
tls-eio line as a follow-up once digestif or OxCaml compatibility changes.

The rational next action is upstream coordination or a local digestif patch
track, not another eta-http design pass.
