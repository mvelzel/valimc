# VMC-017b4a — Live lava and ongoing burning

Status: Implemented locally; automated checks pass, graphical gate pending.
Depends on the verified [fire foundations](VMC-017b4.md).

Acceptance: the existing admitted player clock advances burning; at most one
pending burn request resolves against fresh fenced fluid geometry. Lava ignites,
requests4 raw damage, clears freezing and suppresses the concurrent on-fire
request. Exiting retains burning; water/powder snow extinguish. Mode/loading/death
gates apply. Cooldown selection precedes bounded wear, then fresh equipped armor
and enchantment reduction; replicate inventory, armor HUD, fire flags and death.
Preserve journals through reconnect and concurrent inventory recovery. Delayed or
replaced geometry cannot apply stale lava damage or create catch-up bursts.

Client: survival lava/exit/burning/water, creative negative, armor/Fire Protection/
Netherite/breaking, burning reconnect and fatal lava/burning/respawn. Record fixture
setup separately from actual graphical actions. Natural fire blocks, swept block
effects, rain and status-effect defenses remain parent follow-ups.

References: pinned26.3 `Entity.baseTick/lavaIgnite/lavaHurt/clearFire`,
`LivingEntity.getDamageAfterArmorAbsorb/getDamageAfterMagicAbsorb/doHurtEquipment`,
`Player.hurtArmor`, `ItemStack.hurtAndBreak`. See parent for native case evidence.
Current fluid body samples are shared with the validated travel lane; exact block
effect/sweep contact boundaries remain a parent follow-up.

October16:96 affected tests pass(seed196704), `.local/fire-live-affected-final.log`.
Coverage includes fresh lava/cooldown packets, freezing reset, bounded pending burns
under a stalled region, stale timer tokens, water/extinction, mode/loading gates,
Fire Protection duration, break-before-reduction, Netherite wear immunity, pending
inventory refusal/fresh recheck, durable fatal drops and respawn. Existing health,
air/freezing/void/food, equipment, inputs and transfer/store regressions pass.
No new process/timer is introduced; simulation reuses the existing query lane.
Break events and source exhaustion are pinned native facts (head49/chest50/legs51/
feet52; lava/direct fire0.1, ongoing burning0).138,080 native wear cases plus those
facts pass `.local/armor-wear-native-check-final.log`;582 burning cases still pass
`.local/fire-live-burning-regression.log`.

Frozen runtime `7b5b382` builds in production and passes96 affected checks. The
larger suite found one test-reader assumption: legitimate armor updates replaced
its remembered interaction packet. Readers now retain attributes by entity/holder;
17 affected checks pass(seed699173), and Mojang decodes both attribute packets and
all scenarios over plaintext/AES-CFB8 TCP. Logs:
`.local/fire-live-{production,attribute-readers-final,native-tcp-final}.log`.
The complete suite is being rerun with the corrected reader. The dedicated tester
is validating this unchanged runtime; keep it local until its report is reviewed.
Parent fire-block/effect work stays open.
