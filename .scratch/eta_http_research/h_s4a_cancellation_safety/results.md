# H-S4a Results

Status: PASS-WITH-CAVEAT.

## P0: timeout taxonomy and loser cleanup

Command:

    nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s4a_cancellation_safety/timeout_taxonomy.exe && timeout 10s dune exec scratch/eta_http_research/h_s4a_cancellation_safety/timeout_taxonomy.exe'

Output:

    h_s4a_timeout_taxonomy outcome=timeout_fail cleanup_ran=true permit=0 fd_before=6 fd_after=6 fd_delta=0

Decision:

P0 PASS. The current Eta runtime reports a caller-facing timeout as typed
Cause.Fail Timeout. The losing blocked Eio operation was cancelled, its cleanup
path ran, the local permit returned to zero, and the descriptor count was
unchanged in this non-network baseline.

This P0 fixture is not a substitute for the five required TCP/TLS/read/write
timeout fixtures.

## P1: network timeout matrix

Command:

    nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s4a_cancellation_safety/network_timeout_matrix.exe && timeout 30s dune exec scratch/eta_http_research/h_s4a_cancellation_safety/network_timeout_matrix.exe'

Output:

    h_s4a_connect name=tcp_connect_saturated_listener result=PASS outcome=timeout filler_connected=2 stop_reason=connect_timeout permit=0 fd_before=263 fd_after=263 fd_delta=0 fiber_before=0 fiber_after=0
    h_s4a_network name=tls_handshake_stall result=PASS outcome=timeout server_closed=true permit=0 fd_before=7 fd_after=7 fd_delta=0 fiber_before=1 fiber_after=0 server_detail=bytes=517
    h_s4a_network name=header_read_stall result=PASS outcome=timeout server_closed=true permit=0 fd_before=7 fd_after=7 fd_delta=0 fiber_before=1 fiber_after=0 server_detail=bytes=0
    h_s4a_network name=body_read_stall result=PASS outcome=timeout server_closed=true permit=0 fd_before=7 fd_after=7 fd_delta=0 fiber_before=1 fiber_after=0 server_detail=bytes=0
    h_s4a_network name=upload_sink_stall result=PASS outcome=timeout server_closed=true permit=0 fd_before=7 fd_after=7 fd_delta=0 fiber_before=1 fiber_after=0 server_detail=bytes=3977216

Decision:

P1 PASS-WITH-CAVEAT. Eta.timeout cancels the local TCP connect, TLS handshake,
header read, body read, and upload write stalls in this matrix. Every row
returns Cause.Fail Timeout to the caller, releases the local permit, and has
zero descriptor delta. The server-side rows observe the client side closing:
the server fiber drains or observes EOF and exits.

Caveat:

The fiber measurement is fixture-managed. It proves the server fibers created
by this matrix exit, but it is not a global census of every Eio runtime fiber.

## H-S4a verdict

H-S4a is PASS-WITH-CAVEAT for the local evidence bar. The timeout taxonomy is
Cause.Fail Timeout for the caller and cancellation/interrupt for the losing
operation. No descriptor or local permit leaks were observed in the five
required local fixtures.
