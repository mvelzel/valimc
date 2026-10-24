# VMC-056b — Phoenix LiveView viewer and familiar spark presentation

Status: Done
Milestone: Operations, alongside M3 at the user's request
Depends on: VMC-056a.

Replace the handwritten TCP/JavaScript hosted viewer with a Phoenix endpoint,
Bandit HTTP/WebSockets and real LiveView rendering/events. Match spark's visual
language in both the viewer and command feedback: palette, typography, compact
widgets, controls, call-tree rows, prefix, colors, emphasis and line structure.
Architecture-specific metrics remain accurately named. Preserve local bearer
links, bounded work and standalone report exports.
The viewer header uses “⚡ ValiMC” with a regular lightning emoji, per the user's
branding instruction; no spark logo or logo approximation is included.

Acceptance:

- A real LiveView mounts at the existing report URL, handles filters, tabs,
  sorting, expansion and flame zoom on the server, and updates over WebSockets.
- Follow the current spark viewer and chat presentation; no invented styling
  changes justified by BEAM architecture differences.
- HTTP connections, connected views, input sizes, render rows and timers have
  explicit limits. No web requests enter simulation owners.
- Unknown/expired report tokens fail closed, signed sessions/CSRF/origin checks
  protect LiveView, and local binding and offline exports remain intact.
- Targeted LiveView/event/security and command component tests pass. One batched
  client/browser handoff verifies chat appearance, URL, LiveView and exports.

Reference: spark-viewer `05d68bda52ef483122c1498794dbc2cb5e3ada78`,
`style/theme.scss`, `base.scss`, header/widgets/controls/sampler styles and
components; spark `3e8745a76eaabe9a4f70aad6283876fb518d2ae8`,
`CommandResponseHandler`, `HealthModule`, `SamplerModule` and
`StatisticFormatter`: component prefix, color thresholds, line breaks and
emphasis. Reference checkouts remain ignored; Elixir/templates/CSS are original.
Phoenix 1.8.16, LiveView 1.2.13, Bandit 1.13.1; packaged clients served locally.
JetBrains Mono `19371302b95d218af43299bce79ddbddd0bc364d` is self-hosted under
its OFL license; hashes and provenance are beside the fonts. Standalone reports
embed the fonts and license. Hosted views use packaged Phoenix clients and
server-rendered HEEx; JavaScript rendering remains only for offline exports.

The viewer caps connections at 64, connected views at 16, inputs at 128 bytes,
visible tree rows at 1,000, expansion state at 128 IDs, table rows at 500, hot
functions at 8,192 and flame frames at 2,000 / 24 levels. Only expanded branches
are grouped; no full deep-stack trie is built. One refresh timer follows work.
Signed mounts and CSRF sessions protect LiveView, unknown tokens fail closed,
and endpoint restarts republish the actual ephemeral port without losing captures.
TPS and scheduler windows average available health observations during warmup;
duration min/median/p95/max use the actual latest 100 independent region ticks.

Checks: 21 targeted profiler/LiveView/component tests pass, including forged
mounts, foreign origins, missing CSRF sessions, token expiry, admission release,
endpoint restart, input/render bounds, filters, sorting, expansion and zoom.
`mix test.fast`: 594 passed, 223 excluded. The first fast run encountered an
in-progress mob fixture failure from the concurrent M3 work; its owner's fixture
correction preceded the passing run. Later branding, snapshot labeling and input
guards passed the targeted tests again. Vanilla `commands` and `tcp` pass;
these cover the affected dispatch and startup/socket paths. No Mojang gameplay
rule changed. Checks use `.local/profiler-checks/_build` to avoid shared asset
replacement during other builds.

Dedicated client tester PASS, October 24, 2026, Java 26.3 / protocol 777:
terrain, stats, TPS/ping headings and colored value lines, dark brackets and
bold yellow lightning, health header/gray clickable link, gold start/stop/cancel,
movement while profiling, timeout and red unsupported-option feedback. Private
checkpoint `live-build` based on `f003101d` plus this slice; fresh whole dataset
`world-live-run01`. Client stopped and waited; status confirmed zero players.
Evidence: `.local/client-tests/VMC-056b/run-01`.

Final browser-only checkpoint: `.local/profiler-client/final-build`. The tester's
CUA context could not see IAB; after the user opened the panel, the primary's
browser controls could. Primary completed browser-only QA in Codex: yellow
“⚡ ValiMC” header, dark/light palettes, badges after names, tree expansion,
group/search filters, both process sort directions, flame zoom/reset, hot
methods, memory/ETS, counters and health. Region labels render with no connected
players. Filters remained through live refresh and completion of a real
251-second waiting-inclusive capture. Narrow screens hide bars as spark does.
The preview stylesheet received only the user's final lightning-color change
after the Minecraft client had exited. No spark logo was used.

An automated real-time Chrome check captured the WebSocket handshake/join and
`phx-connected`, with no JavaScript exceptions. HTTP JSON and HTML attachments
preserved 1,422,063 observations, embedded fonts/license, and a null live endpoint.
Fresh standalone source also passes JavaScript syntax and payload checks. IAB
blocks `file:` navigation, so final standalone visual reopening was unavailable;
the successful baseline execution check is recorded in VMC-056a. Active exports
are explicitly labeled snapshots. Evidence stays under `.local/profiler-checks/`
and `.local/profiler-client/`; the Codex preview remains available locally.
