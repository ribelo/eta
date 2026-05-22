open Effet

type clock = Services.clock
type log = Services.log
type result = string

class type clock_log = object
  method clock : clock
  method log : log
end

let describe clock log =
  Services.write_log log ("tick=" ^ string_of_int clock.Services.now);
  "tick=" ^ string_of_int clock.Services.now

let open_row_thunk () =
  Effect.named "public.open_row" (Effect.sync (fun env -> describe env#clock env#log))

let closed_row_value =
  Effect.named "public.closed_row" (Effect.sync (fun env -> describe env#clock env#log))

let args ~clock ~log =
  Effect.named "public.args" (Effect.sync (fun _env -> describe clock log))

let bag services =
  Effect.named "public.bag" (Effect.sync (fun _env -> describe services#clock services#log))

