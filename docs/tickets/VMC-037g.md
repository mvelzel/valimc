# VMC-037g — Instant Health and Instant Damage

Status: Done
Note: **Done within ordinary-drink scope**, validated through `662dc7f`. Targeted/native,1,341 parent full tests, production/full native TCP integration and actual stock/mixed/fatal/named drinks and reconnect pass. Abnormal signed-healing lifecycle remains a separate [follow-up](VMC-037g1.md), deliberately refused whole.

Acceptance: actual healing/harming drinks apply once at completion, with native
amounts/self source and supported defenses, without a persistent instant icon.
Health, containers, mixed effects and fatal consumption/death recovery share the
existing owner/checkpoint lane. Cancellation, creative and reconnect preserve
accepted state. Client checks include both hands, defenses, mixed ordering,
fatal drinks, translated item text/hover, Respawn and fresh reconnect.

Pinned 26.3: `PotionContents.applyToLivingEntity/onConsume`,
`HealOrHarmMobEffect.applyInstantaneousEffect`, `LivingEntity.heal/setHealth`,
`DamageSource.getLocalizedDeathMessage`, item display/data codecs and existing
health/defense/consumption references. Jar SHA1
`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`. Original probes are public;
bytecode/fixtures remain ignored under `.local/instant-*` and `.local/item-hover-*`.

## Native foundations

- `cc3dfa5`:10,240 actual drink requests, both effects/all256 amplifiers/five
  durations/four duration scales. Signed 32 shifts/wrap and double-to-int-to-float
  amounts match. Duration scaling does not change instant strength. Harm uses
  self-attributed indirect_magic; its direct and causing entities are the player.
  Probe float observations use promoted doubles to retain actual float bits.
- `bc518fe`:32 native self-magic event contexts and 24 plain-hand death/chat
  components;80 independently encoded packets native-decode correctly. Names
  occur twice; a custom mainhand name selects the item template, item-name alone
  does not. Named-item details and proofs are in VMC-004b3.
- `303f233`:195 actual native heal/setHealth transitions using the real health
  accessor and controlled maximum. Signed/zero/subnormal/huge requests clamp;
  dead health does not revive. This proves raw health, not abnormal death handling.
- `f4670e6`:33,280 native self-magic defenses, including 0/6/12 damage, all 43
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
retains source 1/drop without revival or reapplication. Earlier damage refactor
passes 103 regressions. Raw `.local/instant-consumption-targeted-order.log` and
`.local/damage-resolution-targeted.log`. Frozen `f4670e6` production/both native
TCP transports pass: `.local/instant-consumption-live-{production,native-tcp}.log`.

October 16 actual 26.3/protocol777 PASS within focused stock scope; primary reviewed
`.local/client-tests/VMC-037g/report.md` once. Actual harm/heal20→14→18,
offhand strong harm 18→6, strong heal 6→14→20 clamp; cancellation/full-food,
creative harm and InstantHealth+then-unsupported effect 16 refusal pass. The old
handoff mislabeled 16 Night Vision; the native catalog identifies it as Hunger.
Four ProtectionIV pieces+ResistanceI reduce 6→1.728 damage without wear; FR alone
does not help. Actual Resistance-before-harm deals 4.8, reversed order deals 6;
milk removes the timed head. Fresh Quick Play retains health/bottle/timed status,
without instant replay. One isolated stock fatal drink shows the self-magic death
message, actual Respawn and one durable bottle. A later healing callback after
fatal harm does not revive. Defense acquisition and item provisioning use fixtures;
actual use, health changes and Respawn are GUI actions, with no repeated healing
fixtures masking damage. No precise tick timing or abnormal-dose claim.

Both wrappers/JVMs stopped; zero connections, seven regions+clock flush:ok,
server 49581 exit 0 without gameplay errors.967 frozen blobs remain unchanged.
Whole dataset `/tmp/valimc-instant-consumption-live-client-20261016` retains20HP,
empty inventory/effects, source 55/outboxnil, region 0,0receipt55 and 1,1receipt54,
each with its one bottle. Earlier receipt histories stay intact. Cleanup/proof:
`.local/instant-consumption-live-cleanup.log`, `.local/instant-consumption-publication-proof.json`.

Larger-block `cc3dfa5` passes 1,330 full tests/production/full native integration,
including plaintext/AES-CFB8 TCP, session 69595 exit 0. That release includes movement
effects and instant request math, before later self-magic/healing/live composition.
Raw `.local/effects-integration-{full-tests,production,full-native}.log`.

Named-item/refusal client gates pass. The later admission
guard refuses negative signed-healing potions atomically, with 53 affected checks
and 768 native health/callback observations. Its abnormal zero-health lifecycle is
tracked in VMC-037g1; no custom-dose parity claim. The frozen `8a28534` parent passes
1,341 full tests, production and both TCP transports; its full native integration
passes (session 15548 exit 0), including plaintext and AES-CFB8 TCP. That immutable
release predates the new negative-dose guard; the guard's53 affected/native768,
production/TCP/client checks are separate. Full log:
`.local/named-consumption-live-full-native.log`; hashed publication proofs retained.
