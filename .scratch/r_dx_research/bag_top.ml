open Effet

let program services = Bag_m20.program services

let run () = program (Dx_common.make_services ()) |> Dx_common.run_with_env (object end) |> Dx_common.ok
