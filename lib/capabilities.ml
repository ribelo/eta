class type clock = object
  method sleep : Duration.t -> unit
end

class type log = object
  method info : string -> unit
  method warn : string -> unit
  method error : string -> unit
end

let clock_of_eio (c : _ Eio.Std.r) : clock =
  let c = (c :> float Eio.Time.clock_ty Eio.Std.r) in
  object
    method sleep d = Eio.Time.sleep c (Duration.to_seconds_float d)
  end
