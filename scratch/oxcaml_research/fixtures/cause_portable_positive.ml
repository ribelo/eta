type diagnostic : value mod portable = {
  message : string;
  stack : string option;
}

type ('err : value mod portable) cause : value mod portable =
  | Fail of 'err
  | Die of diagnostic
  | Interrupt

let sample = Die { message = "boom"; stack = None }
let () = ignore sample
