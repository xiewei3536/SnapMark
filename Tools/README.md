# Test tools

Small helpers for driving SnapMark in automated UI tests (synthetic events need Accessibility
permission for the terminal). Build with `./Tools/build.sh`, binaries land in `Tools/bin/`.

- `uidrv` — post keyboard/mouse events (`key`, `click`, `drag`, `type`, `scroll`).
- `wins [owner]` — list on-screen windows with geometry and layer.
- `inputsrc [id]` — read or switch the keyboard input source (e.g. `com.apple.keylayout.ABC`).
