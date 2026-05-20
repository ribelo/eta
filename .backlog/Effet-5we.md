---
id: Effet-5we
title: Generalise decode_with_policy from 'a -> 'a to 'a -> 'b
status: open
priority: 2
issue_type: task
created_at: 2026-05-19T21:03:35.645Z
created_by: backlog
updated_at: 2026-05-19T21:11:53.496Z
dependencies:
  - issue_id: Effet-5we
    depends_on_id: Effet-tkw
    type: parent-child
    created_at: 2026-05-19T21:11:53.496Z
    created_by: backlog
---

# Generalise decode_with_policy from 'a -> 'a to 'a -> 'b

## description

packages/effet-schema/effet_schema.mli:

  val decode_with_policy :
    'a t ->
    ('a -> ('env, [> error ] as 'err, 'a) Effet.Effect.t) ->
    json ->
    ('env, 'err, 'a) Effet.Effect.t

The policy must return the same 'a. Real-world enrichment cases want different output:
- decode User_request → look up canonical User from DB → return User
- decode Tag_input → resolve to a Tag.t with a database id → return Tag.t
- decode Auth_payload → verify signature → return Verified_payload

Locking to 'a means users either chain Effect.bind after decode_with_policy (defeating the helper's purpose) or write their own decoder.

The shape was inherited from m_a_pure_schema_effect_policy.ml's lab fixture which called it 'effect_policy : 'a -> 'a' because that was the simpler thing to write. No fixture demanded 'a -> 'b.

## design

Change the signature to:

  val decode_with_policy :
    'a t ->
    ('a -> ('env, [> error ] as 'err, 'b) Effet.Effect.t) ->
    json ->
    ('env, 'err, 'b) Effet.Effect.t

Implementation is simpler than the current bind-with-locked-type version. The error row stays open (uses [> error]) so any policy errors compose with decode errors.

Add a worked example to packages/effet-schema/README.md showing a policy that enriches: decode an input record, look up a database row in env's db service, return the enriched output. Use Effet's existing object-row env.

Migration cost in tests: any test using the locked 'a -> 'a shape continues to work because 'b unifies with 'a. No call-site break.

## acceptance criteria

decode_with_policy's signature accepts 'a -> Effect.t 'b (any output type). A test exercises a policy that decodes record A and returns record B, verifying the type signature compiles and the runtime produces the enriched value. README.md gains a section showing the enrichment pattern with an env-row service. Existing tests pass.
