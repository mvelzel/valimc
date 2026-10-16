# VMC-003d — Held-button client validation

Status: Validated and complete. October 16, 2026.

The native CUA API exposes blocking timed clicks, so captures and selection
actions cannot occur while a click remains held. Eating completion passed, but
that cannot establish visible mid-use animation or held-use interruptions.

Add two fixed gestures to the mandatory dedicated SDL adapter: F8 toggles its
logical right button (use), F9 its left button (attack). Repeat/key-up events do
not toggle. Ordinary clicks and shutdown release through the same SDL button
state. No Minecraft class changes, desktop pointer access, modes or fallbacks.
The dedicated tester remains the only CUA driver.

Acceptance: patch/build the pinned SDL backend; fresh Java26.3 client through CUA
shows held eating and attack, intervening selection and explicit release, then
clean shutdown. Keep actual VMC-036c results/limits in its ticket. Test native
input behavior; no desktop-position tests or broad server tests for this adapter.

Reference: pinned SDL `ab5541ec5d4377dcc20a701897437f07ba71566f`,
`Cocoa_HandleKeyEvent`, `SDL_GetMouseState` and `SDL_SendMouseButton`.
Source/license and build products stay ignored. Never replace the library while
an owned JVM is running.

Patch application/reapplication, Python syntax and native Release build pass.
Library SHA256 `06f24507707dc2a2973a645dc7ab1a3b3d57501e1b896cc81a01850b164950e1`;
ignored `.local/sdl-hold-build.{json,log}`. The existing unused physical-button
reconciler warning remains. The complete dedicated actual-client report below
has been reviewed and accepted.

October16 dedicated actual-client evidence — reviewed and accepted: fresh
VMC-036c runs05/06 fingerprint rebuilt dylib06f24507707dc2a2973a645dc7ab1a3b3d57501e1b896cc81a01850b164950e1.
F8 held use allowed actual main/offhand raised-food/crumb snapshots, intervening
main selection/hand swap, offhand selection retention and explicit release.
Direct held-use disconnect lastremaining5 followed by fresh launch gave released
idle hands/use nil/flags0. F9 held creative attack visibly swung/produced stone
particles and removed12 of28 disposable row cells; explicit release then movement
stopped against intact stone,16 held65samples. Row restored exactly. Normal
pause Back to Game click/camera drag worked after release. No desktop pointer,
cursor diagnostics, Minecraft class changes or survival-mining claim. Both owned
JVMs stopped/waited143, zeroPlayers, same server7337/PID74315; all29 world items/
source10/outboxnil conserved. Short report `.local/client-tests/VMC-003d/report.md`;
raw attack/restore and VMC-036c held-use traces remain ignored.
