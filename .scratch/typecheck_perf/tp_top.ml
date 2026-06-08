open Effet

let program () = Tp_m50.program ()

let run () =
  Tp_common.run_with_env (Tp_common.make_services ()) (program ())
  |> Tp_common.ok
