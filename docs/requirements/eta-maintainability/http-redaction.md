---
kind: requirement
---
# HTTP URI redaction

## Intent

Keep HTTP telemetry and diagnostics on one URI-redaction policy.

## Requirements

- The `Eta_http.Error.Redaction` module shall own HTTP URI user-info, query, and fragment redaction. ^httpred-inyc
- When HTTP semantic-convention code records a redacted URI or redirect location, the code shall use `Eta_http.Error.Redaction` rather than a separate redaction implementation. ^httpred-amns
