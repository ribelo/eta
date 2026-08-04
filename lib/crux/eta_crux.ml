type never = Crux_graph.never = |
type 'a t = 'a Crux_graph.t

module Diagnostic = Crux_failure.Diagnostic
module Failure = struct
  include Crux_failure.Failure
  let encode_portable = Crux_portable_failure.encode
  let decode_portable = Crux_portable_failure.decode
end
module Endpoint = Crux_graph.Endpoint

let return = Crux_graph.return
let map = Crux_graph.map
let both = Crux_graph.both
let cutoff = Crux_graph.cutoff
let bind = Crux_graph.bind

module Syntax = Crux_graph.Syntax
module State_machine = Crux_graph.State_machine
let lifecycle = Crux_graph.lifecycle
module Assoc = Crux_graph.Assoc
module Source = Crux_graph.Source

module Codec = Crux_boundary.Codec
module Exported_endpoint = Crux_boundary.Exported_endpoint
module Host_operation = Crux_boundary.Host_operation
module Request = Crux_boundary.Request
module Requester = Crux_boundary.Requester
module Responder = Crux_boundary.Responder
module Request_export = Crux_boundary.Request_export

module Wire = Crux_wire.Wire
module Serialized_session = Crux_wire.Serialized_session
module Post_commit = Crux_root.Post_commit
module Root = Crux_root.Root
module Driver = Crux_driver.Driver
module Adapter = Crux_host.Adapter
module Hosted = Crux_host.Hosted
