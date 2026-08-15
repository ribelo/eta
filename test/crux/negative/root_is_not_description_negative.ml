let root =
  Eta_crux.Root.create
    ~catalog:(Eta_crux.Projection.Catalog.create [])
    ~projection_capacity:1 ~ingress_capacity:1 ~request_capacity:1
    (Eta_crux.return 1)

let _not_a_description = Eta_crux.map root ~f:succ
