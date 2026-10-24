# VMC-056d — Ubuntu hosting through SSH and Docker Compose

Status: In progress
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
  exec`; disconnecting from it does not stop simulation.
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

Checks: pending deployment and targeted configuration/audit checks.
Client: the user tests Minecraft and diagnostic browsing; no automated client.
