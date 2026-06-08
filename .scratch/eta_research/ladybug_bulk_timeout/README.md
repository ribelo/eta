# Ladybug Bulk Parameters And Direct Connection Timeouts

Status: active evidence lab.

## Question

Should Eta change the LadybugDB connector for:

- bulk insert / batch parameters;
- connection-level query timeouts outside Pool.

## Proof Obligations

| # | Obligation | Evidence |
| --- | --- | --- |
| P0 | A batch insert can be expressed with the current parameter binding model. | Run p0_batch_params.exe; the decisive candidate is UNWIND $rows AS row. |
| P1 | A direct connection timeout can preserve Eta's typed timeout and call Connection.interrupt. | Run p1_connection_timeout.exe; the connection must remain reusable. |
| P2 | Any public API added is smaller than a premature graph bulk-loader abstraction. | Compare candidates in candidates.md and results.md. |

## Commands

    nix develop -c dune exec ./scratch/eta_research/ladybug_bulk_timeout/p0_batch_params.exe
    nix develop -c dune exec ./scratch/eta_research/ladybug_bulk_timeout/p1_connection_timeout.exe
