# VMC-080c — Bounded wide-view owner work

Status: Awaiting client
Milestone: M3
Parent: [VMC-080](VMC-080.md).

Skip inactive phase work without skipping required gameplay, bound generated
chunk adoption between simulation turns, and coalesce light preparation using
existing worker and fencing primitives. Preserve delivery credits, durable
installation, halo ordering and recovery. Keep existing native kernels; change
their boundaries only where bounded owner latency requires it. Validate the
affected region, generation, light and job flows before deployment.

Implemented an empty scheduled-rule fast path before redstone context preparation.
Generation has one unacknowledged delivery of at most eight chunks per group,
with the existing nearest-first ordering, epoch routing and durable release;
ready chunks wait in the scheduler instead of the owner's mailbox.

Halo/generation light packet compression runs as one job per section using the
existing chunk-encoding pool. Jobs capture at most four immutable chunk images;
pending masks coalesce by chunk (at most the section's served chunks), and an
`:all` notification subsumes `:border`. Chunk-version checks discard stale frames
and retry their masks against current light. Failure and group adoption rearm
the same bounded job path. Ordinary block-change packets retain their ordering;
unserved chunks no longer spend time encoding light nobody can receive.

No new NIF is needed for this slice: the heavy kernels already run in Rust; this
change removes preparation and duplicate work in Elixir and bounds the inputs
that block the owner. Remaining native-kernel or dirty-scheduler bottlenecks need
the user's next production capture.
