# VMC-056d — Ubuntu hosting through SSH and Docker Compose

Status: Awaiting client
Milestone: Operations, alongside M3 at the user's request
Depends on: VMC-056c.

Run a fresh vanilla survival world on the user's two-vCPU, 4 GB Ubuntu VPS.
Reuse the release, attached command console and diagnostic viewer. Authenticate
SSH through 1Password's agent; the private key stays there. The user chose an SSH
tunnel for diagnostics and will test gameplay personally.

Acceptance:

- Docker starts one server after reboot and preserves its entire world/profile
  dataset across container replacement in a named volume.
- Minecraft accepts public IPv4 on TCP 25565 with online authentication. The
  diagnostic listener is published only on host loopback, reached through SSH;
  its URL, LiveView origin and WebSocket policy name the tunnel's local origin.
- The existing release console accepts ordinary commands through `docker compose
  exec`; disconnecting from it does not stop simulation. The release uses a
  loopback node name, so RPC does not require Docker's short hostname to be an FQDN.
- Bound the container to 3 GiB on the 4 GB host, rotate its logs and compile Rust
  with one Cargo job. Keep view/simulation distance four as in the Fly trial.
- Deploy a committed source snapshot without copying local research, caches,
  uncommitted gameplay changes or Git/private credentials. The source revision
  names each image and release directory; deployment preserves the data volume.
- Check startup, HTTP health, network bindings, Minecraft status and console
  feedback. No player/client driver or performance claim from these checks.

References (October 24, 2026): Docker's official Ubuntu apt installation and
Compose service reference; 1Password's SSH agent configuration. Ports published
by Docker bypass UFW, so the profiler port itself binds host loopback.

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
was never exported. Extra tunnel/report and interactive-console checks await
renewed 1Password key authorization. Raw build/runtime evidence stays in
`.local/hetzner/`. No gameplay or comparative performance result is claimed.

Client: the user tests Minecraft and diagnostic browsing; no automated client.
