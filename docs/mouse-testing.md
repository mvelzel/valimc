# Minecraft mouse input investigation

October 13, 2026. Java 26.3, Microsoft OpenJDK 25.0.1, macOS, computer-use app
`local.valimc.minecraft-client`. Part of VMC-003's verification prerequisite.

## Observed results

Keyboard movement, F3, chat, Tab navigation and command submission work. With
the bundled SDL 3.4.14, these mouse attempts did not change F3 yaw/pitch:

- Small, large and reverse-direction drags.
- Explicit primary/secondary clicks and held clicks before dragging.
- Full screenshot coordinates and half-size Retina coordinates.
- Raising the window, releasing/regrabbing the cursor with Escape, and fullscreen.
- A fresh client with `SDL_MOUSE_RELATIVE_SYSTEM_SCALE=1` in the dedicated helper.

Menu clicks also often move the pointer without activating the button. Use
observed keyboard focus; hover outlines do not prove focus. The Launcher can be
navigated to the test profile's Play button with Tab/Shift+Tab and activated with
Space. Inspect the actual focused control before activation.

Private inspection of the installed 26.3 client showed `InputConstants.grabMouse`
enables SDL's window-relative mouse mode; `MouseHandler.onMove` consumes the
event's relative deltas while grabbed. SDL's macOS backend uses GCMouse for raw
input and can bypass synthetic Cocoa events. This is a plausible explanation,
not yet a verified diagnosis of every failed gesture. See the
[SDL macOS notes](https://wiki.libsdl.org/SDL3/README-macos) and
[synthetic-click issue](https://github.com/libsdl-org/SDL/issues/16241).

SDL's development API adds
[`SDL_MAC_USE_GCMOUSE=0`](https://wiki.libsdl.org/SDL3/SDL_HINT_MAC_USE_GCMOUSE)
to use ordinary Cocoa input for remote-control software. This requires the 3.6
development implementation; the installed 3.4.14 library does not contain it.
The latest stable SDL checked during this investigation was 3.4.18.

## Isolated fallback experiment

The official SDL source at `ab5541ec5d4377dcc20a701897437f07ba71566f` was built
without changes. Source/license files stay under ignored `research/tools/SDL`,
and build outputs stay under ignored `.local/sdl-mouse-build`. Reproduce with:

```sh
git clone --no-checkout https://github.com/libsdl-org/SDL.git research/tools/SDL
git -C research/tools/SDL checkout ab5541ec5d4377dcc20a701897437f07ba71566f
cmake -S research/tools/SDL -B .local/sdl-mouse-build -DCMAKE_BUILD_TYPE=Release -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_STATIC=OFF -DSDL_SHARED=ON
cmake --build .local/sdl-mouse-build --parallel 8
python3 scripts/prepare_minecraft_client.py --sdl-library .local/sdl-mouse-build/libSDL3.dylib
```

Preserve an existing checkout instead of cloning over it. The helper validates
the hint is present, sets it before SDL initialization, and supplies the absolute
library through LWJGL's `org.lwjgl.sdl.libname` JVM property. Only the dedicated
test profile uses this helper. Minecraft classes, official installed libraries
and the normal Launcher profile are untouched. This is an experimental native
input backend and must be recorded with GUI results.

This Mac's built library SHA-256 is
`934465deee61c4acf354758b097d249897210b1082659790c6a17734daac246b`.
The unmodified Cocoa fallback improved menu activation and changed pitch once
from -25.0 to 39.1, but subsequent drags did not reliably rotate the view. The
visible pointer could move while the game's inventory pointer remained at an
older position. This does not establish a complete diagnosis of the tool's event
transport.

## Working event-position adapter

The user enabled and authorized computer use while the physical MacBook was
locked. Launcher navigation, game launch, loopback join/rendering, keyboard
movement and command submission then worked in that session.

Our small original `scripts/patch_sdl_mouse.py` adds an opt-in input adapter to
the pinned private SDL checkout. It preserves unexpected edits and refuses a
different revision. While enabled, the window listener updates absolute pointer
position before button-down, button transitions come from the delivered Cocoa
events rather than polling physical button state, and grabbed motion derives
relative deltas from event positions. This translates computer-use input; it does
not change Minecraft classes, protocol logic, assets or server mechanics.

```sh
python3 scripts/patch_sdl_mouse.py
cmake --build .local/sdl-mouse-build --parallel 8
python3 scripts/prepare_minecraft_client.py --sdl-library .local/sdl-mouse-build/libSDL3.dylib --event-position-mouse
```

Use the same dedicated Launcher installation and restart the client. The adapter
requires `VALIMC_CUA_EVENT_POSITION=1`; normal helper generation does not enable
it. The final tested build SHA-256 is
`fb36cc666bf8a606d72c9048e8201733ac49a93281b2458c8f5ac699095c1a06`.
A read-only `lsof` check confirmed the isolated library was loaded. The source,
license, binaries and raw client logs remain ignored; only our original patching
and helper code is public. Restore installed libraries by regenerating the
helper without flags and restarting the dedicated client.

Actual 26.3 evidence, October 13, 2026:

- Repeated opposite-direction drags changed both axes. The final build changed
  yaw/pitch 104.7 / 47.1 to 112.2 / 43.3, then 97.2 / 50.8.
- Menu clicks opened Multiplayer and joined localhost. Inventory clicks selected
  Oak Log and wrote it to the intended first hotbar slot; the previous stale
  internal-position behavior no longer prevented targeting.
- An earlier adapter build generated yaw/pitch 104.7 / 47.1. Keyboard movement to
  XYZ -1.584 / 64.000 / -0.048, reconnect and graceful release restart restored
  the same pose. `/spawn` and reconnect separately restored 0.500 / 64.000 / 0.500.
- Creative slot edits preserved a glint/custom-NBT stack and ordinary blocks
  placed from both hands. Excessive NBT depth displayed the intended rejection;
  reconnect recovered the previous pose and world rendering.
- Final keyboard/paste `/stats` returned one player, four regions, ten schedulers
  and 77 MiB. The latest client log had no network codec errors.

`drag` holds the primary mouse button and can mine blocks while rotating. Use a
separate test world and account for that side effect; camera motion is now
available, but exact physical mouse sensitivity is not certified. CUA clicks
with a carried stack can also produce vanilla quick-craft packets; the current
server rejects those until VMC-005b2. A restored inventory after that request is
not a pass of the pending ordinary placement/drag scenario. No survival, full
inventory lifecycle, or bundled-SDL mouse compatibility is inferred from these
input tests.
