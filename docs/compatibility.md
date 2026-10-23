# Compatibility

Target: vanilla Java **26.3 / protocol 777**. ValiMC generates and serves real
vanilla worlds; survival gameplay beyond the player's own body is incomplete.
Completed tickets establish their stated scope, not subsystem or full-server
parity. [Current work](roadmap.md) and the [feature backlog](backlog.md) say
what remains.

| Area | Implemented | Still missing |
|---|---|---|
| Protocol/login | Status, compression, registries and tags, encryption, optional online authentication, configuration and the vanilla command tree with server suggestions | Signed chat and command signatures, complete session and proxy policy |
| Worlds | Vanilla generation of the overworld, the Nether and the End, live and per chunk: noise terrain, biomes, features, structures and their loot, per-chunk lighting; world presets and data packs; Anvil import and export; flat worlds; portals between dimensions; world border, spawn search, clock, weather and difficulty | Fluid propagation, the dragon fight, remaining gamerules |
| Blocks | Creative edits; survival mining of every block (its loot table, experience and what the break also breaks) and placement of every block item; vanilla block updates in a Rust engine (shape updates, support, survival and redstone wire power); chests, crafting tables and the three furnaces; TNT, primed by flint and steel or a fire charge, and its explosions; falling sand, gravel, concrete powder and anvils | Most redstone components, pistons, fire from explosions, brushable blocks and functional blocks beyond those |
| Players | Movement validated by the native physics kernel (fluids, climbing, swimming, slowing blocks, edges, poses), health, food, air, freezing, burning, fall and contact damage, status effects and attributes, death and respawn, game modes and abilities, experience | Combat, remaining effects and attributes, live mode transitions |
| Inventory | Authoritative clicks, swaps and drops, 2×2 and 3×3 crafting, chest and furnace menus, cooking with recipe unlocks, item components the data format reads | Recipe book and autofill, special and component crafting outputs, remaining containers |
| Entities | Items and experience orbs as owned entities: motion, merging, pickup, portals, handoffs between owners and replication | Mobs, AI, spawning, projectiles, vehicles |
| Commands | Vanilla's command tree; world, player, admin and generation commands (`/fill`, `/clone`, `/place`, `/locate`, `/give`, `/effect`, `/tp`, `/worldborder`, ...) with selectors over players | `/execute`, scoreboards, teams, functions, selectors over other entities |
| Extensions | Original Elixir runtime | Extension API, Java plugins and Bedrock compatibility |

New worlds are flat unless `generator` selects vanilla terrain; a world keeps
the generator it was created with. World and player storage is ValiMC's own
log and checkpoint format (vanilla worlds import and export through Anvil): a
crash loses at most the last frames. See [architecture](architecture.md) and
[configuration](configuration.md).
