# Hosting ValiMC

## Ubuntu VPS

The supplied `compose.yaml` runs one vanilla survival server with online
authentication, a persistent `valimc_data` volume and a terminal command console.
It targets a small two-vCPU, 4 GB host: the container may use 3 GiB, native builds
use one Cargo job, and view/simulation distance start at four chunks. The image
contains the release and native library; Java, Elixir and Rust are not needed on
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
On the host, allow SSH before enabling a host firewall. Diagnostics stay private
on loopback; there is no public port 8080 to open. Docker's published ports bypass
UFW, so the loopback binding in Compose is essential.

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

For diagnostic pages, keep this running on the Mac:

```sh
ssh -N -L 8080:127.0.0.1:8080 valimc
```

Open the `http://localhost:8080/r/...` link printed by the console or `/spark`.
The origin must be `localhost:8080` to match the LiveView configuration. A domain
and an HTTPS reverse proxy can be added later by changing `VALIMC_PROFILER_URL`
in `/opt/valimc/.env` and redeploying. Proxy WebSocket upgrades to loopback 8080.
Back up the complete named volume while the server is stopped; never delete it
with `docker compose down -v` unless deliberately resetting the whole dataset.
