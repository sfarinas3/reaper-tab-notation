# reaper-tab-notation

A REAPER ReaScript that renders a guitar/shamisen MIDI track as combined
standard music notation + tablature, live-updating from REAPER's native
piano roll. It's a docked ImGui panel, not a separate app - REAPER's
piano roll stays the only place you edit notes; this is a read-only view
(plus a small set of bounded click-to-edit fixes for string/fret
assignment) that mirrors it.

## Features

- Combined notation + tab staff, kept in sync via a shared layout engine
  (notation and tab always line up horizontally).
- Automatic string/fret assignment from raw MIDI pitch (a cost-minimizing
  heuristic - favors open strings, comfortable hand position, and
  avoiding awkward stretches), with a manual per-note override when it
  guesses wrong.
- Beaming, ties, rests, accidentals, ledger lines, grace notes, and a
  grand staff (treble + bass) for extended-range instruments (7-9
  strings) - all meter-aware, not just pinned to the take's starting
  time signature.
- Guitar-only technique markers auto-detected from MIDI velocity: palm
  mute and pinch harmonic.
- A "Show Note Names" toggle that prints each note's letter name beside
  it, and an "Instrument" preset (Guitar / Shamisen) that swaps string
  count, tuning, and max fret together.
- Playhead tracking and auto-scroll during playback.
- Print-to-PDF export - a genuine vector PDF (not a screenshot), reusing
  the exact on-screen rendering code, with a configurable print scale.

## Requirements

- [REAPER](https://www.reaper.fm/)
- [ReaPack](https://reapack.com/) and [ReaImGui](https://github.com/cfillion/reaimgui)
  - The Windows installer (see below) installs both of these for you
    automatically - nothing to do here if you use it.
  - Installing by hand instead (e.g. on macOS/Linux): install ReaPack,
    then in REAPER go to Extensions > ReaPack > Browse packages, search
    for "ReaImGui", and install it. Restart REAPER afterward.

## Installation (Windows)

1. Download and run `ReaperTabNotation-Setup.exe` (see `dist/` if
   you're building from source, or wherever you received it) - no admin
   rights required, it's a per-user install.
2. On the finish page, leave the checked "Finish setup automatically"
   checkbox checked and click Finish. This opens REAPER (or hands off to
   it if it's already running) and registers everything itself: the
   viewer becomes a REAPER action, and a one-click button is added to
   the Main toolbar. If REAPER was already open, close and reopen it
   afterward so the toolbar button appears (REAPER only reads its
   toolbar layout at startup).
3. If that checkbox didn't appear (REAPER's install location couldn't be
   found automatically), do the same two things by hand - full
   click-by-click instructions are in
   [`installer/POST_INSTALL.txt`](installer/POST_INSTALL.txt):
   1. Load `main.lua` as a REAPER action (Actions > Show action list...
      > New action... > Load ReaScript...), then run it to open the
      viewer.
   2. Load and run `install_toolbar_button.lua` the same way once - it
      adds a one-click button to REAPER's Main toolbar so you don't have
      to go through the Action List every time. Restart REAPER
      afterward to see it.

Once set up: select a MIDI item on a track and the tab/notation view
appears.

## Installing on macOS/Linux, or from source

There's no installer for macOS/Linux yet. Clone this repo, install
ReaPack/ReaImGui by hand (see Requirements above), then load `main.lua`
as a REAPER action the same way described in step 2 above, pointing the
file browser at wherever you cloned the repo.

## Development

`deploy.ps1` mirrors this repo into REAPER's Scripts folder
(`%APPDATA%\REAPER\Scripts\reaper-tab-notation`) for local iteration -
run it after any change, then re-run the script from REAPER's Action
List to pick it up.

See [`DISTRIBUTION.md`](DISTRIBUTION.md) for how the Windows installer
itself is built and packaged, including what's deliberately deferred
(license-key gating, Lua bytecode precompilation).
