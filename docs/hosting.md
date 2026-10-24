# Trial hosting on Fly

The supplied `fly.toml` runs one ValiMC server in Amsterdam on a shared CPU with
1 GiB RAM, a 1 GiB persistent volume, online authentication and a vanilla survival
world. View and simulation distance are four chunks to fit a small trial Machine.
Minecraft uses free public IPv6 on port 25565. Diagnostics use HTTPS at
`https://valimc.fly.dev` through Fly's shared IPv4 and IPv6. A dedicated IPv4 is
not required or allocated. Compute, storage and traffic still use Fly's normal
billing. The server stays running until stopped so a private proxy session is
not interrupted by HTTP-based idle detection.

## Deploy

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

## Connect

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

## Server terminal and operators

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

## Stop and start the trial

Use `fly machine list -a valimc` to find the Machine ID, then
`fly machine stop <id> -a valimc` when finished. Storage remains allocated.
`fly machine start <id> -a valimc` starts it again. An incoming public request
can also start it because autostart is enabled. Disable autostart or remove the
app when the trial should no longer run; avoid destroying its volume until its
data is no longer needed.
