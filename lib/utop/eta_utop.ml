let with_runtime ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?blocking_pool ?services ?capture_backtrace f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock ?tracer ?sampler ?auto_instrument ?logger
      ?meter ?random ?blocking_pool ?services ?capture_backtrace ()
  in
  f runtime

let run ?tracer ?sampler ?auto_instrument ?logger ?meter ?random ?blocking_pool
    ?services ?capture_backtrace eff =
  with_runtime ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?blocking_pool ?services ?capture_backtrace @@ fun runtime ->
  Eta_eio.Runtime.run runtime eff

let run_exn ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?blocking_pool ?services ?capture_backtrace eff =
  with_runtime ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?blocking_pool ?services ?capture_backtrace @@ fun runtime ->
  Eta_eio.Runtime.run_exn runtime eff
