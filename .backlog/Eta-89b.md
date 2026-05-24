---
id: Eta-89b
title: "P1: Url.authority must restore brackets for IPv6 literals"
status: closed
priority: 1
issue_type: task
created_at: 2026-05-24T09:04:17.094Z
created_by: backlog
updated_at: 2026-05-24T10:11:27.878Z
close_reason: "Closed by remediation. Url tracks IP-literal host kind so host remains unbracketed while authority/blit_authority/H1 Host restore IPv6 brackets; reg-name authority unchanged. Verified with nix develop -c dune runtest --force."
---

# P1: Url.authority must restore brackets for IPv6 literals

## description

Bug: packages/eta-http/core/url.ml parse_authority (line ~104) for [host] stores span ~off:(start+1) ~len:(close-start-1) — strips brackets. Url.authority (line ~248) returns host ^ ':' ^ port producing '::1:8443' (ambiguous, invalid HTTP authority). blit_authority_raw has the same defect on the zero-alloc path. The H1 writer auto-injects Host from Url.authority, so requests to https://[::1]:8443/ send a malformed Host header.

Location: packages/eta-http/core/url.ml parse_authority, authority, blit_authority_raw

## design

RED test (write first):
1. Url.parse 'https://[::1]:8443/path' |> Result.get_ok. Assert Url.authority url = '[::1]:8443'. Currently '::1:8443'.
2. Build the H1 wire image of a request to that URL. Assert the bytes contain CRLF + 'Host: [::1]:8443' + CRLF.
3. Url.parse 'https://[2001:db8::1]/' (no port). Assert Url.authority = '[2001:db8::1]'.
4. Regression: https://example.com:8080/ still authority 'example.com:8080'.
5. TLS peer-identity in transport/connect.ml inspects Url.host (no brackets). Verify Url.host of [::1]:8443 still returns '::1'.

Fix shape:
- Track host kind in Url.t: type host_kind = Reg_name | Ip_literal (or a boolean is_ip_literal stored alongside the host span).
- In authority and blit_authority_raw, re-add [...] for IP literals.
- Document in url.mli: host returns the unbracketed string; authority includes brackets for IP literals.

## acceptance criteria

All five RED test cases hold. Existing reg-name tests pass. transport/connect.ml peer-identity still works (regression test).
