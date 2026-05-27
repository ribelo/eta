let capture_channel (channel : (int, [ `Closed ]) Eta.Channel.t) =
  let domain =
    Domain.Safe.spawn (fun () -> ignore (Eta.Channel.stats channel))
  in
  Domain.join domain
