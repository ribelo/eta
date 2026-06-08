# H-S3-Enforce Results

Status: PASS.

## Question

Does every documented eta-http TLS construction path in the lab satisfy ADR
0002: TLS 1.2 only, ECDHE RSA/ECDSA AEAD ciphers only, and no public override
capable of silently widening version or cipher policy?

## Construction Path Inventory

eta-http is not shipped yet, so the enforcement chokepoint is internal to this
lab:

    H_s3_enforce_policy.Default_config_builder.default_client

Exercised construction paths:

| Path | Inputs | Expected invariant |
| --- | --- | --- |
| default_path | authenticator only | TLS 1.2 only; exact policy cipher set |
| peer_name_path | authenticator + peer_name | TLS 1.2 only; exact policy cipher set |
| ip_literal_path | authenticator + ip | TLS 1.2 only; exact policy cipher set |
| custom_alpn_path | authenticator + alpn_protocols | ALPN may vary; TLS version/ciphers remain fixed |

The helper deliberately exposes no version or cipher arguments. When eta-http v1
lands, this helper shape should migrate with the public TLS configuration API.

## Positive Fixture

Command:

~~~text
nix develop -c dune exec scratch/eta_http_research/h_s3_enforce/invariants.exe
~~~

Transcript:

~~~text
PASS default_path version_range_tls12_only
PASS default_path ciphers_exact_policy_set
PASS default_path ciphers_no_dhe
PASS default_path no_tls13_ciphers
CONFIG default_path versions=tls12-tls12 ciphers=ECDHE RSA AEAD AES128 GCM,ECDHE RSA AEAD AES256 GCM,ECDHE RSA AEAD CHACHA20 POLY1305,ECDHE ECDSA AEAD AES128 GCM,ECDHE ECDSA AEAD AES256 GCM,ECDHE ECDSA AEAD CHACHA20 POLY1305 alpn=h2,http/1.1
PASS peer_name_path version_range_tls12_only
PASS peer_name_path ciphers_exact_policy_set
PASS peer_name_path ciphers_no_dhe
PASS peer_name_path no_tls13_ciphers
CONFIG peer_name_path versions=tls12-tls12 ciphers=ECDHE RSA AEAD AES128 GCM,ECDHE RSA AEAD AES256 GCM,ECDHE RSA AEAD CHACHA20 POLY1305,ECDHE ECDSA AEAD AES128 GCM,ECDHE ECDSA AEAD AES256 GCM,ECDHE ECDSA AEAD CHACHA20 POLY1305 alpn=h2,http/1.1
PASS ip_literal_path version_range_tls12_only
PASS ip_literal_path ciphers_exact_policy_set
PASS ip_literal_path ciphers_no_dhe
PASS ip_literal_path no_tls13_ciphers
CONFIG ip_literal_path versions=tls12-tls12 ciphers=ECDHE RSA AEAD AES128 GCM,ECDHE RSA AEAD AES256 GCM,ECDHE RSA AEAD CHACHA20 POLY1305,ECDHE ECDSA AEAD AES128 GCM,ECDHE ECDSA AEAD AES256 GCM,ECDHE ECDSA AEAD CHACHA20 POLY1305 alpn=h2,http/1.1
PASS custom_alpn_path version_range_tls12_only
PASS custom_alpn_path ciphers_exact_policy_set
PASS custom_alpn_path ciphers_no_dhe
PASS custom_alpn_path no_tls13_ciphers
CONFIG custom_alpn_path versions=tls12-tls12 ciphers=ECDHE RSA AEAD AES128 GCM,ECDHE RSA AEAD AES256 GCM,ECDHE RSA AEAD CHACHA20 POLY1305,ECDHE ECDSA AEAD AES128 GCM,ECDHE ECDSA AEAD AES256 GCM,ECDHE ECDSA AEAD CHACHA20 POLY1305 alpn=http/1.1
h_s3_enforce_invariants passed
~~~

The fixture inspects Tls.Config.of_client output directly. It does not infer
policy from handshake behavior.

## Negative Fixtures

Command:

~~~text
nix develop -c bash scratch/eta_http_research/h_s3_enforce/run_negative_compile.sh
~~~

Transcript:

~~~text
File "scratch/eta_http_research/h_s3_enforce/negative_tls13_override.ml", line 8, characters 13-33:
8 |     ~version:(`TLS_1_2, `TLS_1_3) ()
                 ^^^^^^^^^^^^^^^^^^^^
Error: The function applied to this argument has type
         ?peer_name:[ `host ] Domain_name.t ->
         ?ip:Ipaddr.t -> ?alpn_protocols:string list -> Tls.Config.client
This argument cannot be applied with label "~version"
PASS expected compile failure: negative_tls13_override
File "scratch/eta_http_research/h_s3_enforce/negative_dhe_cipher_override.ml", line 8, characters 13-49:
8 |     ~ciphers:[ `DHE_RSA_WITH_AES_128_GCM_SHA256 ] ()
                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: The function applied to this argument has type
         ?peer_name:[ `host ] Domain_name.t ->
         ?ip:Ipaddr.t -> ?alpn_protocols:string list -> Tls.Config.client
This argument cannot be applied with label "~ciphers"
PASS expected compile failure: negative_dhe_cipher_override
~~~

## Verdict

H-S3-Enforce PASS. The internal helper is a single chokepoint for the lab. Its
documented construction paths produce Tls.Config.client values with:

- protocol_versions = (TLS_1_2, TLS_1_2);
- ciphers equal to the six ADR 0002 ECDHE-AEAD suites;
- no FFDHE/DHE key exchange ciphers;
- no TLS 1.3 ciphers.

Attempts to widen the version range or add DHE_RSA ciphers through the helper do
not compile because the helper exposes no such labels.

## Residual Risk

The enforcement helper is still scratch-internal. The eta-http implementation
epic must move this chokepoint into the public/internal eta-http API and keep
the same invariant tests attached there.
