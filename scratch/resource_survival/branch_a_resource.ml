open Effet

type ('env, 'err, 'a) t = ('env, 'err, 'a) Resource.t

let manual = Resource.manual
let auto = Resource.auto
let get = Resource.get
let refresh = Resource.refresh
let failures = Resource.failures
