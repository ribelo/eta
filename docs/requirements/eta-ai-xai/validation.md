---
kind: requirement
---
# xAI request validation

## Intent

Reject request defects known from stable local contracts while leaving
account-dependent policy to xAI.

## Requirements

- If a request violates a locally knowable structural invariant, then the xAI provider shall reject it before transport. ^xaicore-7qp6
- If a request exceeds a numeric bound stated in its capability requirements, then the xAI provider shall reject it before transport. ^xaival-b93d
- When a request satisfies local structural and numeric validation, the xAI provider shall submit it for xAI to evaluate entitlement, model availability, regional availability, rate limits, and dynamic account policy. ^xaicore-02y2
