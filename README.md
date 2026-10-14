# ValiMC

An Elixir/OTP Minecraft Java Edition server targeting **26.3, protocol 777**. Built with **Elixir 1.20.4 / Erlang/OTP 29.1.1**, installed and pinned through asdf.

This is a runnable **creative flat-world development preview**. Vanilla survival compatibility is the project direction; it has not been achieved. This implementation establishes the protocol, state ownership, replication, persistence and measurement foundations. It does not claim to outperform Paper, Pumpkin or SteelMC.

## Run

```sh
asdf install
mix run --no-halt
```

Connect with a vanilla **Java 26.3** client to `localhost:25565`. The default binds to `127.0.0.1` and uses offline identities. Runtime requires only Elixir/Erlang; there are no Hex dependencies, JVMs, Rust libraries or external services in the server.

Creative player-menu edits preserve item identity/count and twelve scalar component types plus bounded custom NBT, item names, lore, and active/stored enchantment maps across main storage, armor, hotbar and offhand. Names/lore accept bounded literal/styled, translation and keybind text; selector/score/NBT/object contents and interactive events remain unsupported. Enchantment data and tooltips are preserved; survival enchantment effects remain unimplemented. Tooltip controls can hide selected sections or the whole tooltip while retaining all underlying item data. Other unsupported structured patches restore the previous slot with a message. Inventory snapshots, hotbar selection, hand swapping and ordinary block placement from either hand are synchronized. Basic pickup/split/merge, shift transfer, number-key/offhand swap, quick-craft and double-click collection use authoritative slots; creative clone/fill require owner permission. Connected menu close returns what fits and commits overflow as a durable item batch; automated and actual close/retry/reconnect/restart checks pass. Sustained multi-slot client input remains a validation gate. In-world Q/Ctrl+Q controls use durable inventory transfers into stationary preview items; actual keyboard, stalled-transfer and restart checks pass. Ordinary menu THROW/outside cursor drops now pass actual mouse/keyboard, stalled-transfer and reconnect/restart checks; creative Q/Ctrl+Q preserves ordered paired slot writes with permission/throttle checks; actual keyboard, stalled burst and recovery checks pass; crafting interactions still restore state. `/help`, `/stats` and `/spawn` support client validation and Tab completion. Block edits and combined player pose/inventory snapshots are checkpointed every 30 seconds. Player state also saves on disconnect and graceful shutdown; reconnect restores position, view direction, supported inventory contents and selection. Disconnect now journals whole cursor/grid drops and recovery; automated and actual offline drop/rejoin/restart/pending replay/orphan cleanup checks pass.

```sh
VALIMC_PORT=25566 VALIMC_WORLD=/tmp/valimc-world mix run --no-halt
iex -S mix
# In IEx:
Valimc.Metrics.snapshot()
# Graceful shutdown, including dirty region saves:
System.stop()
```

Game time and the registered Overworld/End clocks now advance and synchronize using the 26.3 time packet. Clock state saves separately; day/night, pause, reconnect and restart have actual-client coverage. Overworld rain/thunder timers, intensity ramps and weather-cycle control also advance and persist, with actual-client transition/recovery coverage. Lightning, snow/ice, full gamerules and vanilla time/weather commands remain future work.

World difficulty and its lock now persist and synchronize at login and after trusted host changes. The native dedicated-server default is Easy. Difficulty-dependent gameplay and client administration remain future work.

Configuration lives in `config/config.exs`; `VALIMC_BIND`, `VALIMC_PORT` and `VALIMC_WORLD` override runtime settings. Public hosting requires authentication and encryption to be implemented first.

## Elixir architecture

- A socket-owning process holds each player's protocol, inventory preview, input limits and replication state. `active: :once` TCP limits inbound buffering.
- Region processes own mutable block state and bounded stationary items. Item mutations check owner incarnations/revisions and publish after writer acknowledgment; observers sample protected ETS views and share cached packet binaries. Independent regions maintain their own 50 ms deadlines; survival simulation remains future work.
- Player processes publish their own latest positions to ETS. A spatial index lets each observer sample nearby players concurrently. Movement replication uses compact quantized snapshots and one socket batch per observer interval, avoiding a movement-message fan-out into player mailboxes.
- A bounded `Task.Supervisor` runs chunk encoders. Regions combine duplicate requests, share immutable encoded binaries, and discard stale results after edits. Baseline terrain is an immutable shared binary; edited chunks use paletted sections.
- Each region has a linked disk writer. Periodic saves run outside the region process and carry revision acknowledgments. A failed writer takes down its owner; later access recreates the region from the last saved snapshot.
- Each connected identity leases its own short-lived state writer. Item serialization and file I/O run outside socket owners, checkpoint queues are bounded, and UUID leases fence overlapping sessions. Corrupt saves preserve the file and reject only that login; write failures disconnect only their owner.
- Supervisors restart dependent infrastructure with `rest_for_one`. A failed connection or listener has a limited failure scope. Connection counts, region counts, input sizes, rates, worker concurrency and slow-client mailboxes have explicit limits.

See [architecture and consistency boundaries](docs/architecture.md), [source research](docs/research.md), and [measurements](docs/performance.md).

## Verify

```sh
mix format --check-formatted
mix test
MIX_ENV=prod mix release
_build/prod/rel/valimc/bin/valimc start
```

The ExUnit suite exercises wire framing, compression limits, negative coordinates, ownership races, shared encoding, worker saturation, persistence, connection isolation, movement replication and mailbox overload.

