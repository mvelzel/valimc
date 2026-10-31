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

## M3 — Survival core (complete)

VMC-015i, 026d, 029d–e, 031a–b, 032b, 034n4, 037n–o, 039a–c, 040a, 041a–b, 042a–b, 043a–e,
044a, 045a and 047a–049a give a survivable world: mobs, combat, spawning, fluids, farming,
redstone and the dragon fight. VMC-081 moved simulation into Rust. The gate is in
[VMC-078](tickets/VMC-078.md#closure-october-31-2026), its findings in [VMC-083](tickets/VMC-083.md).

## M4 — Survival progression (in progress)

Gate: [VMC-084](tickets/VMC-084.md), a fresh-world run that enchants, upgrades
to netherite, brews, trades and wins a raid. Slices: the
[backlog](backlog.md#m4--survival-progression). A lane owns its code, so one
session per lane runs at once; a lane's slices run in order.

| Lane | Owns | Slices |
|---|---|---|
| Rules and commands | Game rules, command gaps | 085 → 006a |
| Effects and brewing | Status effects, potions, the brewing stand | [037p](tickets/VMC-037p.md) (client) → [034o](tickets/VMC-034o.md) (client) |
| Enchanting | Enchantment effects, the table, anvils, smithing | 037q (rest: Frost Walker, spears, the mace's knockback) · 038a–c (client) |
| Containers | Item components, remaining containers | 004b, 032c1–3, 032c5 (client); stopped: 032c4, 032c6, 004b9 next |
| Villages | Trades, villager life, illagers, raids | 044b, 044c (awaiting client) → 044d1–6 → 044e |
| Finale | The gate | 084 |

Current order:

1. [085](tickets/VMC-085.md): M3's leftovers are cleared; two client checks wait for M4's first run.
2. The lanes, in parallel, starting with 037p, 037q, 004b and 044b. A lane's
   first slice refines its tickets from the backlog row.
3. Later: SIMD where data-parallel work dominates ([082](tickets/VMC-082.md)) and the performance items left in [081](tickets/VMC-081.md#closure).

Done: none yet.

Later: vehicles and riding, taming and the remaining mob families, the wither and warden, maps and
books, advancements, commands/admin, certification.

## Paused

None.

## Pending client gates

[085](tickets/VMC-085.md): dolphin treasure guidance and the cat's cod, in M4's first client run.
[044b](tickets/VMC-044b.md): trading with a librarian and a wandering trader, and a restock.
[037q](tickets/VMC-037q.md), [038a–c](tickets/VMC-038a.md): enchantments in play, the table, anvils, grindstones, smithing.
[004b](tickets/VMC-004b.md): components on creative items, a burning shulker box and bundle spilling.
[032c1–3](tickets/VMC-032c.md): barrels, shulker boxes carried with their contents, ender chests shared across two places.
[032c5](tickets/VMC-032c5.md): breaking a furnace mid-smelt for its items and experience, and a renamed chest's title.
[037p](tickets/VMC-037p.md), [034o](tickets/VMC-034o.md): status effects in play (Health Boost, Glowing, Invisibility, Infested), and brewing, lingering clouds, tipped arrows and cauldrons.

## Retrieve and update

```sh
rg -n 'VMC-062' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-062.md
```

Keep this file to open work: one row per open ticket, its remaining slice in a short
line. When a ticket is Done, drop its row, add it to the Done line and to
`history/completed.md`. `scripts/lint_docs.py` caps this file at 90 lines.
