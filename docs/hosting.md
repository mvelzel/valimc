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
also name a non-root account with permission to run Docker.

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
ssh -t valimc 'cd /opt/valimc/current && docker compose exec server /app/bin/console'
```

Commands have no leading slash: `list`, `op YourMinecraftName`, `spark health` or
`spark profiler start --timeout 60`. Join once before granting `op` so the server
knows the authenticated profile. `exit` detaches the console; `stop` shuts down
the server. Start a stopped container with `docker compose start` in its release
directory. Read logs there with `docker compose logs --tail 100 -f server`.

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

## Fly trial

The supplied `fly.toml` runs one ValiMC server in Amsterdam on a shared CPU with
1 GiB RAM, a 1 GiB persistent volume, online authentication and a vanilla survival
world. View and simulation distance are four chunks to fit a small trial Machine.
Minecraft uses free public IPv6 on port 25565. Diagnostics use HTTPS at
`https://valimc.fly.dev` through Fly's shared IPv4 and IPv6. A dedicated IPv4 is
not required or allocated. Compute, storage and traffic still use Fly's normal
billing. The server stays running until stopped so a private proxy session is
not interrupted by HTTP-based idle detection.

### Deploy

The trial volume is provisioned once. For a new installation, first check
`fly volumes list -a valimc`; if `valimc_data` is absent, create it with
`fly volumes create valimc_data -a valimc --region ams --size 1`.

```sh
fly deploy --remote-only --ha=false
```

Keep exactly one Machine: worlds, players and active reports belong to that
server. The `valimc_data` volume mounts at `/data`; the world lives in
`/data/world`, including operator lists, and completed profiles in `/data/profiles`.
The container prepares those directories as root, then drops to nobody before
starting the release. Back up the whole world dataset rather than selected files.

### Connect

On an IPv6-capable connection, run `fly ips list -a valimc` and enter the public
IPv6 address in Minecraft as `[address]:25565`. Use the literal IPv6 address:
the `valimc.fly.dev` hostname also has a shared IPv4 record for HTTPS. The stock
26.3 client resolves one address with `InetAddress.getByName`, then connects to
that address without trying the other address family. Java prefers IPv4 by
default when both records exist, so it selects the shared IPv4, which cannot
carry raw Minecraft TCP. On a working IPv6 connection, the client JVM argument
`-Djava.net.preferIPv6Addresses=true` makes the hostname select IPv6 instead.

For an IPv4-only connection, keep this running on your computer:

```sh
fly proxy 25565:25565 -a valimc
```

Then join `localhost:25565` in Minecraft Java 26.3. This is a private authenticated
tunnel; friends without IPv6 need their own authorized tunnel or another TCP
relay. Fly's shared IPv4 alone cannot accept unmodified Minecraft connections.

### Server terminal and operators

```sh
fly ssh console -a valimc --pty -C /app/bin/console
```

Or SSH first, then run `/app/bin/console`. At its `>` prompt enter ordinary
Minecraft server commands without a leading slash:

```text
list
op YourMinecraftName
spark health
spark profiler start --timeout 60
```

In online mode, join once before `op` so the server knows the account's verified
profile. Operator grants persist in the world. `exit` or Ctrl-D detaches the
terminal; `stop` shuts down the server. One-off commands also work:

```sh
fly ssh console -a valimc -C '/app/bin/console list'
```

`spark health` and profiler commands print token-bearing links on
`https://valimc.fly.dev/r/...`. Open those links in any browser. They work over
IPv4 and IPv6, and live views update through HTTPS WebSockets. Keep report links
private when their contents are private; the link grants read access.

### Stop and start the trial

Use `fly machine list -a valimc` to find the Machine ID, then
`fly machine stop <id> -a valimc` when finished. Storage remains allocated.
`fly machine start <id> -a valimc` starts it again. An incoming public request
can also start it because autostart is enabled. Disable autostart or remove the
app when the trial should no longer run; avoid destroying its volume until its
data is no longer needed.
