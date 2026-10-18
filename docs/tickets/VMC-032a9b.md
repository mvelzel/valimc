# VMC-032a9b — Durable ordinary chest exchanges

Status: Actual-client/full-test/production gates pass; full native integration pending. Depends on checked source,
region admission/receipt and joint-storage foundations; viewing has its own
[client gate](VMC-032a9a.md).

Acceptance: actual pickup/split/merge, shift transfer, number and offhand swaps
conserve the player+single-chest items through durable source preparation, one
region decision and source sealing. Freeze conflicting inventory/cleanup while
pending; bound queued actions and worker lifetimes. Refuse spectator/unsupported/
stale owner or view actions, refresh current authoritative contents, and recover
disconnect/crash without replay. Protect occupied chests from physical mutation
until atomic stored-item spilling exists.

Before client validation, exercise real TCP source/receipt consistency, competing
players, stale views, close during preparation, owner loss and fresh reconnect.
Client scenario: deposit/withdraw seven existing planks, split/merge, shift, number/
offhand and unsupported gesture; close with cursor, reopen/reconnect and audit the
whole dataset. The dedicated tester reports acceptance; raw evidence remains ignored.
Bounded revision polling is an initial viewer mechanism, not a final performance claim.

The socket serializes at most64 queued menu actions and one300ms candidate/admission
job. The player writer supplies its canonical next sequence; a bounded TransferWorkers
task obtains the existing region's one-use action permission. Only then does the
source durably prepare its original items. Existing receipt-backed delivery/sealing
finishes before conflicting inventory/close cleanup. The combined menu refreshes
from its owner after sealing, avoiding new player items beside stale stored contents.
Movement within reach is allowed; admission rechecks current mode/items/range/owner.

October18:101 affected checks pass(seed343843), including ten real TCP scenarios.
The full pickup/split/merge/shift/number/offhand sequence seals11 actions exactly,
retains3diamonds+8planks and survives cursor cleanup/fresh reconnect. Two live
players racing one view obtain only one3diamond stack and both refresh. Suspended
source-candidate close allocates no sequence; close during a prepared destination
write waits without inventory interleaving. Destination owner death after preparation
recovers one receipt/decision and closes the old view. Late chest predictions after
forced close are ignored without disconnecting; current-menu prediction bounds remain.
Spectator/opening/lid/owner/table and existing transfer regressions remain covered.
Raw `.local/chest-exchange-targeted-complete.log`, `.local/chest-exchange-boundaries.log`.
An added forged spectator withdrawal also retains its original items/sequence;
all ten TCP scenarios pass again(seed411991, `.local/chest-exchange-spectator-negative.log`).

Until physical spill callbacks exist, every direct/batched/block-transfer proposal
refuses changing an occupied container's block. The guard's46 affected checks
(seed60807) include all-or-nothing multi-block refusal, unchanged stored bytes and
durable mining rejection/replay with no drops. Same-state edits and unrelated/empty
containers retain their existing paths. Raw `.local/chest-occupied-guard-targeted-final.log`.
Native ordinary click semantics remain the23,040-case VMC-032a2 kernel; this slice
changes ownership/composition rather than inventing another click algorithm.

Frozen8503ab6 passes1,491 full tests and production build. Dedicated actual-client
validation passes pickup/deposit/split/merge/shift/number/offhand, clone/drop
refusals, occupied mutation refusal and cursor return/fresh reconnect. Exactly12
accepted changes move source67→79 and typed receipt63→79; storage revision1→11,
ending empty with all seven planks in player slot36. Item receipts67+61 remain
unchanged. Immediate cursor-close disk checkpoint still held cursor7; clean logout
saved the returned slot and fresh reconnect retained it. No new transfer was
allocated for close cleanup. Both wrappers stopped; zero players/connections,
all regions/clock flushed and server stopped0. Whole stopped dataset audit passes:
source79/outboxnil, typed79, entry11/27nil, items67+61,12HP/no effects, original
chest/table/incidental plank retained. Raw `.local/client-tests/VMC-032a9b/report.md`,
`.local/chest-exchange-final-audit.log`, full-test/production logs. Full native
integration is still running against the frozen checkpoint; this gate stays open.
