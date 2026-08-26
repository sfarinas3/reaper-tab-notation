# Distribution

This app is a REAPER ReaScript, not a standalone program - it only runs
inside REAPER (via ReaImGui) and reads MIDI directly from REAPER's active
take. There's no way to make it a double-clickable app independent of
REAPER; "installable and executable" here means a Windows installer that
does the file-copying REAPER itself requires.

## Current approach: Inno Setup installer

`installer/setup.iss` builds a single `ReaperTabNotation-Setup.exe` that
copies `main.lua`, `install_toolbar_button.lua`, `src/*.lua`, and
`assets/*` into the current user's
`%APPDATA%\REAPER\Scripts\reaper-tab-notation\` (the same folder
`deploy.ps1` targets for local dev). It's a per-user install - no admin
rights, no UAC prompt.

It deliberately does NOT:
- Install ReaPack/ReaImGui (REAPER's own dependency - `main.lua` already
  shows a clear message box on launch if ReaImGui isn't present).
- Register the script as a REAPER action automatically, or add its
  Main-toolbar button. Both require REAPER's own scripting API
  (`reaper.AddRemoveReaScript`, and a read-modify-write of
  `reaper-menu.ini` - see `install_toolbar_button.lua`'s own header),
  callable only from a script already running inside REAPER - an
  installer `.exe` running outside REAPER can't call it directly. The
  installer's finish page (`installer/POST_INSTALL.txt`) instead tells
  the user the two manual one-time steps: Load ReaScript for `main.lua`
  (Actions > Show Action List > New Action > Load ReaScript), then run
  `install_toolbar_button.lua` the same way once to get the toolbar
  button.

### Building it

1. Install [Inno Setup](https://jrsoftware.org/isinfo.php) (free).
2. From the repo root: `ISCC installer\setup.iss`
3. Output: `dist\ReaperTabNotation-Setup.exe` - this is the file to share.

### A future improvement: zero manual steps

Could close the remaining "two manual steps" gap by having the installer
launch REAPER with a tiny one-shot bootstrap ReaScript
(`reaper.exe -nonewinst bootstrap.lua`) that calls `AddRemoveReaScript`
for `main.lua` and then runs the same logic `install_toolbar_button.lua`
already has, and then exits. Not built yet since it adds real complexity
(locating `reaper.exe`, handling REAPER already being open, handling a
portable install) for a one-time step the user only does once anyway.

## Deferred: license-key prompt

Not implemented, but the packaging above doesn't block adding it later -
the sketch, if/when it's wanted:

- On first run, `main.lua` checks `reaper.GetExtState("reaper-tab-notation",
  "license_key")`; if empty, shows an ImGui prompt (a text input + a
  "Continue" button) before drawing anything else, and saves whatever's
  entered via `SetExtState`.
- Validation options, roughly in order of effort:
  1. **No validation at all** - just gate on "is something entered."
     Zero protection, but also zero infrastructure; relies entirely on
     the sales channel (see below) to keep the download itself gated.
  2. **Offline signature check** - keys are pre-generated
     (`<data>-<HMAC signature>`) at sale time (e.g. by whatever tool
     issues them on purchase), and the script verifies the signature
     locally with a shared secret baked into the source. No network call
     needed from Lua (which has no built-in HTTP client), but the secret
     lives in shippable source, so a determined user could extract it and
     forge keys.
  3. **Online validation** - calls out to a license server to check the
     key. ReaScript Lua has no native HTTP client; this would need either
     the community `JS_ReaScriptAPI` extension (adds a dependency) or
     shelling out via `os.execute`/`io.popen` to `curl` (works, but is a
     genuinely ugly way to make an HTTP request from Lua).
- Realistic expectation either way: Lua ships as readable source (see
  below), so this raises the bar for casual copying, not a real barrier
  against a determined user. Most small paid-ReaScript sellers accept
  that and lean on the sales channel instead.

## Deferred: precompiling to Lua bytecode

Not implemented, but also a drop-in change when wanted - REAPER's Lua
runtime (5.4) can load precompiled bytecode (`.luac` files, via
`luac5.4 -o main.luac main.lua`) in place of source. Swap it in by
pointing `installer/setup.iss`'s `[Files]` section at the compiled output
instead of the repo's `.lua` files - nothing else about the installer
needs to change (see the comment already in that file's `[Files]`
section).

Caveats to check when actually doing this:
- The `luac` version used to compile must match REAPER's bundled Lua
  version, or the bytecode won't load - verify against whatever REAPER
  version is being targeted.
- `require()`'d modules (everything in `src/`) would each need their own
  `.luac` compile, and `package.path`/`require` resolution needs to find
  `.luac` files instead of `.lua` (a small change to `main.lua`'s
  `package.path` setup, or renaming the compiled files back to `.lua`
  extensions so `require` finds them unchanged).
- This is a mild deterrent (raises the bar above plain-text source), not
  real protection - Lua bytecode decompilers are publicly available.

## Selling it

Given neither of the above is a real DRM barrier, the pragmatic path most
small ReaScript sellers use: sell the installer download itself through a
platform like Gumroad or Payhip (handles payment + delivery + optional
per-purchase license-key generation for you), rather than building custom
payment/licensing infrastructure from scratch.
