open Eta

let program () = Env_m20.program ()

let run () = Dx_common.run_with_env (Dx_common.make_services ()) (program ()) |> Dx_common.ok
