# VMC-080e — Release callback peer contexts

Status: Awaiting client
Milestone: M3
Parent: [VMC-080](VMC-080.md).

`Region.enter/2` supplies the group's current authoritative peer projection for
one callback. `put_resource/3` currently retains it in the section afterwards,
so every section roots historical versions of neighbouring stores. The transfer
path already clears it before sending a section to another process. Store only
section-owned state between callbacks; the next callback obtains fresh peers.
Preserve ordered sibling effects and their same-group atomic commit, and verify
that later callbacks see current peers after edits and entity handoffs.

Validate retained graph size with a matched owner-state fixture, and exercise
group ticks, rules, entity movement, lighting, commits and group transfers. This
is a retention fix, not evidence by itself of a production MSPT improvement.

Implemented clearing the ephemeral peer projection at `put_resource/3`. Pending
sibling effects remain in order and the next callback receives `state.peers`.
The real two-section group test now checks that resident resources retain no
peer projection after edits, ticks and a transfer; the group still holds its
current projection once.

A matched retained-graph fixture with 80 sections, 32 entities per section and
30 rounds of distinct body updates retains 434,618 versus 528,941 words after
collection (about 18% fewer). The resulting process heap is 6.67 versus 11.52 MB;
heap sizing is discrete, so this is not an equivalent production RSS reduction.
Checksums match. Raw fixture and five samples per path remain in ignored
`.local/wide-view-perf/profile5/peer-retention*`.
The owner, rule, movement, lighting, commit and transfer regressions pass, along
with the fast suite and affected vanilla stages; shared verification evidence is
in the parent ticket. The production memory/MSPT effect awaits the user's profile.
