# Current work

Target: full vanilla Java 26.3 player experience (protocol 777), Elixir 1.20.4 / OTP 29.1.1.
Compatibility policy update: **Done**, `4c449d9` (October 15). [AGENTS.md](../AGENTS.md)
preserves vanilla gameplay/client interoperability and permits BEAM-native internals.
This queue is editable. [Compatibility](compatibility.md) describes the preview;
[backlog](backlog.md) covers remaining features; [completed](history/completed.md)
indexes validated tickets. None imply full parity.

## Priority

**Done:** [status foundations](tickets/VMC-037a.md),
[owned Fire Resistance](tickets/VMC-037a1.md) and
[supported potion drinking](tickets/VMC-037b.md), accepted at `fa0b320`. Native
state/codec proofs,1,276 full tests/build, later53 affected checks/native TCP/build
and actual contacts, drinks, expiry, negatives, creative, death/respawn and reconnect
pass. The ground-target drinking failure was fixed and retested. Six matched128/512
water samples pass; retain dense login variance and older admission findings.
[Water Breathing/air ordering](tickets/VMC-037c.md) is **Done within scope** and
published at `1fd6287`:433 native contexts,60 affected checks,1,284 full tests/build,
both native TCP transports and all six actual-client groups. Retrieve its ticket
for fixture limits and the consistent source/receipt51 dataset.
**Done within scope:** [periodic health effects](tickets/VMC-037d.md) at `5b123b1`
and [milk/honey effect removal](tickets/VMC-036d.md) at `d71b2a9`, published through
`d71b2a9`. Periodic effects pass1,302 full tests/native integration/build and actual
drinks/timing/defenses/death/promotion/reconnect. Milk/honey add658 native cases,
87 affected checks, production/both TCP transports and actual removal/containers/
negatives/reconnect. Retrieve tickets for scope and source/receipt53 evidence.
**Done within scope:** [Resistance](tickets/VMC-037e.md) at `d9e1b8a`:135,150 native
contexts,116,320 composed cases,106 affected checks,1,321 full tests/production,
both native TCP transports and actual falls/contact/gear/drinks/promotion/expiry/
milk/starvation exclusion/reconnect. Whole source/receipt53 retained.
**Implementing:** [Speed/Slowness](tickets/VMC-037f.md),132,098 native attribute
contexts and seven foundation checks pass. Live attributes/drinks/Turtle Master
now pass63 affected checks; native TCP/production and its own client gate follow.

[Live lava/burning](tickets/VMC-017b4a.md), [natural fire contacts](tickets/VMC-017b4b.md),
[flat-plains rain extinction](tickets/VMC-017b4c.md) and
[player contact hazards](tickets/VMC-017b5.md) are **Done within their stated scopes**.
Latest runtime `9fce29f`:1,253 full tests/production, native full integration at `8fbe510`
plus targeted translation/status proofs, actual hazard/gear/death/respawn/reconnect
checks. Matched128/512 water samples retain the existing worker-admission/host-load
finding; no stable512 capacity or speed claim. Retrieve detailed evidence in tickets.

[Automatic item simulation](tickets/VMC-035a6.md),
[same-owner merging](tickets/VMC-035b.md), [ordinary pickup](tickets/VMC-035c.md),
[cross-owner merging](tickets/VMC-035b1.md) and
[void disposal](tickets/VMC-035d1.md) are **Done within their stated scopes**.
The latest block passes1,178 full tests plus targeted void checks, native integration/
both TCP transports, production and actual-client boundary/fairness/recovery/void/
reconnect scenarios. Final feature runtime `f27b413`; evidence stays in tickets.
[Advanced pickup contexts](tickets/VMC-035c1.md) and
[near-camera presentation](tickets/VMC-018c3.md) remain open. Retrieve earlier
validated slices through the [completed index](history/completed.md).

1. **[VMC-011a](tickets/VMC-011a.md): authoritative ownership/tick ordering.**
   Player processes own their simulation state; bounded workers sample geometry.
   Coupled effects need explicit ordering. Owner/timer, client-tick admission and
   block batches are validated, as are [resource separation](tickets/VMC-011a4.md),
   [cold-load isolation](tickets/VMC-011a5.md), [writer leases](tickets/VMC-011a6.md),
   [cold admission/ETS routing](tickets/VMC-011a7.md) and
   [live player poses](tickets/VMC-014c3b2b2.md).
   [Live block-based movement](tickets/VMC-014c4.md) is validated and complete
   within its scope (`d10f566`); gravity/coupled effects remain.
