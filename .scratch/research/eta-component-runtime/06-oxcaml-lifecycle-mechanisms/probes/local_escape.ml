let leak n =
  let local_ r = ref n in
  r
