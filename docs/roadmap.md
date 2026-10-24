# Current work

Target: full vanilla Java 26.3 player experience (protocol 777) on Elixir 1.20.4 /
OTP 29.1.1, with Rust NIFs where native code measurably wins. This queue is
editable. [Compatibility](compatibility.md) describes the preview; the
[backlog](backlog.md) lists remaining features; [completed](history/completed.md)
indexes finished tickets. Evidence lives in tickets, not here.

## M1 — Foundations (complete)

VMC-062..069 replaced the preview's flat-world edit map, fsync-bound region writes, per-feature
transfers, mailbox block reads and monolithic connection with sections, group commit, one
transaction engine, snapshots, a game-time tick pipeline, the entity model and a generated registry;
see [architecture](architecture.md).

## M2 — Real worlds (complete)

VMC-010, 020..025, 026, 027, 028, 029c, 053 and 070..075 generate vanilla's overworld, Nether and
End live (terrain, features, structures, loot) with portals, world settings and the world-generation
commands; the gate is in [VMC-025](tickets/VMC-025.md#m2-milestone-gate-october-21-2026). Commands
on M3 systems (VMC-053h, k–n) move with those systems. Generation and tick time stay matched against
vanilla and Pumpkin, at least in Pumpkin's range.

## Foundations II (complete)

VMC-077 audited the code after M2 and rebuilt its foundations: everything that interacts shares one
owner (groups of 8 × 8 sections that merge and split, with players, entities and blocks inside), one
atomic frame per owner per tick in one striped log, one entity store, one block fact table, Rust
kernels for physics, block rules, light and generation scheduling, and a layered module layout. The
final client run and its rechecks passed; see [VMC-077](tickets/VMC-077.md).

## M3 — Survival core (in progress)

Gate: [VMC-078](tickets/VMC-078.md), a fresh-world survival run to the dragon's
death. Slices: the [backlog](backlog.md#m3--survival-core). A lane owns its
code, so one session per lane runs at once; a lane's slices run in order.

| Lane | Owns | Slices |
|---|---|---|
| Entities (critical path) | Entity store, physics kernel, a new AI context | 043a → 015i → 041a → 041b |
| Combat | Living damage, a projectile kernel, orb motion | 037n → 037o → 034n4c → 026d |
| World effects | Explosions, primed TNT, falling blocks | 050a → 040a |
| Spawning | Spawn rules and caps, structure entities, spawners | 042a → 042b |
| Blocks | Block rules, placement, mining | 029e → 039a → 039b → 039c → 032b |
| Fluids | A fluid module, fluid ticks | 031a → 031b |
| Redstone | Power, components, pistons, item machines | 047a → 048a → 048b → 049a |
| Mob families | One module set per family | 043b ∥ 043c ∥ 043d ∥ 043e ∥ 044a |
| Finale | The End fight, then the gate | 045a → 078 |

Current order:

1. Finish the pending client gates in one batched run; resolve integration failures.
2. Validate double chests (032b) with the next finale client batch.
3. Finale: connect the dragon actor's arena lifecycle (045a), then run the M3 gate (078).

Done: [039c](tickets/VMC-039c.md), [049a](tickets/VMC-049a.md).

Later: enchanting, brewing, trading, raids, vehicles, commands/admin, certification.

## Paused

A furnace holding items stays until its spill and stored experience exist ([VMC-034f](tickets/VMC-034f.md)).

## Pending client gates

| Ticket | Remaining gate |
|---|---|
| [VMC-032b](tickets/VMC-032b.md) | Join, use and split a large chest across a section line; contents survive reconnect; hoppers and comparators read both halves |
| [VMC-037o1](tickets/VMC-037o1.md) | Shoot a dragon part across a section line |
| [VMC-045a1](tickets/VMC-045a1.md) | Place and strike a crystal; shoot a spike crystal; both explode |
| [VMC-039b](tickets/VMC-039b.md) | Bone meal on grass and flowers; grass spreads; berries picked; kelp and cocoa grow |
| [VMC-043e1](tickets/VMC-043e1.md), [043e2](tickets/VMC-043e2.md), [043e3](tickets/VMC-043e3.md), [043e4](tickets/VMC-043e4.md), [043e5](tickets/VMC-043e5.md), [043e6](tickets/VMC-043e6.md), [043e7](tickets/VMC-043e7.md) | A shulker opens and shoots bullets that float the player, shrugs off arrows closed, teleports when hurt; an endermite bites; cod school and flee, a pufferfish stings, a squid inks; a guardian beams and pricks, an elder brings Mining Fatigue; a bat hangs and wakes; a dolphin leaps, bites and graces a swimmer; turtles lay eggs that hatch; an axolotl hunts and plays dead |
| [VMC-043b](tickets/VMC-043b.md) ([043b1](tickets/VMC-043b1.md)–[043b6](tickets/VMC-043b6.md)) | Drowned swim, throw tridents and come ashore; zombies stamp out turtle eggs; witches throw and drink potions, slimes split, silverfish swarm, phantoms swoop; endermen anger at a stare (not through a pumpkin) and teleport; creepers explode (and when lit), spiders leap and climb, cave spiders poison; skeletons circle and shoot, strays slow, bogged poison, a skeleton and a player shoot each other; zombies burn by day (not with a helmet), babies run, husks make the player hungry, a zombie takes a sword, a drowned husk becomes a zombie |
| [VMC-043d](tickets/VMC-043d.md) | A fortress run: blazes volley and drop rods; zombified piglins turn as a group; a piglin barters gold and attacks without gold; a ghast's fireball hit back kills it; hoglins charge and shun warped fungus; magma cubes hop and split; striders walk on lava |
| [VMC-048b](tickets/VMC-048b.md) | A sticky piston door from a button; a player rides a block pushed up and honey pushed sideways |
| [VMC-043c](tickets/VMC-043c.md) | Sheep regrow wool, chickens lay eggs and rabbits hop |
| [VMC-044a1](tickets/VMC-044a1.md), [a2](tickets/VMC-044a2.md), [a3](tickets/VMC-044a3.md), [a4](tickets/VMC-044a4.md) | Villagers take job sites' trades, meet at the bell, sleep in beds and flee zombies; a golem kills a zombie hunting one; cats shy from players, creep up to fish, pounce on rabbits; a trader drinks invisibility at dusk |

## Retrieve and update

```sh
rg -n 'VMC-062' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-062.md
```

Keep this file to open work: one row per open ticket, its remaining slice in a short
line. When a ticket is Done, drop its row, add it to the Done line and to
`history/completed.md`. `scripts/lint_docs.py` caps this file at 90 lines.
