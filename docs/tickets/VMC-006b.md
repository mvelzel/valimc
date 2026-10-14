# VMC-006b — Overworld weather cycle and synchronization

Status: Done — Overworld weather cycle validated, local. Updated: October 14, 2026.
Depends on VMC-006a's delivered world ticks, immutable publications and fenced I/O.

## Scope and acceptance

Implement native clear/rain/thunder timers, independent flags, float32 intensity
ramps, weather-cycle control and real-client synchronization. Integrate weather
as pure state in the existing world environment owner/tick/checkpoint, keeping
region gameplay and player mutations outside that owner. Lightning entities,
damage/fire, snow/ice, biome precipitation, sleep changes, vanilla commands,
permissions and complete gamerules/dimensions remain separate tickets.

- Invoke Mojang's actual `ServerLevel.advanceWeatherCycle` in an isolated probe;
  compare timer/flag/RNG/intensity states and exact event order over transitions,
  clear overrides and frozen cycle. Native random ranges and draw order must
  match. Use an owned persisted legacy 48-bit random stream; global vanilla
  simulation random ordering remains future work.
- Weather ticks independently of advance-time. Disabling advance-weather freezes
  timers/flags while intensities still approach their targets. Native raining
  observation uses the intensity threshold, not the saved raining flag.
- Connections sample cached immutable weather views; bound reconciliation to the
  native five-event maximum and batch socket writes. Missed UI updates may
  coalesce; authoritative weather state still executes every delivered tick.
- Extend the bounded/checksummed world record with weather timers/flags/control/
  random state. Read old clock records without losing their values; save the new
  version. Rebuild transient intensities exactly as vanilla prepares loaded
  weather. Existing stall/fence/failure/corruption contracts remain mandatory.
- Meaningful unit/TCP/native regressions, format, full suite, release, full Mojang
  oracle, audit and exact diff review must pass.

Actual Minecraft 26.3 through CUA: host fixtures start rain and thunder with long
explicit durations, observe gradual rain/darkening, disable the cycle and check
continued intensity completion/command response. Clear weather must fade out.
Verify automatic short-duration transitions, reconnect and full restart of pinned
weather flags/timers; restored intensity follows vanilla load preparation.
Restore clear normal cycling, original clock controls and original player pose/
empty inventory, retaining source counters. Fixture host controls do not prove
unimplemented client weather commands or lightning gameplay.

## References

Pinned Mojang 26.3 SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`ServerLevel.advanceWeatherCycle/prepareWeather`, `WeatherData`, `Level.isRaining`,
`LegacyRandomSource`, `UniformInt` and `ClientboundGameEventPacket`.
Bytecode/captures/oracle output stay in ignored paths.

## Verification

October 14 automated: format check, all **270 ExUnit tests** (seed 220683),
production release, full Mojang oracle and public-tree audit pass. The native
probe invokes `ServerLevel.advanceWeatherCycle` for **480** traces / **50,400**
ticks, comparing flags, all timers, owned random seed, float32 intensities and
exact ordered game-event bodies. It captures the actual broadcast effects from
constructor-free probes, without launching a gameplay server. Full TCP decoding
also verifies initial clear-weather synchronization through Mojang's codec.
Private logs: `.local/vmc006b-{tests,release,oracle}.log` and native fixture log.

Seven new tests cover frozen cycle/independent daylight, overrides/refill and draw
order, threshold/event order/coalescing, validated presets, record migration/load
preparation, persisted controls and actual TCP ramps/start/stop/continued commands.
Existing clock storage stall, fencing, failed-write and corruption tests still
pass with the extended record. Native random sampling is bounded to 16 rejection
draws per weather timer; actual ranges use the native inclusive bounds. The random
stream is owned/persisted separately; full simulation draw ordering remains work.

World record version 2 is **111 bytes** with these core clocks; version 1 remains
readable. Weather timers/flags/control/random history save with clock state in one
checkpoint. Transient intensity is intentionally rebuilt as vanilla prepares
loaded weather: rain 1 when raining, thunder 1 only when both flags are true.
Observers may coalesce visual updates but emit the native five-event maximum in
native order; the authoritative environment step never skips weather state.

Actual **Minecraft 26.3**, installation `ValiMC computer-use test`, app
`local.valimc.minecraft-client`, localhost production release starting **08:36:02
CEST**: CUA rejoined, switched to third person and observed rain particles and
rain darkening, then thunder darkening and `/stats` response. Both 6000-tick timers
stayed frozen while intensity reached 1. Clear host control faded to a blue sky.
A private fixture watching actual hotbar selection synchronized captures of the
fade and an intermediate rain ramp; a two-second held selection captured visible
partial rainfall. These are host weather fixtures, not weather command support.

A 160-tick rain fixture with normal cycling expired automatically, refilled its
native rain delay and cleared rainfall; CUA observed the rain and later clear sky.
The independent thunder flag's native expiration behavior was retained. No
lightning entity/sound/damage is claimed. A fresh frozen storm pinned all weather
fields; normal disconnect/rejoin recovered the same weather. A full release
restart at **08:51:00 CEST** restored exact timers/flags/cycle/random state and
native prepared intensity without reseeding; the client rendered the storm.

Cleanup restored clear normal cycling and original clock controls, accounting for
elapsed game ticks when restoring the temporarily paused Overworld clock. Original
pose, empty inventory, hotbar 0, nil outbox and source sequence **29** stayed intact.
At **08:53:25 CEST**, game time was 64337 and both intensities were zero. First-person
view was restored and the client left paused. Private context:
`/tmp/valimc-vmc006b-context.etf`; client log
`.local/client-tests/VMC-006b/latest.log` has zero ERROR/DecoderException entries.

No runtime repairs were needed during graphical validation. Lightning, snow/ice,
biome precipitation, sleep, vanilla weather commands/permissions, complete
gamerules/dimensions and native saved-data NBT remain incomplete.
