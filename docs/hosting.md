# Hosting ValiMC

## Ubuntu VPS

The supplied `compose.yaml` runs one vanilla survival server with online
authentication, a persistent `valimc_data` volume and a terminal command console.
It targets a small two-vCPU, 4 GB host: the container may use 3 GiB, native builds
use one Cargo job, and view/simulation distance default to vanilla's ten chunks.
The image contains the release and native library; Java, Elixir and Rust are not needed on
the host. Install Docker Engine and its Compose plugin using Docker's
[Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/).

### SSH from a Mac with 1Password

Enable **Settings → Developer → Use the SSH agent** in 1Password. The server must
have the matching public key in its login account's `authorized_keys` (Hetzner
installs the public key selected when creating a server). Keep the private key
inside 1Password. Add a host entry to the Mac's `~/.ssh/config`:

```sshconfig
Host valimc
  HostName YOUR_SERVER_IPV4
  User root
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

Run `ssh valimc` and authorize the key request in 1Password. The host entry can
also name a non-root account with permission to run Docker and write `/opt/valimc`.

### Deploy and update

Allow inbound TCP 22 and 25565 in any Hetzner firewall attached to the server.
On the host, allow SSH before enabling a host firewall. Diagnostics default to
host loopback for SSH access. Docker's published ports bypass UFW; choose the
diagnostic binding in Compose using `VALIMC_PROFILER_HOST_IP`.

From this repository on the Mac, deploy the latest committed revision:

```sh
python3 scripts/heavy.py python3 scripts/deploy_ssh.py valimc
```

The script uploads a Git archive to `/opt/valimc/releases/REVISION`, builds the
Docker image there, starts the server and checks its HTTP health. On success,
`/opt/valimc/current` points to that release. Uncommitted work and local artifacts
are excluded. Keep one server for the world; its named volume remains the same
across releases. Optional host settings live in `/opt/valimc/.env`; the deployed
image tag is set automatically. Docker starts the server after a reboot and
rotates container logs. No gameplay or capacity test runs during deployment.

Set the server's distances in `/opt/valimc/.env`, for example:

```dotenv
VALIMC_VIEW_DISTANCE=32
VALIMC_SIMULATION_DISTANCE=10
VALIMC_PROFILER_URL=http://localhost:8080
```

Deploy again to apply changes; this restarts the server. A player's view distance
is the smaller of their client setting and `VALIMC_VIEW_DISTANCE`. Simulation
distance controls ticking independently of the client setting, up to the server's
view distance. Vanilla defaults both server settings to 10; comparisons need the
same distances, world and player workload on both servers.

### Play, administer and open diagnostics

Connect Minecraft Java 26.3 to `YOUR_SERVER_IPV4:25565`. To open its console:

```sh
ssh -t valimc /opt/valimc/console
```

Commands have no leading slash: `list`, `op YourMinecraftName`, `spark health` or
`spark profiler start --timeout 60`. Join once before granting `op` so the server
knows the authenticated profile. `exit` detaches the console. `stop` ends the
server process, which Docker restarts. To keep it stopped, run `docker compose
stop` in its release directory; resume with `docker compose start`. Read logs
there with `docker compose logs --tail 100 -f server`.

For diagnostic pages, keep this running in a separate terminal on the Mac:

```sh
ssh -N -o ExitOnForwardFailure=yes -L 8080:127.0.0.1:8080 valimc
```

Run `/spark health` in Minecraft (or `spark health` in the server console), then
open the complete `http://localhost:8080/r/...` link it prints on the Mac.
`localhost` refers to the Mac's end of the tunnel; it works while that SSH command
stays running. `/healthz` is only the deployment readiness check, not the dashboard.

`VALIMC_PROFILER_URL` controls the origin printed in chat and the viewer's
LiveView/WebSocket configuration. To open reports directly through the server's
public IPv4 address, use these host settings instead and redeploy:

```dotenv
VALIMC_PROFILER_HOST_IP=0.0.0.0
VALIMC_PROFILER_URL=http://YOUR_SERVER_IPV4:8080
```

Allow inbound TCP 8080 in any Hetzner firewall attached to the server. `/spark`
then prints the public address; open its full `/r/...` link. Reports use unguessable
bearer links, so anyone given a link can read its report. Plain HTTP does not
encrypt the link or report in transit. For HTTPS, use a domain and reverse proxy
that forwards HTTP and WebSocket upgrades to loopback 8080, leave
`VALIMC_PROFILER_HOST_IP=127.0.0.1`, and set `VALIMC_PROFILER_URL` to its HTTPS origin.

Back up the complete named volume while the server is stopped; never delete it
with `docker compose down -v` unless deliberately resetting the whole dataset.
