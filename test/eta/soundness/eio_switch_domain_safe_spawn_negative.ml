let capture_switch (sw : Eio.Switch.t) =
  let domain = Domain.Safe.spawn (fun () -> ignore sw) in
  Domain.join domain
