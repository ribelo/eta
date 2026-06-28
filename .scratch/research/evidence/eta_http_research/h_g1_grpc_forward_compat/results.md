# H-G1 Results

Command:

    nix develop -c dune exec .scratch/research/evidence/eta_http_research/h_g1_grpc_forward_compat/response_consumer.exe

Observed:

    h_g1_grpc label=ok http_status=200 body_bytes=10 grpc_status=0 grpc_message=""
    h_g1_grpc label=unavailable http_status=200 body_bytes=10 grpc_status=14 grpc_message="UNAVAILABLE"
    h_g1_grpc_forward_compat verdict=PASS raw_body_stable=true trailers_observable=true

Verdict: PASS.

The fixture proves that eta-http can expose raw gRPC message bytes through the
body stream while independently exposing gRPC status trailers through
Response.trailers.
