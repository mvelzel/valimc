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
The helper compiles and Java version probes pass. Its in-game mouse test is
**pending**: the Mac locked during restart and computer use requires manual
unlocking. No claim that the fallback fixes motion has been made.

After unlocking: launch the dedicated profile, confirm the new library is loaded,
join localhost, enable F3, record yaw/pitch, drag both axes and compare. Test menu
clicks too. If it works, test a fresh reconnect/restart and record the actual new
angles in VMC-003. If it fails, preserve the evidence and restore the helper's
default with `python3 scripts/prepare_minecraft_client.py` before another restart.
Full mouse support must not be inferred from keyboard movement or seeded poses.