2. **VMC-015: gravity, velocity and grounded state.**
   [Accepted-move fall accounting](tickets/VMC-015a.md) is validated (`84f5fb0`),
   including real jump/drop/powder-snow, flight and reconnect.
   [Gravity/drag](tickets/VMC-015b.md)'s pure air/collision kernels and complete
   block motion facts match native cases/traces (`1da26e93`, baseline client smoke
   passed). [Live default velocity](tickets/VMC-015b1.md) now composes them on the
   bounded player tick/geometry lane; validated and complete within its scope
   (`6691f43`), including frozen loads and actual-client regression after
   eliminating duplicate pose observations.
   [Saved velocity](tickets/VMC-015b2.md) is validated and complete within its
   scope (`18aad55`): direct airborne/ground reconnect, landing, jump and flight.
   [Fluid travel](tickets/VMC-015d.md) is in progress: complete material facts/body
   depths validated (`01c4627`); local native water/lava kernels (`0ae6ef3`).
   Current, contextual support and vertical input match native cases. [Default
   live composition](tickets/VMC-015d1.md) is validated (`2e66935`): actual water/
   lava/current/input/flight/reconnect, 578 tests, full native integration,
   production release and frozen preview loads. [Swimming state/geometry](tickets/VMC-015d2.md)
   and [pitch steering](tickets/VMC-015d3.md) are validated (`3c99728`): actual
   tunnel/crawl/peer/pitch/flight/reconnect, 587 tests, full native integration,
   production release and active-water 512/128-player loads.
   [Climbing](tickets/VMC-015e.md) is validated (`f83e8e7`): actual ladder/vine/
   scaffolding/trapdoor/wet/flight/reconnect, 600 tests, full native integration,
   production build and controlled 512/128-player water loads.
   [Relative input](tickets/VMC-015f.md) now has native direction/acceleration/rate
   kernels; native reported intent preserves simulated controls. Entity/vehicle
   ownership remains open. [Slowing contacts](tickets/VMC-015g.md) are validated
   and published (`bc4eb1e`):
   actual client, 622 tests, full native integration/build and controlled 512/128
   water loads. Weaving status ownership and damage remain follow-ups.
   [Sneaking at edges](tickets/VMC-015h.md) is validated and published (`6ca22ef`):
   native query/frame traces, affected tests and actual ledges/corners/slabs/exclusions.
   Effects/survival consequences remain open.
   [Owned health/fall damage](tickets/VMC-017a.md) has native calculation, health/
   cooldown, codec and journal foundations. Owner/login/timer composition is
   validated (`18028cd`): 75 affected tests and actual hearts/inventory/reconnect.
   [Death/respawn](tickets/VMC-017a1.md) is validated and complete within scope
   (`0b2ad043`): actual death/drops/respawn/dead reconnect, 687 full tests and build.
   [Automatic landing damage](tickets/VMC-017a2.md) passes 93 affected tests,
   71,530 native material cases and native support/codecs. Actual client checks
   exposed a premature bed-bounce impulse; the69-test/native-verified fix passes
   actual bed/slime, ordinary fall, explicit impulse and saved-velocity retests
   (`7337af64`). Accepted-landing scope is validated and complete.
   [Fall enchantment defenses](tickets/VMC-017a3.md) pass 41 affected tests and
   20,800 native cases; actual geared falls, negatives and reconnect passed (`0b2ad043`).
   [Freezing damage](tickets/VMC-017b1.md) passes 75 affected tests and native
   eligibility/protection/codecs; actual exposure, defenses, reconnect and fatal
   respawn are validated and complete within scope (`0b2ad043`).
   [Air supply/drowning](tickets/VMC-017b2.md) passes 94 affected tests and native
   air/equipment/protection/codecs, 700 full tests, full native TCP/build and matched
   preview loads; actual exposure/recovery, defenses, damaged reconnect and fatal
   respawn are validated and complete within owned-air scope (`7337af64`).
   [Void damage](tickets/VMC-017b3.md) passes 67 affected tests and native
   boundary/mode/loading/defense/codecs; actual falls, mode/defense bypass,
   reconnect and fatal respawn are validated within scope (`7337af64`).
   [Hunger/regeneration](tickets/VMC-036a.md) passes131 affected tests and native
   food/peaceful/defense/codecs. Owned clock, journal, rules and HUD are implemented;
   full native integration, 740 full tests and production builds pass. Actual
   hunger/healing, difficulty floors, peaceful recovery, reconnect and fatal
   starvation/respawn are validated within owned-clock scope (`7337af64`).
   [Movement exhaustion](tickets/VMC-036b.md) passes 91 affected tests and native
   travel/mode/jump probes; accepted sprint/swim/jump food costs are implemented,
   with actual sprint/swim/jump costs, walking/crouching/mode negatives and
   depleted reconnect validated (`7337af64`). Sprint eligibility/other action costs remain.
   [Consuming items](tickets/VMC-036c.md) has native facts/food codecs, 18,474
   identity cases and49 affected tests. Live plain-food use now passes38 affected
   tests: owner-clock timing, both hands, interruption, remainders and atomic
   food/inventory saves. Actual both-hand animations, cancellation/reconnect,
   nutrition, soup remainders and creative behavior are validated (`7337af64`).
   Specialized effects/overflow remain separate work.
   [Player equipment](tickets/VMC-018d.md) passes128 native packet cases and39
   affected tests; actual hands/armor, changes/clears, use presentation and tracking
   recreation are validated within six-slot replication scope (`7337af64`).
   [Idle food clock work](tickets/VMC-036a1.md) addresses the measured 512-player
   memory increase; native/83 affected checks pass, but repeated loads show no
   whole-workload memory improvement. Allocation profiling remains open; continue
   consumable facts/use independently.
   [Environment ticks](tickets/VMC-015c.md) share the
   geometry lane and fix the stale powder freezing state; validated and complete
   within freezing scope (`91caf387`), including actual thaw/reconnect and flight.
   [Geometry admission](tickets/VMC-011a8.md) is complete within measured preview
   scope (`8871985`); prepared samples retain owner fencing and bounded work.

