```ocaml
open Eta

let with_db ~acquire ~release body =
  Effect.with_scope
    (Effect.acquire_release ~acquire ~release
    |> Effect.bind body)

let fetch_user id =
  Effect.named ~kind:Capabilities.Client "db.fetch_user"
    (Effect.sync (fun () -> load id))

let program =
  with_db ~acquire:open_conn ~release:close_conn @@ fun conn ->
  Effect.named "handler"
    (fetch_user 42
    |> Effect.bind (fun user ->
           Effect.named "render" (Effect.pure (view user))))
```

Resource lifetime ends at the `with_scope` boundary, matching the lifecycle
`with_*` family. One span verb `named` accepts optional `?kind` (default
`Internal`).
