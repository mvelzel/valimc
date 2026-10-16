# Preview compatibility

Target: vanilla Java **26.3 / protocol 777**. This is a creative flat-world preview.
Completed tickets establish their stated scope, not subsystem/full-server parity.
[Current gates](roadmap.md) and [feature backlog](backlog.md) remain explicit.

| Area | Implemented preview | Still missing |
|---|---|---|
| Protocol/login | Status, compression, registries/tags, encryption, optional real online identity | Full packet behavior, signed chat, complete session/proxy policy |
| Players | Nearby replication, saved pose/flight/modes/fall/freeze/health, hurt timers, powder freezing/thaw, ordered fire/soul/lava and magma/campfire/cactus/berry contacts with gear/wear, owned Speed/Slowness, Resistance/Fire Resistance/Water Breathing/regeneration/poison/wither, durations/reconnect, supported potion drinking and stock milk/honey removal, respawn and translated environmental deaths, roof-aware flat-plains rain extinction, input/Shift/sprint flags, selected pose/eye height, bounded block-based movement corrections, default ranges | Remaining status effects/attributes, live mode transitions, complete forces and remaining damage/combat/consumption rules |
| World | Flat chunks, creative edits, basic/slab survival mining and placement, clocks/weather/difficulty, custom snapshots | Anvil/NBT worlds, generation/biomes/structures, real lighting, full gamerules, functional/oriented blocks |
| Inventory | Supported components, authoritative clicks/swaps/drops, manual2×2/3×3 ordinary/remainder recipes, bounded bulk crafting, durable cleanup/recovery, six-slot equipment replication | Recipe book, special/component crafting outputs, full components/containers/equipment rules; pending gesture gates |
| Items | Owned dropped entities, bounded motion/fluid travel, same/cross-owner merging, ordinary pickup, void disposal and durable transfer retries | Advanced pickup contexts, remaining entity lifecycle and rendering edges |
| Physics | Native shapes/clipping/steps, live pose/movement/fall reconciliation, default dry/fluid velocity, swimming/climbing/slowing contacts, sneaking edge protection, supplied entity/border fitting | Complete forces/effects and dynamic contexts, solid entities/moving borders, coupled ownership/transfers |
| Simulation | Bounded region/player owners and tick deadlines, fenced powder contact/freezing | Full survival ticks, mobs/AI, redstone, fluid propagation, explosions and coupled mechanics |
| Extensions | Original Elixir runtime | Extension API, Java plugins and Bedrock compatibility |

Supported item data includes scalar components, bounded custom NBT, names/lore,
enchantments, potion contents and tooltip controls. Unsupported structured edits
restore accepted state. Data support does not imply every corresponding gameplay effect. Component and
inventory/drop child tickets are indexed in the [backlog](backlog.md).

World/player formats are custom and bounded. Hard crashes can lose changes since
ordinary periodic checkpoints; durable item transfers have a separate journaled
contract. Idle regions remain resident up to the configured cap. See
[architecture](architecture.md) and [configuration](configuration.md).
