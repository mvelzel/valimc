# VMC-005b2a — Bounded quick-craft transactions

Status: Awaiting client
Note: Awaiting sustained client gesture validation. Updated: October 14, 2026. Depends on VMC-005b1. Publishing this checkpoint with the explicit request to push all work to `main`; the pending gesture gate is not marked Done.

## Scope and acceptance

The ordinary 26.3 client sends quick-craft start/add/end sequences when placing
carried items. Replace rejection with owner-local left-even and right-one
distribution across supported player slots 5..45. Creative fill, crafting slots,
collection, item drops and cursor return on close remain later slices.

- Start/add stages never mutate items. Deduplicate at most 41 valid targets;
  ignore incompatible, restricted and excess targets. End commits atomically.
- Preserve exact item patches and counts, respect item/armor caps and retain
  division remainders in the cursor. Single-target gestures use pickup semantics.
- Invalid phase order cancels without mutation. A different click during a
  gesture cancels without applying that click, matching vanilla. Creative writes,
  hand swaps and menu corrections cancel stale gestures.
- Predictions never supply authoritative items. Existing aggregate byte limits
  apply to distribution; failure restores accepted inventory and cancels gesture.
- Regression tests cover phase/order, duplicates, count shortage, restrictions,
  remainders, caps, component preservation, budget failure and TCP correction.
  Mojang codecs encode/decode a real quick-craft TCP scenario.

Actual-client scenario: ordinary menu right-half pickup, single-slot place-one
and merge; left drag across several slots; shift, number-key and offhand swaps;
unsupported operation followed by reopen. Inspect counts and authoritative cursor.
Use the isolated SDL event-position adapter; record fixtures separately from UI
input. Run formatting, ExUnit, release, vanilla oracle and public-tree audit.

## October 14 bounded retry

Ordinary-menu mouse pickup now works. A fresh 17-item glint fixture was actually
picked up, then CUA `drag([565,653],[780,653])` crossed four visible cells. The
observed result was one stack of 17 in slot 21, empty cursor and nil drag state,
consistent with a one-target gesture. It does not pass sustained multi-slot
distribution. The gate remains pending; no further gesture retries were made
in that session. Cleanup restored the fresh original pose/inventory/creative UI
and verified physical source 34/nil outbox. Private context:
`/tmp/valimc-vmc005b2a-mouse.etf`. Continue independent implementation.

## References and design

Pinned vanilla 26.3 jar `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`:
`AbstractContainerMenu.doClick/resetQuickCraft/canItemQuickReplace/
getQuickCraftPlaceCount`, `AbstractContainerScreen.quickCraftToSlots` and mouse
handlers. Private bytecode remains under ignored `research/disassembly/`.
Buttons encode phase in the low two bits and mode in the next two. A one-target
end delegates to pickup; multi-target left distribution divides the original
cursor count, while right distribution adds one per target. Interrupting an
active gesture consumes the interrupting click without applying it.

SteelMC's previously pinned inventory dispatcher informs the input/operation
separation (see VMC-005b1); vanilla determines semantics. Original Elixir code
keeps a bounded target set inside the connection's existing inventory struct.
There are no additional processes, shared mutable menus or gameplay coordinator.

## Verification

October 13, 2026: all 65 ExUnit tests, formatting, production release and full
Mojang oracle pass. New cases cover phase/order cancellation, deduplication,
count shortage, patch/count conservation, armor restrictions, caps, specialized
item rejection, interrupted clicks, aggregate budget failure and TCP correction.
The official oracle encodes a stale/forged quick-craft sequence and decodes the
accepted three-slot result; forged diamond observations cannot create diamonds.

Actual 26.3 CUA basic pickup/place-one/merge/shift/number/offhand/drop-rejection
checks pass (VMC-005b1). A local normal-packet-handler fixture distributed 17
custom-NBT/glint stones into three stacks of 5 and a cursor remainder of 2.
CUA screenshots showed all counts and glint; a real CUA click returned the
remainder to the hotbar. This proves graphical replication of the result,
not client-generated multi-slot drag input.

CUA drag attempts initially used a stale physical pointer and triggered an
outside-menu rejection. The isolated SDL patch now keeps native event positions
in menus too. Further short/long drags and held-click/motion experiments produced
ordinary endpoint pickup packets, rather than a sustained multi-slot gesture.
Record this automation limitation explicitly: reproduce left-even and right-one
multi-slot gestures through actual client mouse input before marking Done.
No full inventory parity or performance claim. Cursor return/collection/drop
remain separate work. Checkpoint subject: `VMC-005b2a: commit bounded inventory drags`.

October 15 bounded retry: actual pickup 36 then drag across 9..12 generated only
endpoint pickup 12, no quick-craft packets. Gate remains pending; right/middle
held motion is unavailable in the documented CUA API. Complete state restored,
logs clean. `.local/client-tests/VMC-005b2a/retry-20261015/report.md`.

October 16 bounded retry with validated SDL F9/F8 latches: reviewed; gate remains pending.
On frozen `489916833cdccec2c6e3eef27bdfbeefda300a71`/PID56593, actual 17-item
fixture pickup then F9+documented drag across 9..12 produced endpoint 12 count 17;
trace showed pickup/pickup_all, no quick-craft. F8+drag across 18..21 produced
ordinary right-half pickup and endpoint placement (12=8,21=9), no quick-craft.
The documented API provides left-button drag, but no pure pointer movement or
right-button drag to combine with a held latch. This bounded attempt does not
verify multi-slot distribution or establish a server quick-craft failure.
Ordinary merge/reopen rendered 17 correctly. Owned JVM exited 143; zeroPlayers 0,
passive trace disabled, exact original worn-tool inventory/pose restored.
Source 25/outboxnil and all 41 exact records/receipts25/10/6/9 unchanged. Evidence,
actions and precise limits:
`.local/client-tests/VMC-005b2a/retry-20261016/report.md`.
