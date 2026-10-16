# VMC-003d — Held-button client validation

Status: In progress. October 16, 2026.

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
reconciler warning remains. Dedicated actual-client validation is in progress;
keep this checkpoint local until the complete report is reviewed.
