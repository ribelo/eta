let root =
  Eta_crux.Root.create ~ingress_capacity:1 ~request_capacity:1
    (Eta_crux.return 1)

let _not_a_description = Eta_crux.map root ~f:succ
