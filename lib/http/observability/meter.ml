module Client = Eta_http_client.Client

let protocol_attr protocol =
  ("network.protocol.version", Client.protocol_to_string protocol)

let record_metric ?(attrs = []) ~name ~description value =
  Eta.Effect.metric_update ~name ~description ~unit_:"{connection}" ~attrs
    ~kind:Eta.Capabilities.Gauge (Eta.Capabilities.Int value)

let record_client_stats ?(attrs = []) client =
  Client.stats client
  |> Eta.Effect.bind (fun stats ->
         let attrs = protocol_attr stats.Client.protocol :: attrs in
         Eta.Effect.concat
           [
             record_metric ~attrs ~name:"eta_http.client.connections.active"
               ~description:"Active eta-http client connections" stats.active;
             record_metric ~attrs ~name:"eta_http.client.connections.idle"
               ~description:"Idle eta-http client connections" stats.idle;
             record_metric ~attrs ~name:"eta_http.client.connections.capacity"
               ~description:"Configured eta-http client connection capacity"
               stats.capacity;
             record_metric ~attrs ~name:"eta_http.client.connections.opened"
               ~description:"Opened eta-http client connections" stats.opened;
             record_metric ~attrs ~name:"eta_http.client.connections.released"
               ~description:"Released eta-http client connections" stats.released;
           ])
