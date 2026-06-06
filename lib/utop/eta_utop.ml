let host () = Eta_eio.Host.make ~unix:(module Eio_unix) ~eio:(module Eio) ()

let with_runtime ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?blocking_pool ?capture_backtrace f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eta_eio.Runtime.with_host (host ()) ~sw ~clock:(Eio.Stdenv.clock env)
    ?tracer ?sampler ?auto_instrument ?logger ?meter ?random ?blocking_pool
    ?capture_backtrace f

let run ?tracer ?sampler ?auto_instrument ?logger ?meter ?random ?blocking_pool
    ?capture_backtrace eff =
  with_runtime ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?blocking_pool ?capture_backtrace @@ fun runtime ->
  Eta_eio.Runtime.run runtime eff

let run_exn ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?blocking_pool ?capture_backtrace eff =
  with_runtime ?tracer ?sampler ?auto_instrument ?logger ?meter ?random
    ?blocking_pool ?capture_backtrace @@ fun runtime ->
  Eta_eio.Runtime.run_exn runtime eff
