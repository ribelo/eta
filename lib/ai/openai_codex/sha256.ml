(** Minimal SHA-256 for PKCE S256. Private to eta_ai_openai_codex. *)

let rotr32 x n =
  let n = n land 31 in
  Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))

let ch x y z = Int32.logxor (Int32.logand x y) (Int32.logand (Int32.lognot x) z)

let maj x y z =
  Int32.logxor (Int32.logand x y)
    (Int32.logxor (Int32.logand x z) (Int32.logand y z))

let bsig0 x =
  Int32.logxor (rotr32 x 2) (Int32.logxor (rotr32 x 13) (rotr32 x 22))

let bsig1 x =
  Int32.logxor (rotr32 x 6) (Int32.logxor (rotr32 x 11) (rotr32 x 25))

let ssig0 x =
  Int32.logxor (rotr32 x 7)
    (Int32.logxor (rotr32 x 18) (Int32.shift_right_logical x 3))

let ssig1 x =
  Int32.logxor (rotr32 x 17)
    (Int32.logxor (rotr32 x 19) (Int32.shift_right_logical x 10))

let k =
  [|
    0x428a2f98l;
    0x71374491l;
    0xb5c0fbcfl;
    0xe9b5dba5l;
    0x3956c25bl;
    0x59f111f1l;
    0x923f82a4l;
    0xab1c5ed5l;
    0xd807aa98l;
    0x12835b01l;
    0x243185bel;
    0x550c7dc3l;
    0x72be5d74l;
    0x80deb1fel;
    0x9bdc06a7l;
    0xc19bf174l;
    0xe49b69c1l;
    0xefbe4786l;
    0x0fc19dc6l;
    0x240ca1ccl;
    0x2de92c6fl;
    0x4a7484aal;
    0x5cb0a9dcl;
    0x76f988dal;
    0x983e5152l;
    0xa831c66dl;
    0xb00327c8l;
    0xbf597fc7l;
    0xc6e00bf3l;
    0xd5a79147l;
    0x06ca6351l;
    0x14292967l;
    0x27b70a85l;
    0x2e1b2138l;
    0x4d2c6dfcl;
    0x53380d13l;
    0x650a7354l;
    0x766a0abbl;
    0x81c2c92el;
    0x92722c85l;
    0xa2bfe8a1l;
    0xa81a664bl;
    0xc24b8b70l;
    0xc76c51a3l;
    0xd192e819l;
    0xd6990624l;
    0xf40e3585l;
    0x106aa070l;
    0x19a4c116l;
    0x1e376c08l;
    0x2748774cl;
    0x34b0bcb5l;
    0x391c0cb3l;
    0x4ed8aa4al;
    0x5b9cca4fl;
    0x682e6ff3l;
    0x748f82eel;
    0x78a5636fl;
    0x84c87814l;
    0x8cc70208l;
    0x90befffal;
    0xa4506cebl;
    0xbef9a3f7l;
    0xc67178f2l;
  |]

let get_be32 b off =
  let b0 = Char.code (Bytes.get b off) in
  let b1 = Char.code (Bytes.get b (off + 1)) in
  let b2 = Char.code (Bytes.get b (off + 2)) in
  let b3 = Char.code (Bytes.get b (off + 3)) in
  Int32.logor
    (Int32.shift_left (Int32.of_int b0) 24)
    (Int32.logor
       (Int32.shift_left (Int32.of_int b1) 16)
       (Int32.logor (Int32.shift_left (Int32.of_int b2) 8) (Int32.of_int b3)))

let set_be32 b off v =
  Bytes.set b off
    (Char.chr (Int32.to_int (Int32.shift_right_logical v 24) land 0xff));
  Bytes.set b (off + 1)
    (Char.chr (Int32.to_int (Int32.shift_right_logical v 16) land 0xff));
  Bytes.set b (off + 2)
    (Char.chr (Int32.to_int (Int32.shift_right_logical v 8) land 0xff));
  Bytes.set b (off + 3) (Char.chr (Int32.to_int v land 0xff))

let digest_bytes input =
  let h =
    [|
      0x6a09e667l;
      0xbb67ae85l;
      0x3c6ef372l;
      0xa54ff53al;
      0x510e527fl;
      0x9b05688cl;
      0x1f83d9abl;
      0x5be0cd19l;
    |]
  in
  let bit_len = Int64.mul (Int64.of_int (Bytes.length input)) 8L in
  let len = Bytes.length input in
  let pad_len =
    let r = (len + 1) mod 64 in
    if r <= 56 then 56 - r else 120 - r
  in
  let total = len + 1 + pad_len + 8 in
  let msg = Bytes.create total in
  Bytes.blit input 0 msg 0 len;
  Bytes.set msg len '\x80';
  for i = len + 1 to total - 9 do
    Bytes.set msg i '\x00'
  done;
  set_be32 msg (total - 8)
    (Int64.to_int32 (Int64.shift_right_logical bit_len 32));
  set_be32 msg (total - 4) (Int64.to_int32 bit_len);
  let w = Array.make 64 0l in
  let process_block off =
    for t = 0 to 15 do
      w.(t) <- get_be32 msg (off + (t * 4))
    done;
    for t = 16 to 63 do
      w.(t) <-
        Int32.add
          (Int32.add (ssig1 w.(t - 2)) w.(t - 7))
          (Int32.add (ssig0 w.(t - 15)) w.(t - 16))
    done;
    let a = ref h.(0) in
    let b = ref h.(1) in
    let c = ref h.(2) in
    let d = ref h.(3) in
    let e = ref h.(4) in
    let f = ref h.(5) in
    let g = ref h.(6) in
    let hh = ref h.(7) in
    for t = 0 to 63 do
      let t1 =
        Int32.add
          (Int32.add (Int32.add !hh (bsig1 !e)) (Int32.add (ch !e !f !g) k.(t)))
          w.(t)
      in
      let t2 = Int32.add (bsig0 !a) (maj !a !b !c) in
      hh := !g;
      g := !f;
      f := !e;
      e := Int32.add !d t1;
      d := !c;
      c := !b;
      b := !a;
      a := Int32.add t1 t2
    done;
    h.(0) <- Int32.add h.(0) !a;
    h.(1) <- Int32.add h.(1) !b;
    h.(2) <- Int32.add h.(2) !c;
    h.(3) <- Int32.add h.(3) !d;
    h.(4) <- Int32.add h.(4) !e;
    h.(5) <- Int32.add h.(5) !f;
    h.(6) <- Int32.add h.(6) !g;
    h.(7) <- Int32.add h.(7) !hh
  in
  let rec loop off =
    if off < total then (
      process_block off;
      loop (off + 64))
  in
  loop 0;
  let out = Bytes.create 32 in
  for i = 0 to 7 do
    set_be32 out (i * 4) h.(i)
  done;
  out

let digest_string s = digest_bytes (Bytes.of_string s)
