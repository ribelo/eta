let constants =
  [|
    0x428a2f98l; 0x71374491l; 0xb5c0fbcfl; 0xe9b5dba5l;
    0x3956c25bl; 0x59f111f1l; 0x923f82a4l; 0xab1c5ed5l;
    0xd807aa98l; 0x12835b01l; 0x243185bel; 0x550c7dc3l;
    0x72be5d74l; 0x80deb1fel; 0x9bdc06a7l; 0xc19bf174l;
    0xe49b69c1l; 0xefbe4786l; 0x0fc19dc6l; 0x240ca1ccl;
    0x2de92c6fl; 0x4a7484aal; 0x5cb0a9dcl; 0x76f988dal;
    0x983e5152l; 0xa831c66dl; 0xb00327c8l; 0xbf597fc7l;
    0xc6e00bf3l; 0xd5a79147l; 0x06ca6351l; 0x14292967l;
    0x27b70a85l; 0x2e1b2138l; 0x4d2c6dfcl; 0x53380d13l;
    0x650a7354l; 0x766a0abbl; 0x81c2c92el; 0x92722c85l;
    0xa2bfe8a1l; 0xa81a664bl; 0xc24b8b70l; 0xc76c51a3l;
    0xd192e819l; 0xd6990624l; 0xf40e3585l; 0x106aa070l;
    0x19a4c116l; 0x1e376c08l; 0x2748774cl; 0x34b0bcb5l;
    0x391c0cb3l; 0x4ed8aa4al; 0x5b9cca4fl; 0x682e6ff3l;
    0x748f82eel; 0x78a5636fl; 0x84c87814l; 0x8cc70208l;
    0x90befffal; 0xa4506cebl; 0xbef9a3f7l; 0xc67178f2l;
  |]

let initial =
  [|
    0x6a09e667l; 0xbb67ae85l; 0x3c6ef372l; 0xa54ff53al;
    0x510e527fl; 0x9b05688cl; 0x1f83d9abl; 0x5be0cd19l;
  |]

let ( +! ) = Int32.add
let ( ^! ) = Int32.logxor
let ( &! ) = Int32.logand
let ( |! ) = Int32.logor
let not32 = Int32.lognot

let rotate_right value count =
  Int32.(
    shift_right_logical value count
    |! shift_left value (32 - count))

let choose x y z = (x &! y) ^! (not32 x &! z)
let majority x y z = (x &! y) ^! (x &! z) ^! (y &! z)

let big_sigma0 value =
  rotate_right value 2 ^! rotate_right value 13
  ^! rotate_right value 22

let big_sigma1 value =
  rotate_right value 6 ^! rotate_right value 11
  ^! rotate_right value 25

let small_sigma0 value =
  rotate_right value 7 ^! rotate_right value 18
  ^! Int32.shift_right_logical value 3

let small_sigma1 value =
  rotate_right value 17 ^! rotate_right value 19
  ^! Int32.shift_right_logical value 10

let padded input =
  let length = Bytes.length input in
  let padding =
    let remainder = (length + 1 + 8) mod 64 in
    if remainder = 0 then 0 else 64 - remainder
  in
  let result = Bytes.make (length + 1 + padding + 8) '\000' in
  Bytes.blit input 0 result 0 length;
  Bytes.set result length '\x80';
  Bytes.set_int64_be result
    (Bytes.length result - 8)
    (Int64.mul (Int64.of_int length) 8L);
  result

let digest input =
  let state = Array.copy initial in
  let message = padded input in
  let schedule = Array.make 64 0l in
  for block = 0 to (Bytes.length message / 64) - 1 do
    let offset = block * 64 in
    for index = 0 to 15 do
      schedule.(index) <-
        Bytes.get_int32_be message (offset + (index * 4))
    done;
    for index = 16 to 63 do
      schedule.(index) <-
        small_sigma1 schedule.(index - 2)
        +! schedule.(index - 7)
        +! small_sigma0 schedule.(index - 15)
        +! schedule.(index - 16)
    done;
    let a = ref state.(0) in
    let b = ref state.(1) in
    let c = ref state.(2) in
    let d = ref state.(3) in
    let e = ref state.(4) in
    let f = ref state.(5) in
    let g = ref state.(6) in
    let h = ref state.(7) in
    for index = 0 to 63 do
      let first =
        !h +! big_sigma1 !e +! choose !e !f !g
        +! constants.(index) +! schedule.(index)
      in
      let second = big_sigma0 !a +! majority !a !b !c in
      h := !g;
      g := !f;
      f := !e;
      e := !d +! first;
      d := !c;
      c := !b;
      b := !a;
      a := first +! second
    done;
    state.(0) <- state.(0) +! !a;
    state.(1) <- state.(1) +! !b;
    state.(2) <- state.(2) +! !c;
    state.(3) <- state.(3) +! !d;
    state.(4) <- state.(4) +! !e;
    state.(5) <- state.(5) +! !f;
    state.(6) <- state.(6) +! !g;
    state.(7) <- state.(7) +! !h
  done;
  let output = Bytes.create 32 in
  Array.iteri
    (fun index word ->
      Bytes.set_int32_be output (index * 4) word)
    state;
  output

let xor_pad key value =
  Bytes.init 64 (fun index ->
      Char.chr
        (Char.code key.[index] lxor value))

let hmac ~key message =
  if String.length key > 64 then
    invalid_arg "Eta Crux HMAC key exceeds 64 bytes";
  let key =
    key ^ String.make (64 - String.length key) '\000'
  in
  let inner =
    Bytes.cat (xor_pad key 0x36) message |> digest
  in
  Bytes.cat (xor_pad key 0x5c) inner |> digest
