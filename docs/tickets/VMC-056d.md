# VMC-056d — Ubuntu hosting through SSH and Docker Compose

Status: Awaiting client
Milestone: Operations, alongside M3 at the user's request
Depends on: VMC-056c.

Run a fresh vanilla survival world on the user's two-vCPU, 4 GB Ubuntu VPS.
Reuse the release, attached command console and diagnostic viewer. Authenticate
SSH through 1Password's agent; the private key stays there. The user initially
chose an SSH tunnel for diagnostics, then requested direct public IPv4 access.
They will test gameplay personally.

Acceptance:

- Docker starts one server after reboot and preserves its entire world/profile
  dataset across container replacement in a named volume.
- Minecraft accepts public IPv4 on TCP 25565 with online authentication. The
  diagnostic listener defaults to host loopback for SSH, with an explicit public
  IPv4 binding option. Its advertised URL, LiveView origin and WebSocket policy
  name the chosen address; this host uses public HTTP on TCP 8080 at the user's
  request.
- The existing release console accepts ordinary commands through `docker compose
  exec`; disconnecting from it does not stop simulation. The release uses a
  loopback node name, so RPC does not require Docker's short hostname to be an FQDN.
- Bound the container to 3 GiB on the 4 GB host, rotate its logs and compile Rust
  with one Cargo job. Allow host environment overrides for view/simulation
  distance, defaulting both to vanilla's ten chunks. The user's server uses a
  32-chunk view cap and ten-chunk simulation distance for their next trial.
- Deploy a committed source snapshot without copying local research, caches,
  uncommitted gameplay changes or Git/private credentials. The source revision
  names each image and release directory; deployment preserves the data volume.
- Check startup, HTTP health, network bindings, Minecraft status and console
  feedback. No player/client driver or performance claim from these checks.

References (October 24, 2026): Docker's official Ubuntu apt installation and
Compose service reference; 1Password's SSH agent configuration. Ports published
by Docker bypass UFW, so the profiler port's host binding controls its exposure.

- https://docs.docker.com/engine/install/ubuntu/
- https://docs.docker.com/reference/compose-file/services/
- https://www.1password.dev/ssh/get-started

Checks (October 24, 2026): Docker Compose validates the configuration; Python
and embedded shell syntax pass, as do the publication/docs/layer audits. Docker
Engine 29.9.2 and Compose 5.6.1 are installed on Ubuntu 26.04.1 x86_64. The full
production image builds on the two-vCPU, 4 GB host with one Cargo job.

The initial console check exposed Docker's short hostname failing Erlang's
long-name RPC validation. Compose now explicitly uses `valimc@127.0.0.1`;
the runtime includes `libsctp1`, removing OTP's missing-library warning. The
deployed image is `valimc:447fa3e81c3ce1c8c003b388f2d3b413a227505a`, with
configuration digest `2d937b49df435afa8e4802c8b1e8ec905f0f380a8401bff0a54d5ac3919ae81a`.
The replacement retains the same `valimc_data` volume. Startup HTTP health
passes, public IPv4 Minecraft status reports Java 26.3/protocol 777, and the
fixed console's one-off `list` exits successfully without the former warnings.
The diagnostic port is published only on 127.0.0.1 and an external connection
cannot reach it. The inspected container memory limit is 3 GiB and its restart
policy is `unless-stopped`; the initial runtime check confirms BEAM runs as nobody.

The Mac has a `valimc` SSH host entry using the 1Password agent; the private key
was never exported. Renewed authentication allowed a console `spark health`
check and temporary SSH forward: the report HTML and live health JSON return
200, the HTML contains its LiveView session, and its WebSocket CSP names
`ws://localhost:8080`. The temporary verification tunnel is closed. Interactive
console use and gameplay remain the user's checks.

The user reports good TPS with the initial four-chunk settings. For their next
trial, `/opt/valimc/.env` sets view 32 and simulation 10; Compose now accepts both
overrides and defaults both to 10. The pinned 26.3
`DedicatedServerProperties` initializes `view-distance` and `simulation-distance`
to 10. `ChunkView.distance/1` still clamps the client request to the server cap;
simulation tickets remain independent of the client request. The configuration
documentation's former claim that every loaded chunk simulates was stale and
has been corrected.

The host validates the default 10/10 and overridden 32/10 Compose configurations;
the resolved service differs only in those two environment values. The running
release reports view 32, simulation 10 and `http://localhost:8080` through RPC.
The container is recreated without rebuilding its existing `447fa3e8` image and
keeps `valimc_data`; readiness passes. Before public diagnostic access, the configuration digest was
`b61c7fcaed4570fc2dbfa0a1ecef2f10c9b30a3eaa7e8de77c4eebde8dd81163`.
The Compose file in that release directory includes this configuration update;
its former version and environment files have private backups on the host.
Raw build/runtime evidence stays in `.local/hetzner/`, including
`configure-distances.log` and `health-tunnel-check.json`. No automated gameplay,
benchmark or comparative performance result is claimed.

At the user's subsequent request, the host now explicitly sets
`VALIMC_PROFILER_HOST_IP=0.0.0.0` and
`VALIMC_PROFILER_URL=http://46.225.2.68:8080`, publishes diagnostic TCP 8080 on
public IPv4 and allows it in UFW. Compose retains loopback as its default for
other hosts. The service configuration changes only the diagnostic binding and
origin; view 32, simulation 10, the image and volume stay the same. The console
prints the public report URL. From the Mac without SSH forwarding, report HTML
and live health JSON return 200, and a WebSocket upgrade with the public origin
returns 101. Evidence: `configure-public-reports.log` and
`public-report-check.json` under `.local/hetzner/`. The current configuration digest
is `2437fff6466e0af2c640e3e5667187c964f8b4bdc8120869044364b2e4887c03`.
Public reports use bearer links over HTTP, as documented; no domain or TLS proxy
is configured.

Client: the user tests Minecraft and diagnostic browsing; no automated client.
