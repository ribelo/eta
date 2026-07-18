let mapped : int list Contract.effect =
  Contract.map_par [ 1; 2 ] ~f:Contract.pure

let retried : int Contract.effect =
  Contract.retry (Contract.pure 1) ~schedule:() ~while_:(fun _ -> true)

let repeated : int Contract.effect =
  Contract.repeat (Contract.pure 1) ~schedule:()
