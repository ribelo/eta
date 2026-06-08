# Schema.json_schema Survival Research

Backlog: Effet-jv3.

Current shipped behavior before removal:

| Constructor | Behavior | External-validator risk |
|---|---|---|
| primitives | local fragments like `{ "type": "string" }` | no draft declaration |
| option | `anyOf` with null | plausible fragment only |
| enum | `enum` labels | plausible fragment only |
| tagged_union | `oneOf` tag sketches | does not validate full case payloads |
| lazy_ | `{"$ref":"#/recursive"}` | broken reference |
| refine | `allOf` + description | loses actual predicate |
| transform | `allOf` + description | loses transformation semantics |

Consumers:

- No non-test package code consumed `Schema.json_schema`.
- The only package test checked that a generated schema had a title.

Decision:

- Remove `json_schema` from `Schema.t` and from the public API.
- Do not claim JSON Schema support until there is a dedicated generator with a
  selected draft, definition table, `$ref` handling, and validator-backed tests.

Future direction:

- A real `Effet_schema_jsonschema` module should be a separate surface.
- It should document which refinements can be mapped and which remain
  decode-only constraints.