3. **[VMC-029a](tickets/VMC-029a.md): survival mining.** Native hardness/progress
   matches1,286,028 rates and1,386 actual tick/crack prefixes. Stock tools match
   1,143,136 native state pairs; gear and eye/ground player speed also match native
   contexts. [Stock durability](tickets/VMC-029a2.md) matches39,704 actual callbacks,
   including Unbreaking and final-use breaks. [Atomic block/drop persistence](tickets/VMC-029a1.md) has bounded
   proposal/source-intent codecs, writer recovery, fenced region commits and
   receipt-backed source wear/refunds, with101 affected checks passing.
   [Fluid-preserving removal](tickets/VMC-029a3.md) is validated (`a696a61`): full
   native state comparisons,47 affected checks and actual wet/dry creative removal/reconnect.
   [Deterministic loot](tickets/VMC-029a4.md) matches210,847 native contexts across
   930 block families. [Attempt progress/animation](tickets/VMC-029a5.md) matches490
   native action traces and165 codecs. Renewable original-block fences pass19
   affected checks. [Basic live mining](tickets/VMC-029a6.md) now composes the
   player clock, fresh contact, loot/wear and durable region/source receipts;
   broader loot and destruction callbacks remain.
   All six basic block kinds, cracks/abort, loot/wear and fresh reconnect passed
   actual-client checks (`c163209`);822 full tests/build and full native integration
   pass, including plaintext and continuous AES-CFB8 TCP. This basic slice is complete.
   [Stateful loot/slabs](tickets/VMC-029a7.md) is validated (`4899168`): native
   constant counts,101 slab families,231,455 native cases,21 affected checks and
   actual single/double wet/dry slabs, wear and fresh reconnect.
   [Ordinary full cubes](tickets/VMC-029a8.md) are validated (`e28fbb8`):173 added
   types,65 affected tests,231,455 native loot contexts, production and actual
   tool/loot/wear/abort/fresh-reconnect checks. Broader callbacks remain open.
   [Random cube loot](tickets/VMC-029a9.md) is validated (`84a6fca`):53 affected
   tests,380,160 native contexts, production and actual random/Silk/Fortune drops,
   wear and fresh reconnect. Broader ore/XP/context loot remains open.
4. **[VMC-029b](tickets/VMC-029b.md): authoritative placement.** Native candidates/
   codecs match518,964 contexts and576 packets. Bounded preparation and expiring
   owner commits now compose on the player with admission, ordered corrections
   and one bounded worker.70 affected checks, both native TCP transports, production
   and actual creative targeting/slab/water/both-hand/reconnect checks pass
   (`96da2b8`). This core is complete. [Durable survival consumption](tickets/VMC-029b1.md)
   is validated and complete within owned one-block/both-hand scope (`af99f492`):
   exact consumption/refunds, v14 source journals and typed destination receipts,
   874 full tests, full native integration/both TCP transports, production and
   actual depletion/wet/dry/top/both-hand/fresh reconnect. Broader callbacks and
   ownership remain open. [Ordinary full cubes](tickets/VMC-029b2.md) now admit178
   more items and are validated (`5fd058a`):53 affected checks,1,319,700 native
   contexts,2,840 consumption cases, production and actual both-mode family,
   offhand/depletion/refusal/fresh-reconnect checks. Broader placement remains open.
   [Logs/pillars](tickets/VMC-029b3.md) are validated (`4d60aa4`):60 families/180
   mining states,84 affected checks,1,590,780 native placements,3,440 consumption
   cases,889 full tests, full native TCP/build and actual axes/mining/reconnect.

