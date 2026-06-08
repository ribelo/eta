module PA = Portable.Atomic

type conn = { stream : int Eio.Stream.t }

type node = {
  value : conn;
  next : node option;
}

let stream = Eio.Stream.create 1

let conn = { stream }

let head : node option PA.t = PA.make None

let () =
  let old = PA.get head in
  let node = Some { value = conn; next = old } in
  ignore (PA.compare_and_set head ~if_phys_equal_to:old ~replace_with:node)
