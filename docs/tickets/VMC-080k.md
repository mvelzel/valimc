# VMC-080k — Recover long write-ahead logs within the memory budget

Status: In progress
Milestone: M3
Parent: [VMC-080](VMC-080.md).

The user cannot reconnect after the 080j deployment. Hetzner's kernel records
three container memory kills during the login attempts (14:02–14:03 UTC on
October 25). The container has a 3 GiB limit. World stripe 2 holds 2.8 GiB of
segments; stripe recovery retains every decoded payload before building the
location index and checking which frames checkpoints already cover. Readiness
and an open TCP listener do not exercise that saved-world path.

Acceptance:

- Recover the index one frame at a time, keeping payload memory independent of
  the historical log's length, including segments larger than the rotation size.
- Preserve the file format, checksum and increasing-LSN checks, incarnation,
  checkpoint floor, indexed locations and final torn-tail recovery. A damaged
  older segment must still refuse recovery without being truncated.
- Verify payload retention, restart/index recovery and saved-player reconnect.
  Deploy to the existing VPS and exercise saved-world recovery there, retaining
  the same volume, world and 32/10 distances. The user tests actual gameplay.

`RegionLog.open_fold/3` folds validated frames directly into a caller's compact
accumulator. The shared scanner reads a capped frame with raw positional I/O;
`open/1` and read-only recovery retain their list interface. The stripe retains
locations instead of payloads and applies the existing checkpoint/owner recovery
rules. No native code or storage-format migration is needed.

A stopped-volume copy of the complete 3.5 GiB data directory is retained on the
host at `/opt/valimc/backups/pre-recovery-fix-20261025`, before recovery changes.
The first focused run passes 30 checks across log, indexed restart, player
storage, region loading and directory-loss/reconnect flows. The retention test
folds 32 half-MiB payloads across oversized segments in a separate process,
forces collection and asserts less than 4 MiB of reachable binary data. This
checks memory retention, not a throughput or production TPS claim. Truncation
property cases also compare the streaming reader with the frame decoder.

Production recovery, deployment verification and user reconnect remain pending.
Evidence stays under ignored `.local/hetzner/recovery*`.
