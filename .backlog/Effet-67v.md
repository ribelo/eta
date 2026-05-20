---
id: Effet-67v
title: Wire JSON_ADAPTER to a real consumer (Make functor) or remove it
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T21:00:15.221Z
created_by: backlog
updated_at: 2026-05-19T21:11:20.382Z
dependencies:
  - issue_id: Effet-67v
    depends_on_id: Effet-tkw
    type: parent-child
    created_at: 2026-05-19T21:10:56.189Z
    created_by: backlog
  - issue_id: Effet-67v
    depends_on_id: Effet-a64
    type: blocks
    created_at: 2026-05-19T21:11:20.382Z
    created_by: backlog
---

# Wire JSON_ADAPTER to a real consumer (Make functor) or remove it

## description

packages/effet-schema/effet_schema.mli exports:

  module type JSON_ADAPTER = sig
    type external_json
    val of_external : external_json -> (json, issue list) result
    val to_external : json -> external_json
  end

But there is no Make (A : JSON_ADAPTER) : ... functor anywhere in the package, and no Yojson / Ezjsonm adapter implementing the contract. The module type is documentation pretending to be enforcement.

This means:
- users wanting Yojson interop write their own conversion functions, ignoring JSON_ADAPTER
- the contract isn't tested against a real adapter, so changes to Json.t can break it silently
- the .mli claims pluggable JSON without delivering it

Two paths: implement the missing pieces, or remove the dead interface.

## design

A) Implement the consumer. Add Effet_schema_yojson sublibrary (or a separate package effet-schema-yojson) that exports Adapter : JSON_ADAPTER with type external_json = Yojson.Safe.t. Add a minimal Make functor in the core package:

  module Make (A : JSON_ADAPTER) : sig
    val decode : 'a Schema.t -> A.external_json -> ('env, [> error ], 'a) Effet.Effect.t
    val encode : 'a Schema.t -> 'a -> A.external_json
  end

With one adapter shipped, the contract has a real test surface and downstream consumers see how to plug other JSON libraries.

B) Delete module type JSON_ADAPTER. Document Json.t as the canonical type and require users wanting Yojson interop to write their own conversions (a few lines).

Pick A if any concrete user has asked for adapter-based plug-in, or if shipping Yojson interop is on the v0 roadmap. Pick B otherwise — the dead abstraction costs more in confusion than it saves.

## acceptance criteria

Either (A) packages/effet-schema-yojson/ exists with an Adapter satisfying JSON_ADAPTER, plus a Make functor in core that uses it; an integration test round-trips a fixture through the adapter. Or (B) module type JSON_ADAPTER is removed from effet_schema.mli. The package no longer ships an unused interface.
