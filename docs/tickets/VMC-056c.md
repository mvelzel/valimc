# VMC-056c — Fly trial hosting and an attached server console

Status: Parked
Milestone: Operations, alongside M3 at the user's request
Depends on: VMC-056b.
Note: The user retired the Fly app; Ubuntu hosting continues in VMC-056d.

Serve the existing ValiMC profiler through HTTPS on Fly and run one persistent
Minecraft server. Use free public IPv6 for Minecraft and shared IPv4 for HTTPS;
never allocate a dedicated IPv4. IPv4-only testers can use `fly proxy` and join
localhost. An SSH terminal attaches to the running release's command dispatcher
with `bin/console`, so the first operator can be granted with `op`.

Acceptance:

- Local viewer defaults remain loopback and ephemeral. Explicit bind/port/public
  origin settings produce usable HTTPS links, permit only that WebSocket origin
  and retain bearer-token access, CSRF, bounded views and offline exports.
- Invalid public origins and listener values fail at startup. `/healthz` exposes
  no reports or metrics; report routes without a valid token remain closed.
- The release console accepts ordinary commands, returns their feedback and
  executes with console permissions. EOF/`exit` detaches; `stop` stops the server.
  Raw command text is data, never an RPC expression or shell program.
- One 1 GiB shared-CPU Machine uses a persistent world/profile volume and online
  authentication. Its entrypoint prepares the mounted directories, then runs as
  nobody. Do not replace an existing dataset without preserving it.
- Deploy and verify HTTPS, allowed/foreign WebSocket origins, Minecraft status
  over IPv6, private proxy fallback and the attached console. No paid IPv4.

References (October 24, 2026): Fly's public networking documentation requires
dedicated IPv4 for non-TLS raw TCP over IPv4; free public IPv6 supports raw TCP.
`fly proxy` reaches the Machine over private IPv6. The Machine therefore listens
on `::`; HTTPS routes to the separate profiler listener on 8080. Fly volumes are
local to one Machine and the root filesystem is ephemeral. Keep one world owner
and one report store rather than independently load-balancing two servers.

- https://docs.fly.io/networking/services/
- https://docs.fly.io/flyctl/proxy/
- https://docs.fly.io/volumes/overview/
- W3C CSP `connect-src`: name the configured WebSocket origin explicitly.

Checks (October 24, 2026): 32 targeted console/profiler/LiveView/RCON tests pass.
The three runtime-configuration tests also pass after the final malformed-origin
cases were added. `language` and `commands` vanilla stages pass (2/2). Format,
shell syntax, publication/docs/layer audits and Fly config validation pass.

Deployment: frozen source based on `e708f7d0` plus this slice, excluding unrelated
concurrent gameplay edits. Image `deployment-01M5Q45SPX26P0MA70JKTS4ZA6`, digest
`f849147855954c5b81114a01afb1c9e24e66f46e342c78e714181fec3032935e`.
The initial full source transfer was 32.76 MB; the runtime image is 48 MB.
One Machine (`87476e4f611358`, ams, 1024 MB, one shared CPU) owns encrypted
1 GB volume `valimc_data`. The old trial's complete tiny dataset is preserved
in `.local/fly-existing-8ed9346b327658.tar.gz`; it contained empty admin lists
and clocks, without players or chunks. The other replica had no world directory.
The configured vanilla world starts fresh on the persistent volume.

Fly HTTP and game-port checks pass. Public HTTPS `/healthz` returns `ok`; a
console-generated report returns 200 with a signed LiveView mount and the public
WebSocket CSP. The release command bridge returns `list` and multiline
`spark health` output. A short-lived private proxy on local port 25566 returns
Minecraft status for Java 26.3/protocol 777, then closes cleanly. Direct public
IPv6 could not be verified from this host (`No route to host`); the documented
proxy works without native IPv6. Only free public IPv6 and shared IPv4 are
allocated. Raw logs stay in `.local/fly-*`.

Client address selection research: inspected the installed official 26.3 client
jar (SHA-1 `e877b6a07acd633fb3bb475002175cec036e7b87`).
`ServerAddressResolver.SYSTEM` calls `InetAddress.getByName`, constructs one
`InetSocketAddress` and returns it. `ConnectScreen$1.run` passes that address to
`Connection.connect`, whose Netty bootstrap uses its resolved `InetAddress`;
there is no alternate-family retry. No client class or stock version JVM
argument sets a `preferIPv*` property. IPv6 is supported, but Java 25's default
`java.net.preferIPv6Addresses=false` selects IPv4 when both DNS records exist.
`-Djava.net.preferIPv6Addresses=true` changes that selection, provided the client
has a working IPv6 route. Private bytecode stays in `.local/fly-client-*`.
Reference: https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/net/doc-files/net-properties.html

Client: the user will test gameplay and the browser personally; no delegated or
automated CUA testing. Gameplay rules are unchanged.