An additional TCP client uses **Mojang's actual 26.3 packet encoders and decoders**. It checks compressed login, all 32 synchronized registries, network registry/tag dependency loading against the vanilla data pack, 49 spawn chunks including section decoding, two-player visibility, movement, block placement/breaking and commands. This is a protocol oracle, not a graphical Minecraft client test. [Client testing notes](docs/client-testing.md) track the separate graphical-client evidence.

```sh
# Development-only: Java 25+ and Python 3. No Java is used by the Elixir server.
export VALIMC_JAVA_HOME=/path/to/jdk-25
python3 scripts/prepare_vanilla.py
python3 scripts/check_vanilla.py
```

The official jar is checksum verified and stays outside version control. `scripts/generate_protocol.py` regenerates the committed protocol facts from official reports. The vanilla gameplay server is not launched, and no EULA is accepted by these tools.

Load tests run their Python clients in a separate process, start a temporary server, capture BEAM metrics, and clean up:

```sh
python3 bench/load.py --players 128 --seconds 5
python3 bench/load.py --players 512 --seconds 5 --scatter
```

## Compatibility limits

Implemented: Java 26.3 status/ping, offline login, zlib compression, vanilla core-pack registry negotiation, flat chunks, preview lighting, creative movement, nearby player visibility, plain system chat, ordinary block placement/breaking, custom region snapshots and player pose persistence.

Item entity packet primitives pass Mojang codec and graphical checks. Region-owned
stationary development items now replicate stack updates, visibility, reconnect
and owner recovery through bounded snapshots. Stationary item UUIDs/positions/
supported stacks now persist in bounded custom region files. They have no gravity/
physics or pickup. An internal region inbox now commits stable-UUID item batches
and bounded per-source retry receipts together; retries after removal/restart do
not recreate items. A leased source API now conserves supported stacks and saves
reduced inventory plus one outbox atomically, with stale-checkpoint fencing and
destination receipt verification. Pending source intents now recover automatically
through bounded asynchronous jobs before login publishes inventory. Conflicts or
unavailable storage preserve the intent and reject that login. Connected-session
Q/Ctrl+Q invokes source prepare/delivery/clear with one
in-flight transfer, inventory mutation corrections and live movement/chat. Actual
keyboard controls, stalled corrections and reconnect/restart pass. Ordinary menu
THROW/outside cursor effects now use that path; actual menu input, empty no-ops,
stalled correction and exact reconnect/restart recovery pass. Connected close overflow now commits partial return plus up to five
remainders in one batch; actual close/retry/reconnect/restart checks pass. Disconnected menu
cleanup journals whole cursor/grid stacks even with free storage, completes after
socket exit and permits fenced reconnect recovery; automated and actual offline
drop/disconnect/rejoin/restart/pending replay/orphan-save cleanup checks pass.

Supported stack comparisons now use effective prototype components: redundant
defaults and absent removals merge, while changed values or removal of present
defaults remain distinct. NBT comparison follows Mojang's numeric/list equality.
Raw codec/save/journal bytes are preserved. Automated checks, 11,797 Mojang
identity pairs and actual merges/distinct-component controls/overflow/recovery pass.

A separate internal creative-creation source API retains inventory and journals
one authorized new stack through the same durable recovery. Automated and actual
client API recovery/reconnect/restart/removal checks pass. Connected creative drops now preserve bounded paired command order with permission
and vanilla throttle checks; automated/oracle and actual Q/held Ctrl+Q, stalled
burst/reconnect/restart checks pass. Earlier mouse gesture gates remain pending.

Missing: online authentication/encryption, Bedrock, survival rules, collision/anti-cheat, complete inventories and item components, crafting, combat, hunger, mobs/AI, redstone, fluids, block entities, vanilla terrain/structures, real light propagation, Anvil world import/export, complete player state persistence, plugin APIs and Java plugin compatibility. Known but unimplemented play packets are ignored; this is not full protocol parity. Default-item placement does not implement directional or functional block behavior.

Fixed spatial regions currently support independent edits. Neighbor-coupled simulation, deterministic entity transfers, and multi-region transactions are specified as future work, not implemented. Hard crashes can lose changes since the last 30-second checkpoint. Player `.pose` files use bounded custom versions 2/3 under `world/players/`, with legacy pose migration and a version 3 transfer outbox; they are not vanilla player NBT. Storage errors/timeouts are explicit and can prevent a final save. Idle regions remain resident until shutdown, within the configured region limit.

See [the tracked roadmap](docs/roadmap.md), [development and verification process](docs/development.md), and [agent instructions](AGENTS.md). Work proceeds one ticket at a time. Local checkpoints may precede actual Minecraft computer-use validation. Development and normal pushes use `main`; pending client gates remain explicit if the user requests publication before every gate passes.

## References

Nineteen pinned reference checkouts are downloaded under ignored `research/sources/`, including Pumpkin, SteelMC, Paper/Folia, Cuberite, Glowstone, MCHPRS, Feather, Go-MC, Flying Squid, MultiPaper and Dragonfly. [The survey](docs/research.md) records each one's useful subsystems and limitations. `research/sources.lock.json` records exact commits; `python3 scripts/fetch_sources.py` recreates them. Vanilla 26.3 defines exact compatibility; other implementations contribute evidence and design ideas.

The Elixir implementation is original code informed by protocol behavior and architecture research. Upstream implementations have their own licenses; their source and license files are preserved in the reference checkouts. Protocol metadata records versioned wire facts. Mojang's implementation and assets are not bundled in the runtime.
