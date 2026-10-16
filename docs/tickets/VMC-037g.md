# VMC-037g — Instant Health and Instant Damage

Status: Owned drinking implemented locally at `f4670e6`; targeted/native,
production/both TCP transports and focused stock/mixed/fatal client checks pass.
Named-mainhand text [VMC-004b3](VMC-004b3.md) and whole negative-dose refusal
at662dc7f also pass their client/production/TCP gates. The abnormal native lifecycle
is a separate [follow-up](VMC-037g1.md). Parent8a28534 full native integration
remains running before publication. This ticket is not Done.

Acceptance: actual healing/harming drinks apply once at completion, with native
amounts/self source and supported defenses, without a persistent instant icon.
Health, containers, mixed effects and fatal consumption/death recovery share the
existing owner/checkpoint lane. Cancellation, creative and reconnect preserve
accepted state. Client checks include both hands, defenses, mixed ordering,
fatal drinks, translated item text/hover, Respawn and fresh reconnect.

Pinned26.3: `PotionContents.applyToLivingEntity/onConsume`,
`HealOrHarmMobEffect.applyInstantaneousEffect`, `LivingEntity.heal/setHealth`,
`DamageSource.getLocalizedDeathMessage`, item display/data codecs and existing
health/defense/consumption references. Jar SHA1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. Original probes are public;
bytecode/fixtures remain ignored under `.local/instant-*` and `.local/item-hover-*`.

## Native foundations

- `cc3dfa5`:10,240 actual drink requests, both effects/all256 amplifiers/five
  durations/four duration scales. Signed32 shifts/wrap and double-to-int-to-float
  amounts match. Duration scaling does not change instant strength. Harm uses
  self-attributed indirect_magic; its direct and causing entities are the player.
  Probe float observations use promoted doubles to retain actual float bits.
- `bc518fe`:32 native self-magic event contexts and24 plain-hand death/chat
  components;80 independently encoded packets native-decode correctly. Names
  occur twice; a custom mainhand name selects the item template, item-name alone
  does not. Named-item details and proofs are in VMC-004b3.
- `303f233`:195 actual native heal/setHealth transitions using the real health
  accessor and controlled maximum. Signed/zero/subnormal/huge requests clamp;
  dead health does not revive. This proves raw health, not abnormal death handling.
- `f4670e6`:33,280 native self-magic defenses, including0/6/12 damage, all43
  enchantments, wrong-slot/stored negatives, caps and ResistanceII. Finite results,
  no armor wear/exhaustion and bounded overflow follow the existing defense lane.

Raw: `.local/instant-drinks-{native-final,native-check-final,targeted-final}.log`,
`.local/self-magic-{native-final,check,decode,targeted}.log`,
`.local/healing-{native-final,native-check-final,targeted-final}.log`,
`.local/instant-{damage-protection,resisted-damage}-{native,check}-final.log`.

## Owned composition and verification

`PlayerConsumption` plans inventory/container, nutrition, timed effects and instant
callbacks in delivery order without I/O. `PlayerDamage` shares owned immunity,
armor, Resistance and Protection. One final snapshot queues before publication;
fatal consumption waits for its acknowledgement before the death/drop journal.
No extra owner/timer/replay callback or second effect authority. Original mainhand
is retained before container replacement. Instant effects never enter timed maps.

113 affected checks pass(seed230653): cancel/full/creative/offhand drinks, source
IDs, ordered defenses/hurt windows and a stalled fatal drink followed by healing.
The zero-health+bottle snapshot precedes exactly one durable drop; reconnect
retains source1/drop without revival or reapplication. Earlier damage refactor
passes103 regressions. Raw `.local/instant-consumption-targeted-order.log` and
`.local/damage-resolution-targeted.log`. Frozen `f4670e6` production/both native
TCP transports pass: `.local/instant-consumption-live-{production,native-tcp}.log`.

October16 actual26.3/protocol777 PASS within focused stock scope; primary reviewed
`.local/client-tests/VMC-037g/report.md` once. Actual harm/heal20→14→18,
offhand strong harm18→6, strong heal6→14→20 clamp; cancellation/full-food,
creative harm and unsupported InstantHealth+NightVision16 refusal pass.
Four ProtectionIV pieces+ResistanceI reduce6→1.728 damage without wear; FR alone
does not help. Actual Resistance-before-harm deals4.8, reversed order deals6;
milk removes the timed head. Fresh Quick Play retains health/bottle/timed status,
without instant replay. One isolated stock fatal drink shows the self-magic death
message, actual Respawn and one durable bottle. A later healing callback after
fatal harm does not revive. Defense acquisition and item provisioning use fixtures;
actual use, health changes and Respawn are GUI actions, with no repeated healing
fixtures masking damage. No precise tick timing or abnormal-dose claim.

Both wrappers/JVMs stopped; zero connections, seven regions+clock flush:ok,
server49581 exit0 without gameplay errors.967 frozen blobs remain unchanged.
Whole dataset `/tmp/valimc-instant-consumption-live-client-20261016` retains20HP,
empty inventory/effects, source55/outboxnil, region0,0receipt55 and1,1receipt54,
each with its one bottle. Earlier receipt histories stay intact. Cleanup/proof:
`.local/instant-consumption-live-cleanup.log`, `.local/instant-consumption-publication-proof.json`.

Larger-block `cc3dfa5` passes1,330 full tests/production/full native integration,
including plaintext/AES-CFB8 TCP, session69595 exit0. That release includes movement
effects and instant request math, before later self-magic/healing/live composition.
Raw `.local/effects-integration-{full-tests,production,full-native}.log`.

Pending: final native integration/publication only for this ordinary-drink scope.
Named-item/refusal client gates pass. The later admission
guard refuses negative signed-healing potions atomically, with53 affected checks
and768 native health/callback observations. Its abnormal zero-health lifecycle is
tracked in VMC-037g1; no custom-dose parity claim. The frozen8a28534 parent passes
1,341 full tests, production and both TCP transports; its full native integration
is still running. That immutable release predates the new negative-dose guard.
