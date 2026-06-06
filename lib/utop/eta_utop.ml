let host () = Eta.Host_eio.make ~unix:(module Eio_unix) ~eio:(module Eio) ()

let with_runtime ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?island_pool ?blocking_pool ?capture_backtrace f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eta.Runtime.with_host_eio (host ()) ~sw ~clock:(Eio.Stdenv.clock env)
    ?tracer ?sampler ?auto_instrument ?logger ?meter ?random ?island_pool
    ?blocking_pool ?capture_backtrace f

let run ?tracer ?sampler ?auto_instrument ?logger ?meter ?random ?island_pool
    ?blocking_pool ?capture_backtrace eff =
  with_runtime ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?island_pool ?blocking_pool ?capture_backtrace @@ fun runtime ->
  Eta.Runtime.run runtime eff

let run_exn ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?island_pool ?blocking_pool ?capture_backtrace eff =
  with_runtime ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?island_pool ?blocking_pool ?capture_backtrace @@ fun runtime ->
  Eta.Runtime.run_exn runtime eff
