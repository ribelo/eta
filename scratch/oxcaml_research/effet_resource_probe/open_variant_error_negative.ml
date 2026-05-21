open! Portable

module P_atomic = Portable.Atomic

type ('err : immutable_data) failures = 'err list P_atomic.t

let _failures : [> `Refresh_failed of string ] failures = P_atomic.make []
