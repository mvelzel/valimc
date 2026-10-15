# Preview compatibility

Target: vanilla Java **26.3 / protocol 777**. This is a creative flat-world preview.
Completed tickets establish their stated scope, not subsystem/full-server parity.
[Current gates](roadmap.md) and [feature backlog](backlog.md) remain explicit.

| Area | Implemented preview | Still missing |
|---|---|---|
| Protocol/login | Status, compression, registries/tags, encryption, optional real online identity | Full packet behavior, signed chat, complete session/proxy policy |
| Players | Nearby replication, saved pose/flight/modes/fall/freeze, powder freezing/thaw, input/Shift/sprint flags, selected pose/eye height, bounded block-based movement corrections, default ranges | Live mode transitions, gravity/forces, complete attributes/effects, combat/health/hunger/death |
| World | Flat chunks, simple creative edits, clocks/weather/difficulty, custom snapshots | Anvil/NBT worlds, generation/biomes/structures, real lighting, full gamerules, functional/oriented blocks |
| Inventory | Supported components, authoritative preview clicks/swaps/drops, durable cleanup/recovery | Full components/text, crafting, containers/equipment/gameplay rules; pending gesture gates |
| Items | Durable stationary scene entities, bounded replication and transfer retries | Gravity, merging, pickup, despawn and complete entity lifecycle |
| Physics | Native cached/contextual shapes, clipping/steps, live block-based pose/movement and fall-context reconciliation, supplied entity/border fitting | Complete dynamic contexts, solid entities/moving borders, gravity/forces, coupled ownership/transfers |
| Simulation | Bounded region/player owners and tick deadlines, fenced powder contact/freezing | Full survival ticks, mobs/AI, redstone, fluids, explosions and coupled mechanics |
| Extensions | Original Elixir runtime | Extension API, Java plugins and Bedrock compatibility |

Supported item data includes scalar components, bounded custom NBT, names/lore,
enchantments and tooltip controls. Unsupported structured edits restore accepted
state. Enchantment data does not implement survival effects. Component and
inventory/drop child tickets are indexed in the [backlog](backlog.md).

World/player formats are custom and bounded. Hard crashes can lose changes since
ordinary periodic checkpoints; durable item transfers have a separate journaled
contract. Idle regions remain resident up to the configured cap. See
[architecture](architecture.md) and [configuration](configuration.md).
