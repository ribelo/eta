open Eta

let program services = Tp_m50.program services

let run () =
  let services = Tp_common.make_services () in
  Tp_common.run_with_services services (program services) |> Tp_common.ok
