open Eta

let program deps = Deps_m20.program deps

let run () =
  let deps = Deps_common.make_services () in
  Deps_common.run_with_deps deps (program deps) |> Deps_common.ok