5. **[VMC-033a](tickets/VMC-033a.md): player crafting foundation.**476 indexed
   2×2 recipes pass149,128 native selection/result contexts and five targeted
   checks. Production and actual baseline smoke passed (`6cd6800`); this
   foundation is complete. Live grid/result composition follows.
   Broader crafting and recipe-book synchronization remain open.
   [Manual grid crafting](tickets/VMC-033b.md) passes113 affected checks and3,536
   actual native menu contexts: derived output, atomic ingredient consumption
   and cursor/cleanup boundaries. Production and actual recipes/refusals/cleanup/
   reconnect passed (`adfb228`); the manual slice is complete.
   [Result gestures](tickets/VMC-033c.md) pass86 affected checks and3,642 native
   contexts; production and actual shift/number/offhand/refusal/reconnect passed
   (`b3060b6`). The drop-free slice is complete;112 overflow plans remain refused
   at that checkpoint. [Durable crafting drops](tickets/VMC-033d.md) pass140
   affected checks and9,466 native contexts, including exact recipe conversion,
   source/destination recovery and real TCP. Actual overflow/Q/refusal/reconnect,
   914 full tests, full native TCP/production passed (`88416e9`); this slice is complete.
   [Table recipes](tickets/VMC-033e.md) pass438,672 native contexts and100 affected
   tests, retaining all476 player recipes; production and actual player crafting/
   cleanup/reconnect passed (`7779eaf`). This foundation is complete.
   The [owned3×3 table menu](tickets/VMC-033f.md) follows. Bulk result dropping
   remains separate.
   Its [owned input/cleanup foundation](tickets/VMC-033f1.md) passes affected/native
   checks and restart/TCP recovery; actual connected/disconnected cleanup and fresh
   reconnect passed (`7d1a97f`). This foundation is complete; table clicks follow.
   [Table click plans](tickets/VMC-033f2.md) pass134 affected checks,11,990 native
   traces and2,398 native packet decodes; actual player crafting/reconnect,
   933 full tests, full native TCP and production passed (`6ec31a9`/`c8a8a13`).
   This kernel foundation is complete; live menu composition follows.
   [Table blocks](tickets/VMC-033f3.md) pass49 affected tests and native placement,
   consumption/mining checks, production and actual both-mode/both-hand placement,
   mining/wear/drop/refusal/reconnect (`738852b`). This block slice is complete.
   [Live menus](tickets/VMC-033f4.md) are validated (`8fe1adf`):947 full tests,
   full native TCP/production and actual recipes, refusals, removal/relocation,
   disconnect and two-batch overflow/reconnect. The ordinary table slice is complete.

VMC-061's concise docs/retrieval workflow is complete, ahead of further features.
[VMC-003c](tickets/VMC-003c.md)'s direct local test-client lifecycle is complete:
automatic join, small window, readable Auto UI, muted launch and owned shutdown.

## Pending client queue

One dedicated tester owns CUA. Code checkpoints can progress independently.

| Ticket | Remaining gate | Checkpoint / release |
|---|---|---|
| [VMC-005b2a](tickets/VMC-005b2a.md) | Sustained multi-slot client drag | Published with gate pending |
| [VMC-005b2c](tickets/VMC-005b2c.md) | Client-generated clone/fill | Published with gate pending |

The admission/routing block (`66a4b81`) passes 481 tests, production build and full
native integration, including plaintext/encrypted TCP. Live pose selection
(`b65e6ec`) passes 113 affected tests, native codecs/TCP and actual-client checks;
live movement (`d10f566`) passes its client gate, 109 affected tests and both native
TCP transports. The larger block passes 505 tests, full native integration and a
production build. The admission block passes 508 tests, native integration and a
production build; frozen 512-player and 128-player layouts pass, with client
movement/flight/reconnect retested. See VMC-011a8 for workload and host-load limits.
Retain [VMC-018c2](tickets/VMC-018c2.md)'s unreproduced item visibility finding and
[VMC-018c3](tickets/VMC-018c3.md)'s near-camera dropped-item planes for the next item work.
The fall/environment block passes 527 tests, full native integration and a separate
production build; VMC-015c records client evidence and frozen preview loads.

## Retrieve and update

```sh
rg -n 'VMC-014c3b2b1' docs/roadmap.md docs/backlog.md docs/history/completed.md
cat docs/tickets/VMC-014c3b2b1.md
```

Read the ticket's referenced code/probes next. After a checkpoint, update its
checks/next gate and this queue. On Done, remove the pending row and add a link to
`history/completed.md`; keep detailed evidence in the ticket. Change priorities
when it helps compatibility. See [development](development.md) for Git/test rules.
