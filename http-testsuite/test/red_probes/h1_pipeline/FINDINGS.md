# h1_pipeline findings

## 1. handler_exception_then_valid — handler exception allows connection reuse

- **Probe name:** `handler_exception_then_valid`
- **Command to reproduce:**
  ```sh
  nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_pipeline/run.exe
  ```
- **Expected behavior:** The first request (`GET /boom`) causes the handler to
  raise. The server should emit a 500 response and close the connection, so the
  pipelined second request (`GET /ok`) is **not** processed.
- **Actual behavior:** The server returns `HTTP/1.1 500` for `/boom` and then
  returns `HTTP/1.1 200` for `/ok` on the same connection.
- **Protocol/backend involved:** HTTP/1.1 plain text, `eta_http_eio`
  (`lib/http_eio/h1_server_connection.ml`).
- **Minimized input:**
  ```text
  GET /boom HTTP/1.1\r\nHost: example.test\r\n\r\n
  GET /ok HTTP/1.1\r\nHost: example.test\r\n\r\n
  ```
- **Classification:** confirmed Eta bug

## 2. handler_timeout_then_valid — handler_timeout does not interrupt/reuse

- **Probe name:** `handler_timeout_then_valid`
- **Command to reproduce:**
  ```sh
  nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_pipeline/run.exe
  ```
- **Expected behavior:** The server is configured with
  `handler_timeout = 100 ms`. The first request (`GET /slow`) sleeps for 500 ms
  in the handler, so the server should time it out, return `503 Service
  Unavailable`, and close the connection.
- **Actual behavior:** The handler timeout is not enforced. The server waits for
  the handler to finish sleeping, returns `HTTP/1.1 200`, and then processes the
  pipelined second request (`GET /ok`) on the same connection.
- **Protocol/backend involved:** HTTP/1.1 plain text, `eta_http_eio`
  (`lib/http_eio/h1_server_connection.ml`).
- **Minimized input / config:**
  ```ocaml
  let config =
    { Eta_http_eio.Server.Config.default with
      server =
        { Eta_http.Server.Config.default with
          timeouts =
            { Eta_http.Server.Config.default.timeouts with
              handler_timeout = Some (Eta.Duration.ms 100) } } }
  ```
  Request bytes:
  ```text
  GET /slow HTTP/1.1\r\nHost: example.test\r\n\r\n
  GET /ok HTTP/1.1\r\nHost: example.test\r\n\r\n
  ```
- **Classification:** likely Eta bug

## Probes that ran cleanly (no finding)

- `pipeline_two_ok` — two pipelined `GET`s both return 200 and the connection
  stays alive.
- `malformed_then_valid` — malformed first request returns 400 and the
  connection closes.
- `unread_body_drain_small` — small unread body is drained and the connection
  is reused under `Drain_up_to`.
- `unread_body_drain_large` — large unread body forces connection close under
  `Drain_up_to`.
- `unread_body_reset` — unread body forces connection close under `Reset`.
- `partial_body_then_request` — partial body prevents the second request from
  being processed.
