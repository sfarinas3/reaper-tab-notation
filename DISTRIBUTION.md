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

It also installs ReaPack/ReaImGui (REAPER's own dependency) itself: pinned
copies of `reaper_imgui64.dll` and `reaper_reapack64.dll` live in
`vendor/` (see `vendor/VERSIONS.txt` for exactly which release each came
from and how to update them) and get dropped straight into REAPER's
`UserPlugins` folder, `onlyifdoesntexist` so an existing install is never
silently downgraded. This works without ReaPack ever running: REAPER
loads any DLL in `UserPlugins` exporting the right entry point regardless
of filename or how it got there, and our script only actually needs the
ReaImGui extension loaded - ReaPack itself was only ever the
*conventional* way a user would get that DLL, not a hard dependency of
a dependency. The DLLs are bundled (not fetched from GitHub live at
install time) so a friend's install never depends on internet access or
GitHub's release URLs staying put - the tradeoff is a pinned version that
needs a manual bump in `vendor/` for updates, same as any bundled binary.

Registering the script as a REAPER action and adding its Main-toolbar
button both require REAPER's own scripting API
(`reaper.AddRemoveReaScript`, and a read-modify-write of
`reaper-menu.ini` - see `install_toolbar_button.lua`'s own header),
callable only from a script already running inside REAPER - an installer
`.exe` running outside REAPER can't call it directly. Instead, the
`[Run]` section launches REAPER itself with `install_toolbar_button.lua`
as a command-line argument once Setup finishes: a checked-by-default
"Finish setup automatically" checkbox on the finish page runs
`reaper.exe -nonewinst "...\install_toolbar_button.lua"` (a real REAPER
command-line feature - passing a `.lua` path runs it as a script;
`-nonewinst` hands it to an already-running instance instead of opening
a second one). Since `install_toolbar_button.lua` registers `main.lua`
as an action as a side effect of adding the toolbar button, this one
step covers both, not just the toolbar half.

`reaper.exe`'s path is looked up via the registry
(`installer/setup.iss`'s `[Code]` section, `FindReaperExe`) -
`HKLM\SOFTWARE\REAPER`'s default value holds the install directory
(confirmed against a real install during development), with `HKCU` and a
couple of common default paths as fallbacks for a portable/manually-
placed install with no registry entry. This is best-effort: if none of
those resolve, the checkbox simply doesn't appear at all (`Check:
ReaperExeFound`), and `installer/POST_INSTALL.txt`'s manual instructions
- Load ReaScript for `main.lua`, then run `install_toolbar_button.lua`
the same way once - are the documented fallback, kept up to date even
though the automatic path now covers the common case.

The `[Run]` entry uses `nowait`: if REAPER isn't already running, this
step actually *launches* REAPER (a real session that stays open), not a
script that runs and exits - without `nowait`, Setup would sit frozen on
the finish page until the user closed REAPER. It also uses
`skipifsilent`, so an unattended/silent install never launches REAPER as
a side effect.

### Building it

1. Install [Inno Setup](https://jrsoftware.org/isinfo.php) (free).
2. From the repo root: `ISCC installer\setup.iss`
3. Output: `dist\ReaperTabNotation-Setup.exe` - this is the file to share.

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
