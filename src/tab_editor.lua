-- Edit Mode: click an empty tab-staff position to create a note (type a
-- fret number and a duration), click an existing note to edit its
-- duration or delete it. Coexists with (doesn't replace) note_editor.
-- lua's View Mode click-to-correct popup - main.lua branches which
-- module's check_system runs on a staff click based on ui_chrome.lua's
-- Edit Mode toggle.
--
-- Duration is entered as a plain denominator - "4" for a quarter note,
-- "8" for an eighth, "16" for a sixteenth, matching how a musician would
-- actually name the value, and directly convertible to ticks:
-- ticks = 4 * ppq_per_quarter / denominator (see ticks_for_denominator/
-- denominator_for_ticks below) - the same values config.layout.
-- duration_classes already uses (240=16th, 480=8th, 960=quarter, etc.),
-- so nothing new is being invented, just exposed as a typed field instead
-- of a drag gesture. A trailing "T"/"t" (e.g. "8T") means triplet-scaled -
-- the exact same suffix REAPER's own grid-snap dropdown already uses for
-- its "1/8T" divisions - and computes the note's real (shorter) MIDI span
-- instead of the plain notated one, so notes typed this way land evenly
-- enough to actually be recognized as a tuplet by the notation view (see
-- ticks_for_triplet_denominator/parse_duration_input below). Before this
-- existed, typing a plain "3" (a real but different, much LONGER value -
-- a literal third-note, 1280 ticks) was the only way anyone would think to
-- attempt a triplet note here, silently created a wildly oversized note,
-- and made the next note's placement spuriously collide with it. An
-- earlier design tried press-and-drag to resize an
-- existing note's rendered end - reverted after live testing: this app
-- draws only a fret-number glyph at a note's ONSET, nothing at its end
-- unless mid-drag, so there was no reliable visual affordance to grab in
-- the first place, and a typed value is arguably more natural for tab
-- entry anyway (durations are already named by denominator). A typed
-- duration also sidesteps needing to freeze the rest of the score or
-- detect an in-progress external edit the way a continuous drag would
-- have - it's one atomic popup commit, same as every other write in this
-- file.
--
-- A newly created note's duration field defaults to whatever the
-- TEMPORALLY PREVIOUS note in the piece (any string, not just the
-- clicked one - rhythm applies across the whole texture) is currently
-- using, so typing a run of same-length notes doesn't require re-entering
-- the same denominator every time; the very first note in an empty take
-- has nothing to default from, so it falls back to a quarter note (see
-- previous_note_duration/M.end_frame's create-popup-open logic).
--
-- Locating a click (see next_create_tick/sequence_frontier): a click on
-- empty space doesn't get to name an arbitrary tick at all. This app
-- renders one shared rhythmic timeline (chords are simultaneous notes
-- across strings, not independent per-string tracks - see notation_model.
-- detect_rests' own header), so a click that landed wherever it pleased
-- could leave an unaccounted-for gap between it and whatever was already
-- there - one that only reads as silence because detect_rests happens to
-- fill it in as a rest, exactly the kind of accidental extra-voice-looking
-- gap that function had to be hardened against once already. Instead, a
-- click on string_idx only ever resolves to one of: the tick of the chord
-- you just placed (if string_idx is still free there - stacking another
-- note onto it), the sequence frontier (the latest endppq among every
-- note in the take - the natural next slot), or a measure boundary at or
-- past that frontier (the one deliberate exception: starting fresh at the
-- top of a later measure, skipping any silence in between as an ordinary
-- rest). Whichever of those is pixel-closest to the click wins - layout_
-- engine.lua's M.x_for_tick gives each candidate's real on-screen x, so
-- there's no separate inverse math and no risk of disagreeing with how
-- everything else on screen is actually positioned.
--
-- Vertical/horizontal click gates: note_editor.lua's existing-note radius
-- hit-test is self-bounding (it only ever matches near a real drawn note),
-- so it implicitly never fires on empty space. "Click empty space to
-- create" has no such implicit bound, so this adds explicit ones: a
-- half-line-height vertical band around the tab staff's own string rows
-- (not measure_correction.lua's bar_top/bar_bottom, which spans the whole
-- system including the notation staff above - a different, deliberately
-- coarser gate for a different purpose), and the system's own barline_x
-- range horizontally (plus a little slack), so a click in blank space past
-- a short last system doesn't register as a hit at all.
--
-- Collision handling is refuse-only, never truncate, for BOTH create and
-- duration-edit: checked against RAW MIDI note spans (assigned_events'
-- startppq/endppq - fret_heuristic.assign_events' output, passed in via
-- begin_frame), not the render model's duration_ticks, which is a
-- notation-only gap-capped value, not a note's real sustain (layout_
-- engine.lua's own header explains why - see also measure_correction.lua,
-- which established this same precedent). If any existing note already
-- occupies the target string within the requested span, the write is
-- refused with a status message rather than silently truncating it.
-- Editing a note's OWN duration excludes that note itself from the
-- collision scan (by idx - see string_occupied's exclude_idx param), so
-- it never collides with its own current span.
--
-- Crossing a barline is explicitly fine and needs no special handling: a
-- typed duration long enough to cross one just renders as this app's
-- existing automatic tied-segment split (layout_engine.compute, given
-- cached_measure_ticks) - standard engraving practice already built for
-- every other note in the piece, not something Edit Mode needs to prevent
-- or account for separately.
--
-- The Edit popup's Fret field (added alongside Duration - see
-- draw_edit_popup/commit_edit) lets an existing note's pitch be corrected
-- in place, without a delete+recreate round trip.
--
-- Fast tab-entry chaining (see commit_create's own comment): committing a
-- newly created note - via Enter or the Add button, both funnel through
-- commit_create - re-arms the SAME create popup for the next note on the
-- same string, right where this one ended, IF AND ONLY IF this note was
-- appended at the very end of the piece (nothing already existed after
-- it). This is deliberately narrow: an insert into the middle of already-
-- composed material closes the popup as normal, since there's no "next
-- note" to usefully chain into there.
--
-- Quick entry (see parse_quick_entry/commit_create/commit_edit): both
-- popups also expose an optional single "string.fret.duration" box, e.g.
-- "8.12.1/8+" for string 8, fret 12, an eighth-note triplet - a
-- D&D-dice-notation-style shortcut typeable entirely from the numeric
-- keypad (only digits, ".", "/", and "+" are needed; "+" stands in for the
-- Duration field's own "T" triplet suffix, since the keypad has no
-- letters). Filling this box in OVERRIDES the three classic fields
-- entirely at commit time, rather than merging with them. In the Create
-- popup it's just a faster way to type the same three values already
-- being entered there. In the Edit popup it additionally powers a new
-- walk-to-next-note advance (see commit_edit/next_note_after): committing
-- an edit jumps straight to the next EXISTING note in time order instead
-- of closing, letting a whole already-composed passage be rapid-fire
-- re-tagged. Either popup's re-arm/advance puts the keyboard cursor back
-- in whichever box - quick entry or Fret - was actually used to commit the
-- note just finished, so a quick-entry run stays a quick-entry run without
-- ever needing to click or Tab back into that box.
--
-- Duration grammar (see parse_duration_input): a plain denominator ("4",
-- "2", "1") or an explicit N/D fraction of a whole note ("3/8" for a
-- dotted quarter, "3/4" for a dotted half) - the N/D form is what actually
-- reaches values a plain denominator alone can't express, not just longer
-- plain notes (a bare "2" or "1" already covered those). A trailing T/t/+
-- triplet-scales the result. Both the Duration field and the Quick entry
-- box's own duration segment accept this same grammar.
--
-- Rests (see parse_rest_input/commit_rest): prefixing EITHER the Duration
-- field or the Quick entry box with "-" (e.g. "-1/4" for a quarter rest)
-- means rest instead of note, since a rest has no fret/string/pitch of its
-- own. In the Create popup this writes nothing at all - it just advances
-- the insertion point by that duration and keeps the SAME popup open
-- unconditionally (nothing was written, so there's nothing to collide
-- with), a general "skip forward" tool for leaving gaps mid-run. In the
-- Edit popup, since there's no "nothing" to turn an existing note INTO, a
-- rest instead DELETES the note being edited (via the shared delete_note
-- helper, same underlying write as the Delete button) and then walks to
-- the next existing note exactly like a normal edit commit does.
--
-- Guitar technique suffixes (see strip_technique_suffix/parse_fret_input):
-- typed right after a fret number - classic Fret field ("12l") or quick
-- entry's own fret segment ("8.12l.1/4") - "l" (legato: hammer-on/pull-
-- off) and "t" (tap) tag the note via midi_read.lua's technique P_EXT map
-- (the same mechanism note_editor.lua's Shamisen popup uses, just with a
-- disjoint guitar id range - see GUITAR_TECHNIQUE_LEGATO/_TAP), since a
-- MIDI text/sysex event was already tried for this exact purpose and
-- abandoned (see midi_read.lua's own header: REAPER silently discarded
-- them). Legato renders as a slur on BOTH staves (draw_notation.lua and
-- draw_tab.lua) - one continuous arc spanning the whole run of
-- consecutively-tagged same-string notes, not a separate small arc per
-- pair; tap renders as a "T" text marker on the tab staff only
-- (draw_tab.lua). "pm" (palm mute) and "ph"
-- (pinch harmonic) are NOT tags at all - draw_tab.lua already auto-
-- detects both from a note's own MIDI velocity, so these two suffixes
-- just pick a velocity inside the matching range instead of the plain
-- default, reusing that already-working detection rather than building a
-- second guitar-technique system. A note carries at most one tag-based
-- technique (legato XOR tap) at a time - the same one-technique-per-note
-- limitation the Shamisen system already has.
--
-- Hover tooltips (draw_create_popup/draw_edit_popup, via
-- reaper.ImGui_IsItemHovered + SetTooltip): both the Quick entry box and
-- the Duration field show the compact grammar above on hover, since
-- neither is fully self-explanatory from its label alone.
--
-- Drag-to-select + mass delete (see begin_frame/check_system/M.end_frame/
-- mass_delete_selected): a press-and-hold that moves far enough
-- (DRAG_SELECT_THRESHOLD) becomes a rubber-band rectangle instead of the
-- ordinary click-to-create/edit gesture - every note whose position falls
-- inside it gets added to selected_notes and a highlight ring (filled tint
-- plus a solid outline, so it reads clearly regardless of the numeral's own
-- color - see SELECTION_MARK_FILL/SELECTION_MARK_BORDER), spanning across a
-- system/line-wrap boundary for free since the rectangle is plain screen
-- coordinates, not tied to any one system. With a selection active and no
-- popup open, deletion is offered two ways: the Delete key
-- (mass_delete_selected, one undo step) or right-clicking anywhere to open
-- a small context menu ("Delete N Notes" / "Move to String..." / "Clear
-- Selection" - see CONTEXT_MENU_POPUP_ID below), for anyone who'd rather
-- click than reach for the keyboard; Escape also clears the selection
-- without deleting anything, and a small status line names how many notes
-- are selected in the meantime. A plain click (a press that never crosses
-- the drag threshold) still behaves exactly as before and always clears
-- whatever was previously selected first - there's no modifier-key
-- add-to-selection mode, out of scope for now.
--
-- "Move to String" (see try_move_selected_to_string/draw_move_popup): the
-- context menu's second option - moves every selected note onto one typed
-- target string, KEEPING EACH NOTE'S OWN PITCH fixed and re-deriving its
-- fret (the opposite of a single-note Edit popup retarget, which keeps
-- FRET fixed - see commit_edit's own comment for why that one's different;
-- here, "move this passage to one string" only makes sense as "keep
-- playing the same pitches, just on a different string"). Validates every
-- selected note BEFORE writing anything and refuses the whole move, with a
-- specific reason, if any one of them can't land there - an out-of-range
-- fret, two selected notes overlapping in time, or a selected note landing
-- on top of an existing note already on that string - rather than partially
-- applying and leaving a harder mess to undo by hand.
--
-- Create write-back: reaper.MIDI_InsertNote(take, selected, muted,
-- startppqpos, endppqpos, chan, pitch, vel, noSortIn) - verified against
-- REAPER's own API docs before use, since this repo had zero existing
-- call sites to copy from (every OTHER edit in this app, including this
-- file's own duration-edit below, is MIDI_SetNote against a known idx).
-- Unlike MIDI_SetNote, an insert hands back no idx for the note it just
-- created - nothing here may read/reuse an idx after the call; the popup
-- closes immediately, and only a fresh midi_read.read_notes next frame
-- could ever identify a newly created note (not needed anywhere in this
-- file). A created note's channel is always the clicked string (an
-- explicit pin), never 0/auto. Delete is the mirror-image: one
-- reaper.MIDI_DeleteNote call against an EXISTING note's already-known
-- idx. Previously documented here as a known limitation: MIDI_InsertNote/
-- MIDI_DeleteNote don't reliably register their own undo state with
-- REAPER's native undo system even with finalize_midi_write's documented
-- workaround applied (confirmed by testing, not just theorized) - Ctrl+Z
-- could silently no-op for create/delete. Rather than continue chasing
-- REAPER's own undo integration, this is now worked around entirely by
-- push_undo_snapshot/do_undo/do_redo's own self-contained undo stack (see
-- its comment, right after finalize_midi_write below) - every Edit Mode
-- write, including a plain fret/duration edit, goes through it now, not
-- just create/delete.

local config = require('config')
local layout_engine = require('layout_engine')
local midi_read = require('midi_read')
local notation_model = require('notation_model')

local M = {}

local HIT_RADIUS = 8 -- px - same value as note_editor.lua's own constant; duplicated rather than shared, see this file's header
local CREATE_POPUP_ID = "tab_editor_create_popup"
local EDIT_POPUP_ID = "tab_editor_edit_popup"
local CONTEXT_MENU_POPUP_ID = "tab_editor_context_menu"
local MOVE_POPUP_ID = "tab_editor_move_popup"
local UNDO_ALL = -1 -- Undo_EndBlock's extraflags: -1 = all undo-state flags, the standard idiom (matches note_editor.lua)
local CLICK_SLACK = 20 -- px - horizontal gate margin past a system's own barline_x range

-- Drag-select overlay colors - a fixed accent (not derived from config.
-- color_fg/bg) same as draw_tab.lua's COLOR_TECHNIQUE/COLOR_UNREACHABLE:
-- a semantic UI marking, not part of the score's own "ink." A selected
-- note gets BOTH a translucent fill (so it still reads as "tinted" even
-- sitting on top of the numeral) and a solid outline ring (AddCircle, not
-- filled - see M.end_frame) - fill alone proved too easy to miss against a
-- busy tab staff, especially where the numeral's own color is close to the
-- fill color.
local SELECTION_MARK_FILL = 0x40C0FF60 -- translucent tint drawn over a selected note's numeral
local SELECTION_MARK_BORDER = 0x40C0FFFF -- solid ring outlining a selected note, unmistakable regardless of the numeral's own color
local SELECTION_MARK_RADIUS = 10 -- px
local SELECTION_RECT_FILL = 0x4090FF30 -- faint fill while a drag is in progress
local SELECTION_RECT_BORDER = 0x4090FFFF -- solid border while a drag is in progress
local SELECTION_HUD_COLOR = 0xFFFFFFFF -- "N notes selected" status text

-- Hover-tooltip text for the Tab Code/Duration fields (see
-- reaper.ImGui_IsItemHovered/SetTooltip call sites in draw_create_popup/
-- draw_edit_popup) - the compact grammar isn't self-explanatory from the
-- field label alone, so this spells it out on demand rather than
-- cluttering the popup itself. Create and Edit each get their own wording
-- for what a rest actually does there (skip forward vs delete - see
-- commit_create/commit_edit).
local FRET_TECHNIQUE_HELP =
  "  l   legato (hammer-on/pull-off) - drawn as a slur\n" ..
  "  t   tap - drawn as a text marker\n" ..
  "  lt  legato + tap together\n" ..
  "  pm  palm mute - written at a muted velocity\n" ..
  "  ph  pinch harmonic - written at max velocity"
-- Shamisen's tsubo (fret/position) labels aren't consecutive integers -
-- see notation_model.display_fret_label/parse_fret_label's header for the
-- full mapping. Appended to the Fret/Tab Code tooltips below, only when
-- config.instrument == "Shamisen", so Guitar's tooltips are unchanged.
local SHAMISEN_FRET_LABEL_HELP =
  "Shamisen fret labels: 0,1,2,3,#,4,5,6,7,8,9,b,10,11,12,13,1#,14,...\n" ..
  "(each octave's 2 half-tone positions are marked #/b, not a number)."

local QUICK_ENTRY_TOOLTIP_CREATE_BASE =
  "Tab Code: string.fret.duration\n" ..
  "e.g. 8.12.1/8+ = string 8, fret 12, eighth-note triplet\n" ..
  "e.g. 8.12l.1/4 = string 8, fret 12, quarter note, legato\n\n" ..
  "Fret technique suffix (optional, right after the number):\n" ..
  FRET_TECHNIQUE_HELP .. "\n\n" ..
  "Duration accepts:\n" ..
  "  N or N/D   4 or 1/4 (quarter), 2 (half), 3/8 (dotted quarter)\n" ..
  "  ...T/...+  triplet-scaled, e.g. 8T or 8+ (eighth-note triplet)\n" ..
  "  -N/D       rest instead of a note, e.g. -1/4 (skips forward,\n" ..
  "             writes nothing)\n\n" ..
  "Overrides the String/Fret/Duration fields below when filled in."
local QUICK_ENTRY_TOOLTIP_EDIT_BASE =
  "Tab Code: string.fret.duration\n" ..
  "e.g. 8.12.1/8+ = string 8, fret 12, eighth-note triplet\n" ..
  "e.g. 8.12l.1/4 = string 8, fret 12, quarter note, legato\n\n" ..
  "Fret technique suffix (optional, right after the number):\n" ..
  FRET_TECHNIQUE_HELP .. "\n\n" ..
  "Duration accepts:\n" ..
  "  N or N/D   4 or 1/4 (quarter), 2 (half), 3/8 (dotted quarter)\n" ..
  "  ...T/...+  triplet-scaled, e.g. 8T or 8+ (eighth-note triplet)\n" ..
  "  -N/D       rest instead - DELETES this note, e.g. -1/4\n\n" ..
  "Overrides the String/Fret/Duration fields below when filled in."
local DURATION_TOOLTIP_CREATE =
  "N or N/D, e.g. 4, 1/4, 2, 3/8 (dotted quarter)\n" ..
  "Add T or + for a triplet, e.g. 8T\n" ..
  "Prefix with - for a rest, e.g. -1/4 (skips forward, writes nothing)"
local DURATION_TOOLTIP_EDIT =
  "N or N/D, e.g. 4, 1/4, 2, 3/8 (dotted quarter)\n" ..
  "Add T or + for a triplet, e.g. 8T\n" ..
  "Prefix with - for a rest, e.g. -1/4 (DELETES this note)"
local FRET_TOOLTIP_BASE =
  "Optional technique suffix, right after the number:\n" .. FRET_TECHNIQUE_HELP

-- config.instrument can change at runtime (the Instrument dropdown), so
-- these three are computed at draw time rather than fixed module-load
-- constants like the others above - each just prepends SHAMISEN_FRET_
-- LABEL_HELP when appropriate.
local function fret_tooltip()
  if config.instrument == "Shamisen" then
    return SHAMISEN_FRET_LABEL_HELP .. "\n\n" .. FRET_TOOLTIP_BASE
  end
  return FRET_TOOLTIP_BASE
end
local function quick_entry_tooltip_create()
  if config.instrument == "Shamisen" then
    return SHAMISEN_FRET_LABEL_HELP .. "\n\n" .. QUICK_ENTRY_TOOLTIP_CREATE_BASE
  end
  return QUICK_ENTRY_TOOLTIP_CREATE_BASE
end
local function quick_entry_tooltip_edit()
  if config.instrument == "Shamisen" then
    return SHAMISEN_FRET_LABEL_HELP .. "\n\n" .. QUICK_ENTRY_TOOLTIP_EDIT_BASE
  end
  return QUICK_ENTRY_TOOLTIP_EDIT_BASE
end

local function round(v)
  return math.floor(v + 0.5)
end

-- Guitar technique suffixes, typed directly after a fret number (e.g.
-- "12l" for a legato-flagged fret 12, "8.12.1/4" -> "8.12l.1/4" in Tab
-- Code) - see parse_fret_input below for where these get stripped off.
--
-- "l" (legato: hammer-on/pull-off), "t" (tap), and "lt" (both at once) are
-- stored as an explicit per-note tag, reusing midi_read.lua's existing
-- technique P_EXT map - the SAME mechanism note_editor.lua's Shamisen
-- technique popup already uses (see that file's own header for why this
-- isn't a MIDI event: MIDI_InsertTextSysexEvt was tried first and REAPER
-- silently discarded the events on read-back). GUITAR_TECHNIQUE_LEGATO/
-- _TAP/_LEGATO_TAP use their own id range (101+), disjoint from note_
-- editor.lua's Shamisen ids (1-6), so the two systems never collide if a
-- take's instrument is ever changed. Legato renders as a slur (notation_
-- model/draw_notation.lua, draw_tab.lua); Tap renders as a "T" text marker
-- on the tab staff (draw_tab.lua), mirroring its existing Pinch Harmonic
-- marker - "lt" draws BOTH at once (layout_engine.lua/draw_tab.lua's own
-- is_legato_technique-style checks treat GUITAR_TECHNIQUE_LEGATO_TAP as
-- carrying each component). Legato+tap is the one combination this app
-- supports; every other technique suffix remains mutually exclusive with
-- the others (tagging a note "pm" after it was "l" still replaces the
-- legato tag rather than combining with it) - a real, deliberately narrow
-- scope, not a general multi-technique system.
--
-- "pm" (palm mute) and "ph" (pinch harmonic) are NOT stored as tags at
-- all - draw_tab.lua already auto-detects both directly from a note's own
-- recorded MIDI velocity (see that file's own header: 1-63 = palm mute,
-- 127 = pinch harmonic), a heuristic that happens to already match
-- Ample Sound Hellrazer's own velocity-driven "Sustain & Pop" convention.
-- Typing "pm"/"ph" here just writes the note at a velocity inside the
-- matching range instead of the plain default, reusing that already-
-- working detection/rendering rather than building a second system.
local GUITAR_TECHNIQUE_LEGATO = 101
local GUITAR_TECHNIQUE_TAP = 102
local GUITAR_TECHNIQUE_LEGATO_TAP = 103
-- Write-side velocity chosen for each - anywhere inside draw_tab.lua's own
-- detection range works, these are just reasonable defaults within it.
local PALM_MUTE_WRITE_VELOCITY = 40
local PINCH_HARMONIC_WRITE_VELOCITY = 127
-- Read-side detection thresholds, copied EXACTLY from draw_tab.lua's own
-- PALM_MUTE_VELOCITY_MAX/PINCH_HARMONIC_VELOCITY (note.vel >= 1 and <= 63
-- for palm mute, note.vel == 127 for pinch harmonic) - used only to seed a
-- popup field with the right suffix when re-opening Edit on an
-- already-tagged note; kept as separate constants (not shared with
-- draw_tab.lua) since these two files don't otherwise depend on each
-- other, matching this codebase's existing note_editor.lua/draw_tab.lua
-- TECHNIQUE_SYMBOLS precedent of duplicated-but-commented-in-sync tables
-- rather than a new shared-constants module.
local PALM_MUTE_VELOCITY_MAX = 63
local PINCH_HARMONIC_VELOCITY = 127

-- Strips a trailing technique suffix (case-insensitive "l", "t", "lt",
-- "pm", or "ph") off typed fret text, returning the plain numeric text
-- plus whichever of technique_id/velocity_override applies (at most one is
-- ever non-nil). The three two-character suffixes ("pm", "ph", "lt") are
-- checked FIRST, before the single-character "l"/"t" - "lt" itself ends in
-- "t", so checking the single-character cases first would misread it as a
-- bare tap suffix and leave a stray "l" glued onto the fret number.
local function strip_technique_suffix(text)
  local lower = text:lower()
  if lower:sub(-2) == "pm" then return text:sub(1, -3), nil, PALM_MUTE_WRITE_VELOCITY end
  if lower:sub(-2) == "ph" then return text:sub(1, -3), nil, PINCH_HARMONIC_WRITE_VELOCITY end
  if lower:sub(-2) == "lt" then return text:sub(1, -3), GUITAR_TECHNIQUE_LEGATO_TAP, nil end
  if lower:sub(-1) == "l" then return text:sub(1, -2), GUITAR_TECHNIQUE_LEGATO, nil end
  if lower:sub(-1) == "t" then return text:sub(1, -2), GUITAR_TECHNIQUE_TAP, nil end
  return text, nil, nil
end

-- Parses a typed Fret field (classic or quick-entry's first segment) into
-- fret, technique_id, velocity_override - or nil on an invalid number.
-- Range-checking (0..config.max_fret) is the caller's job, same division
-- of labor parse_string_index/parse_duration_input already use. The
-- numeric text (after suffix-stripping) goes through notation_model.
-- parse_fret_label rather than a bare tonumber, since Shamisen's tsubo
-- labels aren't consecutive integers ("#", "1b", etc. - see that
-- function's header); it falls back to plain tonumber for Guitar, so
-- Guitar entry is completely unaffected.
local function parse_fret_input(buf)
  local trimmed = (buf or ""):match("^%s*(.-)%s*$")
  local numeric_text, technique_id, velocity_override = strip_technique_suffix(trimmed)
  local fret = notation_model.parse_fret_label(config, numeric_text)
  if not fret then return nil end
  return fret, technique_id, velocity_override
end

-- Formats a fret number back into typed text for seeding a popup field,
-- appending whichever technique suffix this note currently carries (if
-- any) - the round-trip counterpart to parse_fret_input/
-- strip_technique_suffix, so re-opening Edit on an already-tagged note
-- shows e.g. "12l" instead of a bare "12" that would silently drop the
-- tag if left untouched and re-committed. notation_model.display_fret_
-- label (not a bare tostring) so a reopened Shamisen note shows its tsubo
-- label ("1#", "10", ...) instead of the raw semitone fret number.
local function format_fret_with_technique(fret, technique_id, vel)
  local suffix = ""
  if technique_id == GUITAR_TECHNIQUE_LEGATO_TAP then
    suffix = "lt"
  elseif technique_id == GUITAR_TECHNIQUE_LEGATO then
    suffix = "l"
  elseif technique_id == GUITAR_TECHNIQUE_TAP then
    suffix = "t"
  elseif vel and vel >= 1 and vel <= PALM_MUTE_VELOCITY_MAX then
    suffix = "pm"
  elseif vel and vel >= PINCH_HARMONIC_VELOCITY then
    suffix = "ph"
  end
  return notation_model.display_fret_label(config, fret) .. suffix
end

-- Denominator (as typed, e.g. 4 for a quarter note) <-> ticks. Same
-- formula config.layout.duration_classes' own values already imply
-- (240=1/16, 480=1/8, 960=1/4, 1920=1/2, 3840=1/1) - not a new convention,
-- just exposed as a typed field. denominator_for_ticks is best-effort
-- display/default only (rounds to the nearest whole denominator) - a
-- note's real ticks don't have to land on a clean value (e.g. one hand-
-- edited in REAPER's own piano roll), and this never needs to round-trip
-- exactly, only to seed a sensible starting guess in a duration field.
local function ticks_for_denominator(d)
  return round(4 * config.layout.ppq_per_quarter / d)
end

-- Triplet-scaled duration input, e.g. "8T" for an eighth-note triplet -
-- same "T" suffix REAPER's own grid-snap dropdown already uses for its
-- "1/8T" etc. divisions, reused deliberately so this matches something the
-- user already knows rather than inventing a new notation. A plain
-- denominator's ticks (ticks_for_denominator) is a NOTATED value; a
-- triplet note's real MIDI span is 2/3 of that (3 notes occupy the space 2
-- normally would) - e.g. "8T" = 480 * 2/3 = 320 ticks, matching
-- notation_model.TUPLET_SHAPES' own eighth-triplet shape exactly, so notes
-- typed this way are placed evenly enough to actually be recognized as a
-- tuplet by the notation view, not just visually close. Before this
-- existed, typing a plain "3" (meaning a literal third-note, 1280 ticks -
-- a real but different, much longer value already part of the plain
-- denominator convention) was the only way to attempt a triplet note,
-- silently created a wildly oversized note, and made the NEXT note's
-- placement spuriously collide with it.
local function ticks_for_triplet_denominator(d)
  return round(ticks_for_denominator(d) * 2 / 3)
end

local DURATION_MATCH_TOLERANCE = 10 -- ticks - matches layout_engine.lua's TIE_DURATION_TOLERANCE

-- Formats ticks back into a duration string for seeding a popup's default
-- (see M.end_frame). A genuine triplet duration (e.g. 320 ticks) also
-- happens to land exactly on a clean plain denominator too (320 = a
-- literal twelfth note, "12"), so this can't just pick whichever fit is
-- within tolerance - both regularly are. Instead it computes BOTH fits and
-- takes whichever lands CLOSER to the actual ticks (triplet wins a tie),
-- only accepting the triplet fit at all if it's within tolerance. Without
-- the closer-wins comparison, a plain value that merely happens to sit
-- near some triplet denominator's own rounded value (e.g. a plain 1/16
-- note, 240 ticks, sits only 7 ticks from triplet-11's 233) would
-- misreport as a triplet even though the plain fit is exact - silently
-- reseeding the Duration field with a shorter value than the note actually
-- has the moment its Edit popup opens (caught via user testing: adding a
-- technique suffix to a note's Fret field, with Duration untouched, was
-- shortening the note on commit).
local function denominator_for_ticks(ticks)
  if not ticks or ticks <= 0 then return "4" end
  local whole_note_ticks = 4 * config.layout.ppq_per_quarter

  local plain_denom = math.max(1, round(whole_note_ticks / ticks))
  local plain_diff = math.abs(ticks_for_denominator(plain_denom) - ticks)

  local plain_equivalent = ticks * 3 / 2
  local triplet_denom = round(whole_note_ticks / plain_equivalent)
  local triplet_diff = triplet_denom > 0 and math.abs(ticks_for_triplet_denominator(triplet_denom) - ticks) or nil

  if triplet_diff and triplet_diff <= DURATION_MATCH_TOLERANCE and triplet_diff <= plain_diff then
    return tostring(triplet_denom) .. "T"
  end
  return tostring(plain_denom)
end

-- Parses a duration field's typed text into real ticks, or nil if it's not
-- a valid duration. Accepts the plain denominator convention ("4", "8T") or
-- an explicit N/D fraction of a whole note - not just the "1/N" shape a
-- bare denominator already implies, but any numerator ("3/8" for a dotted
-- quarter, "3/4" for a dotted half, etc.), which is what actually lets a
-- typed duration reach values a plain denominator alone cannot express. A
-- trailing T/t/+ means triplet-scaled (2/3 of whatever the rest of the
-- text resolved to) - "+" is an additional alias for "T", accepted for the
-- numpad-only quick-entry box below, which has no letters to type "T"
-- with.
local function parse_duration_input(buf)
  local trimmed = (buf or ""):match("^%s*(.-)%s*$")
  local is_triplet = false
  local numeric_part = trimmed
  local last_char = trimmed:sub(-1)
  if last_char == "t" or last_char == "T" or last_char == "+" then
    is_triplet = true
    numeric_part = trimmed:sub(1, -2)
  end

  local whole_note_ticks = 4 * config.layout.ppq_per_quarter
  local plain_ticks
  local num_s, den_s = numeric_part:match("^(%d+)/(%d+)$")
  if num_s then
    local num, den = tonumber(num_s), tonumber(den_s)
    if not num or num <= 0 or not den or den <= 0 then return nil end
    plain_ticks = round(whole_note_ticks * num / den)
  else
    local denom = tonumber(numeric_part)
    if not denom or denom <= 0 then return nil end
    plain_ticks = round(whole_note_ticks / round(denom))
  end
  if plain_ticks <= 0 then return nil end

  if is_triplet then
    return round(plain_ticks * 2 / 3)
  end
  return plain_ticks
end

-- Parses a string-number field's typed text into a validated INTERNAL
-- string index (1..#config.tuning), or nil if it's missing/out of range.
-- What's actually TYPED is the instrument-appropriate DISPLAY number (see
-- notation_model.display_string_number) - Shamisen's lowest string is
-- typed as "1", not this app's own internal index for it - so the range
-- check validates the typed value as-is (1..n either way) and only the
-- RETURNED value gets converted to the internal index everything else in
-- this file (config.tuning[...], MIDI_InsertNote/SetNote's channel param)
-- expects. Both parse_quick_entry and each popup's own "String" field
-- funnel through this one function, so the numbering fix only has to
-- happen here. Shared by both popups' commit functions - each one still
-- reports its own status message on failure, so this only does the
-- parse/range-check/convert, not the messaging.
local function parse_string_index(buf)
  local s = tonumber(buf)
  if not s then return nil end
  s = round(s)
  if s < 1 or s > #config.tuning then return nil end
  return notation_model.display_string_number(config, s)
end

-- Optional compact "string.fret.duration" entry, e.g. "8.12.1/8+" for
-- string 8, fret 12, an eighth-note triplet, or "8.12l.1/8+" for the same
-- note legato-flagged - a D&D-dice-notation-style shortcut typeable
-- entirely from the numeric keypad plus letters for the fret's own
-- technique suffix (digits, ".", "/", "+", and one of l/t/lt/pm/ph - see
-- strip_technique_suffix; "t" here means TAP on the fret segment, NOT
-- triplet - that's parse_duration_input's own trailing "t" on the
-- DURATION segment, a different field, so the two never collide).
-- String-then-fret (not fret-then-string) matches how a guitarist actually
-- locates a note - pick the string first, then the fret on it - the same
-- reasoning behind the Fret/String field order below. Returns fret,
-- string_idx, duration_ticks, technique_id, velocity_override on success,
-- or nil, nil, nil, nil, nil, error_message on any parse failure - reuses
-- parse_string_index/parse_duration_input/parse_fret_input rather than
-- re-implementing their validation, so this box always accepts exactly
-- what the separate String/Fret/Duration fields do. Return ORDER stays
-- fret-then-string regardless of the input text's own order - every
-- caller (commit_create/commit_edit) already destructures it that way, and
-- there's no reason to entangle this function's return shape with the
-- typed text's own segment order.
local function parse_quick_entry(buf)
  local trimmed = (buf or ""):match("^%s*(.-)%s*$")
  local string_s, fret_s, duration_s = trimmed:match("^([^.]+)%.([^.]+)%.([^.]+)$")
  if not string_s then
    return nil, nil, nil, nil, nil, "Tab Code must be string.fret.duration (e.g. 8.12.1/8+)."
  end

  local string_idx = parse_string_index(string_s)
  if not string_idx then
    return nil, nil, nil, nil, nil, string.format("String must be between 1 and %d.", #config.tuning)
  end

  local fret, technique_id, velocity_override = parse_fret_input(fret_s)
  if not fret then return nil, nil, nil, nil, nil, "Enter a valid fret number." end
  if fret < 0 or fret > config.max_fret then
    return nil, nil, nil, nil, nil, string.format(
      "Fret must be between 0 and %s.", notation_model.display_fret_label(config, config.max_fret))
  end

  local duration_ticks = parse_duration_input(duration_s)
  if not duration_ticks then
    return nil, nil, nil, nil, nil, "Enter a valid duration (e.g. 1/8, or 1/8+ for a triplet)."
  end

  return fret, string_idx, duration_ticks, technique_id, velocity_override, nil
end

-- A duration field or quick-entry box starting with "-" (e.g. "-1/4" for a
-- quarter rest, "-4" the same via the bare-denominator form) means REST
-- rather than a note - see commit_create/commit_edit's own comments for
-- what that means in each popup (skip forward without writing anything, or
-- delete the note being edited). Returns the rest's length in ticks, or
-- nil if buf isn't rest-shaped/valid - the remainder after the "-" is
-- whatever parse_duration_input already accepts, so a rest supports the
-- exact same N/D/triplet grammar a note's duration does.
local function parse_rest_input(buf)
  local trimmed = (buf or ""):match("^%s*(.-)%s*$")
  if trimmed:sub(1, 1) ~= "-" then return nil end
  return parse_duration_input(trimmed:sub(2))
end

-- MIDI_InsertNote/MIDI_DeleteNote have a known REAPER API gap: unlike
-- MIDI_SetNote (which note_editor.lua's edits rely on and have undone
-- reliably all along), an insert/delete doesn't reliably register its own
-- undo state just from being wrapped in Undo_BeginBlock/EndBlock -
-- Ctrl+Z can silently no-op. This is the documented workaround other
-- REAPER scripters have published for the same problem (MIDI_Sort to
-- finalize the take's internal state, then UpdateItemInProject +
-- MarkTrackItemsDirty to nudge REAPER's undo system) - applied here since
-- it's a real, harmless mitigation, but tested against this app's actual
-- Edit Mode create/delete flow and CONFIRMED NOT SUFFICIENT ON ITS OWN -
-- Ctrl+Z still doesn't reliably undo an insert/delete even with this in
-- place. Left in rather than reverted since it's still correct per
-- REAPER's own guidance and may be doing some of the work, but this is a
-- known, unresolved limitation of Edit Mode's create/delete - not
-- something to trust as fixed. Root cause not yet identified; see the
-- project's own memory notes for what's been ruled out so far.
-- Editing an existing note (commit_edit, below) deliberately does NOT use
-- this - it goes through MIDI_SetNote instead, which doesn't have this
-- gap.
local function finalize_midi_write(take)
  reaper.MIDI_Sort(take)
  local item = reaper.GetMediaItemTake_Item(take)
  reaper.UpdateItemInProject(item)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), item)
end

-- Self-contained undo/redo for every Edit Mode write (create, delete, mass
-- delete, fret/string/duration edit, technique tag) - built because
-- REAPER's own native item undo, wrapped by Undo_BeginBlock/Undo_EndBlock
-- plus finalize_midi_write's own documented workaround, was CONFIRMED (by
-- testing, not just theorized - see this file's header) to not reliably
-- register MIDI_InsertNote/MIDI_DeleteNote as an undoable state at all;
-- Ctrl+Z could silently no-op for create/delete. Rather than continue
-- chasing why REAPER's native undo won't pick these two calls up, every
-- Edit Mode write now ALSO pushes a full snapshot of the take's raw MIDI
-- stream (MIDI_GetAllEvts) plus its technique P_EXT string onto our own
-- stack BEFORE the write happens, and Ctrl+Z/Ctrl+Shift+Z (M.end_frame)
-- restore from that stack directly (MIDI_SetAllEvts) instead of relying on
-- REAPER's own undo history for these edits at all. A full raw-stream
-- snapshot, rather than replaying individual Insert/Delete/SetNote calls
-- in reverse, is authoritative - restoring it reconstructs the take
-- exactly as it was, note ordering/idx included - and it's the same
-- mechanism regardless of which kind of edit is being undone, so a
-- create, a delete, a mass delete, and a fret/duration edit all undo
-- through the one consistent path (this also means Ctrl+Z always reverts
-- the MOST RECENT Edit Mode action regardless of which kind it was,
-- rather than two separate, potentially-out-of-order timelines).
--
-- Deliberately still wraps each actual write in Undo_BeginBlock/Undo_
-- EndBlock too (unchanged) - REAPER's own Undo History list still shows
-- something for these edits, and MIDI_SetNote-based edits (fret/string/
-- duration) already register correctly there on their own; this stack is
-- what GUARANTEES Ctrl+Z works from inside this window regardless.
--
-- Gated to only handle Ctrl+Z/Ctrl+Shift+Z while no popup is open (see
-- M.end_frame) so a focused Duration/Fret text field's own built-in
-- text-edit undo (Dear ImGui's InputText has its own Ctrl+Z for in-
-- progress typing) isn't shadowed by this.
local UNDO_STACK_LIMIT = 50 -- cap on retained snapshots, so a long editing session doesn't grow this unboundedly
local undo_stack = {} -- ordered oldest -> newest; each entry = { take, events, tech }
local redo_stack = {} -- cleared by push_undo_snapshot (a fresh edit invalidates old redo history, standard convention)

-- Call BEFORE any Edit Mode write that changes note data or a technique
-- tag - captures take's CURRENT (pre-edit) state so Ctrl+Z can restore it.
local function push_undo_snapshot(take)
  local ok, events = reaper.MIDI_GetAllEvts(take, "")
  if not ok then return end
  local _, tech = reaper.GetSetMediaItemTakeInfo_String(take, midi_read.TECH_EXT_KEY, "", false)
  undo_stack[#undo_stack + 1] = { take = take, events = events, tech = tech }
  if #undo_stack > UNDO_STACK_LIMIT then
    table.remove(undo_stack, 1)
  end
  redo_stack = {}
end

-- Pops one snapshot off pop_from, restores it, and pushes the state it
-- just OVERWROTE onto push_to - shared by do_undo/do_redo below, which are
-- exact mirror images of each other (undo moves undo_stack -> redo_stack,
-- redo moves redo_stack -> undo_stack).
local function swap_snapshot(pop_from, push_to, undo_desc)
  if #pop_from == 0 then return end
  local snap = table.remove(pop_from)

  local ok, current_events = reaper.MIDI_GetAllEvts(snap.take, "")
  if ok then
    local _, current_tech = reaper.GetSetMediaItemTakeInfo_String(snap.take, midi_read.TECH_EXT_KEY, "", false)
    push_to[#push_to + 1] = { take = snap.take, events = current_events, tech = current_tech }
  end

  reaper.Undo_BeginBlock()
  reaper.MIDI_SetAllEvts(snap.take, snap.events)
  reaper.GetSetMediaItemTakeInfo_String(snap.take, midi_read.TECH_EXT_KEY, snap.tech or "", true)
  finalize_midi_write(snap.take)
  reaper.Undo_EndBlock(undo_desc, UNDO_ALL)
  technique_changed = true
end

local function do_undo()
  swap_snapshot(undo_stack, redo_stack, "Undo (tab/notation viewer)")
end

local function do_redo()
  swap_snapshot(redo_stack, undo_stack, "Redo (tab/notation viewer)")
end

-- Sets (technique_id given) or clears (nil) a note's guitar-technique tag
-- (GUITAR_TECHNIQUE_LEGATO/_TAP) in the take's shared technique P_EXT map
-- (midi_read.lua) - the exact same read-whole-map/patch-one-key/write-
-- whole-map-back pattern note_editor.lua's own commit_technique uses,
-- since P_EXT only holds one string per key per take, not a per-note slot.
-- old_key (optional) additionally clears a DIFFERENT, previous key first -
-- needed because commit_edit can change a note's string/fret (and so its
-- chan/pitch, which are part of the map's key) in the SAME commit that
-- changes its technique tag; without this, retagging a note's string
-- would leave a stale entry behind at its old chan/pitch instead of
-- moving with it.
-- This note's current guitar-technique id (GUITAR_TECHNIQUE_LEGATO/_TAP),
-- or nil - used to seed a popup field when walking to the next note (see
-- commit_edit) so its own existing tag round-trips into the Fret field's
-- text instead of silently vanishing the moment that note is re-committed.
local function note_technique(take, note)
  local map = midi_read.read_technique_map(take)
  return map[note.startppq .. ":" .. note.chan .. ":" .. note.pitch]
end

local function write_note_technique(take, startppq, chan, pitch, technique_id, old_key)
  local map = midi_read.read_technique_map(take)
  if old_key then map[old_key] = nil end
  local key = startppq .. ":" .. chan .. ":" .. pitch
  map[key] = technique_id
  reaper.GetSetMediaItemTakeInfo_String(take, midi_read.TECH_EXT_KEY, midi_read.serialize_technique_map(map), true)
end

-- Set whenever a commit changes only the take's technique P_EXT map (not
-- the MIDI note data itself) - read (and reset) by M.end_frame's return
-- value, this module's own "please recompute" signal, since a P_EXT
-- change is invisible to midi_read.get_notes_hash (see that file's
-- header). Mirrors note_editor.lua's own technique_changed exactly - see
-- its header for why a hash check alone can't notice this.
local technique_changed = false

-- Per-frame click state (begin_frame..end_frame), mirroring note_editor.
-- lua's own triplet convention - mouse polling is not centralized in this
-- app, each module polls independently.
local mouse_x, mouse_y, clicked = 0, 0, false
local best_existing = nil -- { note, dist } - closest existing-note hit within HIT_RADIUS across every system checked this frame
local best_empty = nil -- { tick, string_idx } - the empty grid cell hit for whichever system's gates passed this frame

-- Drag-to-select state (begin_frame..end_frame, mirroring the click state
-- above) - a press-and-hold that moves far enough becomes a rubber-band
-- selection instead of the ordinary click-to-create/edit gesture; a press
-- that never moves past DRAG_SELECT_THRESHOLD still resolves as a normal
-- click on release, exactly as before. See begin_frame/check_system/
-- mass_delete_selected below for the full mechanism.
local DRAG_SELECT_THRESHOLD = 4 -- px of movement before a press-and-hold counts as a drag, not a click
local drag_active = false -- true from mouse-down until release, regardless of whether it turns out to be a click or a drag
local drag_is_selecting = false -- true once movement has exceeded DRAG_SELECT_THRESHOLD this press - a genuine drag
local drag_start_x, drag_start_y = 0, 0
local drag_finished = false -- true for exactly the frame a drag-select gesture is released - check_system's cue to rectangle-hit-test against every system
local selected_notes = {} -- key ("startppq:chan:pitch", same convention as the technique P_EXT map) -> true; drag-selected notes pending mass delete
local selected_marks = {} -- rebuilt fresh every frame in check_system: { {x, y}, ... } screen positions of every currently-selected note actually on screen this frame, for end_frame to draw a highlight over

local target_take = nil
local collision_events = nil -- assigned_events, for the raw-span occupancy/collision checks - see header

local pending_create = nil -- { tick, string_idx } - what the open create popup is placing; string_idx here is only the INITIAL seed for create_string_buf, not the write's source of truth (see commit_create)
local pending_edit = nil -- { note } - what the open edit popup is changing/would remove
local fret_input_buf = ""
local create_string_buf = "1"
local create_duration_buf = "4"
local create_quick_buf = ""
local edit_string_buf = "1"
local edit_fret_buf = "0"
local edit_duration_buf = "4"
local edit_quick_buf = ""
local focus_fret_input = false
local focus_edit_fret_input = false
local focus_create_quick_input = false
local focus_edit_quick_input = false
local create_status = nil
local edit_status = nil
local popup_was_open = false

-- "Move to String" popup (see try_move_selected_to_string) - opened from
-- the right-click context menu on an active selection (see M.end_frame).
local open_move_popup = false -- set inside the context menu's own BeginPopup/EndPopup, consumed right after - see M.end_frame for why this can't just call OpenPopup directly from in there
local move_string_buf = "1"
local move_status = nil
local focus_move_input = false

-- Call once per frame before checking any system, right before the loop
-- that draws each system's tab staff. assigned_events is main.lua's
-- cached_assigned_events (fret_heuristic.assign_events' output) - needed
-- for the collision checks' raw note spans, not the render model.
--
-- click-vs-drag is decided here, once per frame, rather than firing
-- "clicked" straight off the initial press the way this used to: a press
-- might still turn into a drag-select a few frames later, and the old
-- fire-on-press behavior would have already opened a create/edit popup by
-- then. Instead a fresh press just records where it started
-- (drag_start_x/y) and clears any previous selection (a new interaction
-- always supersedes the old one - there's no modifier-key add-to-selection
-- mode, out of scope for now); "clicked" only becomes true on RELEASE, and
-- only if the press never crossed DRAG_SELECT_THRESHOLD - otherwise
-- drag_finished becomes true instead, for check_system's own rectangle
-- hit-test.
function M.begin_frame(ctx, take, assigned_events)
  target_take = take
  collision_events = assigned_events
  mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)

  if (not popup_was_open) and reaper.ImGui_IsMouseClicked(ctx, 0) then
    drag_active = true
    drag_is_selecting = false
    drag_start_x, drag_start_y = mouse_x, mouse_y
    selected_notes = {}
  end

  if drag_active and not drag_is_selecting and reaper.ImGui_IsMouseDown(ctx, 0) then
    local dx, dy = mouse_x - drag_start_x, mouse_y - drag_start_y
    if (dx * dx + dy * dy) >= DRAG_SELECT_THRESHOLD * DRAG_SELECT_THRESHOLD then
      drag_is_selecting = true
    end
  end

  local released_this_frame = drag_active and reaper.ImGui_IsMouseReleased(ctx, 0)
  drag_finished = released_this_frame and drag_is_selecting
  clicked = released_this_frame and not drag_is_selecting
  if released_this_frame then
    drag_active = false
  end

  best_existing = nil
  best_empty = nil
  selected_marks = {}
end

local x_for_tick_in_system = layout_engine.x_for_tick_in_system

-- Where a click is allowed to create the NEXT note, across the WHOLE
-- piece (collision_events, not just this system) - Edit Mode enforces one
-- sequential timeline rather than letting a click land anywhere: skipping
-- ahead mid-measure would leave an unaccounted-for gap that only reads as
-- silence because notation_model.detect_rests happens to fill it in -
-- exactly the kind of accidental multi-voice-looking gap that function
-- had to be hardened against once already (see its own header on the
-- running-latest-end fix). Returns:
--   last_tick - the temporally LAST existing event's own tick (nil if the
--     take has no notes at all) - clicking an unused string here adds a
--     note to the chord you just placed, not a new event.
--   seq_end - the latest endppq among EVERY note in the take (nil if
--     none) - the position immediately after everything placed so far,
--     the natural "next" slot once the current chord is done.
local function sequence_frontier()
  local n = #collision_events
  if n == 0 then return nil, nil end
  local last_tick = collision_events[n].tick
  local seq_end = nil
  for i = 1, n do
    local notes = collision_events[i].notes
    for j = 1, #notes do
      if not seq_end or notes[j].endppq > seq_end then seq_end = notes[j].endppq end
    end
  end
  return last_tick, seq_end
end

-- True if string_idx already has a note in the temporally-last event -
-- gates whether sequence_frontier's last_tick is actually usable as a
-- create target for THIS string, or whether that chord already used it.
local function last_event_uses_string(string_idx)
  local n = #collision_events
  if n == 0 then return false end
  local notes = collision_events[n].notes
  for j = 1, #notes do
    if notes[j].string == string_idx then return true end
  end
  return false
end

-- The one valid tick a click on string_idx is allowed to create at within
-- this system, or nil if none apply here (e.g. this whole system falls
-- before the sequence frontier - already-composed material a click can no
-- longer append to). Candidates: the current chord's own tick (last_tick,
-- only if string_idx is free there - lets a second click add a note to
-- the chord you just placed), the sequence frontier itself (seq_end -
-- always the "next slot" once the current chord is done), and every
-- measure boundary at or past the frontier (system.ticks) - the explicit
-- exception for starting fresh at the top of a later measure, skipping
-- any silence in between (detect_rests fills that in as ordinary rests,
-- same as any other gap). No notes anywhere yet (seq_end nil) makes every
-- boundary in the piece a valid start, covering the very first click on
-- an empty take. Ties broken by whichever candidate the click landed
-- closest to, in pixels.
local function next_create_tick(system, click_x_local, string_idx)
  local last_tick, seq_end = sequence_frontier()

  local candidates = {}
  if last_tick and not last_event_uses_string(string_idx) then
    candidates[#candidates + 1] = last_tick
  end
  if seq_end then
    candidates[#candidates + 1] = seq_end
  end
  for _, b in ipairs(system.ticks) do
    if (not seq_end) or b >= seq_end then
      candidates[#candidates + 1] = b
    end
  end

  if #candidates == 0 then return nil end

  local best_tick, best_dist = nil, nil
  for _, t in ipairs(candidates) do
    local d = math.abs(x_for_tick_in_system(system, t) - click_x_local)
    if not best_dist or d < best_dist then
      best_dist = d
      best_tick = t
    end
  end
  return best_tick
end

-- Pure predicate - true if the CURRENT mouse position (this frame's
-- mouse_x/mouse_y, captured in begin_frame regardless of click state) would
-- match either of check_system's own hit-tests (existing-note radius or
-- empty-grid-cell) for this system. Lets main.lua's grid_overlay.lua click-
-- to-seek check "is there something to edit right here" without waiting for
-- check_system's own click/drag-vs-click timing: that only resolves - and
-- only updates best_existing/best_empty - on the RELEASE frame of a
-- completed non-drag click (see M.begin_frame's header), which is too late
-- for a seek that has to make its own call on the PRESS frame. Since both
-- hit-tests are pure functions of mouse position, re-running them here
-- immediately at press-time is safe: for a genuine click (not a drag) the
-- mouse hasn't moved from where check_system will eventually test it either.
function M.would_hit_editable(origin_x, tab_origin_y, system)
  local line_height = config.layout.line_height
  local n_strings = #config.tuning

  for i = 1, #system.events do
    local event = system.events[i]
    local x = origin_x + event.x
    for j = 1, #event.notes do
      local note = event.notes[j]
      if not note.tied_from_prev then
        local string_idx = note.string or config.layout.x_notehead_string
        local y = tab_origin_y + (string_idx - 1) * line_height
        local dx, dy = mouse_x - x, mouse_y - y
        if math.sqrt(dx * dx + dy * dy) <= HIT_RADIUS then return true end
      end
    end
  end

  local top = tab_origin_y
  local bottom = tab_origin_y + (n_strings - 1) * line_height + line_height / 2
  if mouse_y < top or mouse_y > bottom then return false end

  local xs = system.barline_x
  if #xs == 0 then return false end
  local lo_x = origin_x + xs[1] - CLICK_SLACK
  local hi_x = origin_x + xs[#xs] + CLICK_SLACK
  if mouse_x < lo_x or mouse_x > hi_x then return false end

  local string_idx = round((mouse_y - tab_origin_y) / line_height) + 1
  string_idx = math.max(1, math.min(n_strings, string_idx))
  return next_create_tick(system, mouse_x - origin_x, string_idx) ~= nil
end

-- Call once per system, right after that system's score_render.draw_system
-- call - same slot as note_editor.check_system/measure_correction.
-- check_system.
function M.check_system(origin_x, tab_origin_y, system)
  local line_height = config.layout.line_height
  local n_strings = #config.tuning

  -- Selection-highlight marks: rebuilt fresh every frame (selected_marks
  -- itself was cleared in begin_frame), regardless of click/drag state -
  -- selected_notes persists across many frames after a drag finishes, so
  -- this has to re-derive each currently-selected note's ON-SCREEN
  -- position every frame for end_frame to draw a highlight over, not just
  -- the frame the drag itself completed.
  if next(selected_notes) then
    for i = 1, #system.events do
      local event = system.events[i]
      local x = origin_x + event.x
      for j = 1, #event.notes do
        local note = event.notes[j]
        if note.string then
          local key = note.startppq .. ":" .. note.chan .. ":" .. note.pitch
          if selected_notes[key] then
            local y = tab_origin_y + (note.string - 1) * line_height
            selected_marks[#selected_marks + 1] = { x = x, y = y }
          end
        end
      end
    end
  end

  -- Drag-select rectangle hit-test: finalizes whatever the just-completed
  -- drag covers, across every system checked this frame (screen-space
  -- coordinates need no per-system translation, so a drag spanning a
  -- system/line-wrap boundary naturally selects across it with no extra
  -- work). Deliberately includes tied-continuation notes (unlike the
  -- click-to-edit radius test below, which excludes them) - editing a
  -- tied note directly doesn't make sense, but a rectangle "delete
  -- everything visually in this box" should still catch one, since it's
  -- a real, independently-deletable MIDI note.
  if drag_finished then
    local x0, x1 = math.min(drag_start_x, mouse_x), math.max(drag_start_x, mouse_x)
    local y0, y1 = math.min(drag_start_y, mouse_y), math.max(drag_start_y, mouse_y)
    for i = 1, #system.events do
      local event = system.events[i]
      local x = origin_x + event.x
      if x >= x0 and x <= x1 then
        for j = 1, #event.notes do
          local note = event.notes[j]
          if note.string then
            local y = tab_origin_y + (note.string - 1) * line_height
            if y >= y0 and y <= y1 then
              selected_notes[note.startppq .. ":" .. note.chan .. ":" .. note.pitch] = true
            end
          end
        end
      end
    end
  end

  if not clicked then return end

  -- Existing-note radius hit-test (candidate for the edit/delete popup) -
  -- identical convention to note_editor.check_system, checked across
  -- every system this frame the same way it is there.
  for i = 1, #system.events do
    local event = system.events[i]
    local x = origin_x + event.x
    for j = 1, #event.notes do
      local note = event.notes[j]
      if not note.tied_from_prev then
        local string_idx = note.string or config.layout.x_notehead_string
        local y = tab_origin_y + (string_idx - 1) * line_height
        local dx, dy = mouse_x - x, mouse_y - y
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist <= HIT_RADIUS and (not best_existing or dist < best_existing.dist) then
          best_existing = { note = note, dist = dist }
        end
      end
    end
  end

  -- Empty-grid-cell hit-test (candidate for create) - gated on falling
  -- within THIS system's own staff rows/measure span, see header for why
  -- these explicit bounds are needed (unlike the self-bounding radius
  -- test above). Top is tab_origin_y exactly, not half a line above it -
  -- that upward slack used to reach into the staff gap above the tab
  -- staff, which main.lua's grid_overlay.lua also treats as its own click-
  -- to-seek surface (see that file's header); a seek click landing in the
  -- shared sliver was ALSO read as "create a note on string 1 here," which
  -- popped the Create Note popup open and ate every click after it.
  local top = tab_origin_y
  local bottom = tab_origin_y + (n_strings - 1) * line_height + line_height / 2
  if mouse_y < top or mouse_y > bottom then return end

  local xs = system.barline_x
  if #xs == 0 then return end
  local lo_x = origin_x + xs[1] - CLICK_SLACK
  local hi_x = origin_x + xs[#xs] + CLICK_SLACK
  if mouse_x < lo_x or mouse_x > hi_x then return end

  local string_idx = round((mouse_y - tab_origin_y) / line_height) + 1
  string_idx = math.max(1, math.min(n_strings, string_idx))

  local tick = next_create_tick(system, mouse_x - origin_x, string_idx)
  if not tick then return end

  best_empty = { tick = round(tick), string_idx = string_idx }
end

-- True if any existing note on string_idx overlaps [start_tick, end_tick) -
-- see header for why this reads collision_events (raw MIDI spans), not
-- the render model. exclude_idx (optional) skips a note matching that
-- idx - used when editing a note's OWN duration, so it never collides
-- with its own current span; create passes nil, which never matches any
-- real idx and so checks every note as before.
local function string_occupied(string_idx, start_tick, end_tick, exclude_idx)
  for i = 1, #collision_events do
    local notes = collision_events[i].notes
    for j = 1, #notes do
      local note = notes[j]
      if note.string == string_idx and note.idx ~= exclude_idx
          and note.startppq < end_tick and note.endppq > start_tick then
        return true
      end
    end
  end
  return false
end

-- Duration (in ticks) of the temporally closest note strictly before
-- tick, across ANY string - rhythm applies across the whole texture, not
-- just one string - or nil if nothing precedes it at all (the very first
-- note in the take). Used to default a newly created note's duration
-- field to whatever the piece was already using, see header.
local function previous_note_duration(tick)
  local best = nil
  for i = 1, #collision_events do
    local notes = collision_events[i].notes
    for j = 1, #notes do
      local note = notes[j]
      if note.startppq < tick and (not best or note.startppq > best.startppq) then
        best = note
      end
    end
  end
  if not best then return nil end
  return best.endppq - best.startppq
end

-- True if any existing note (any string) starts at or after tick - used by
-- commit_create to decide whether the just-placed note is at the temporal
-- END of the score (nothing comes after it anywhere in the take), the
-- condition under which M.end_frame's auto-advance (see commit_create's
-- own comment) is allowed to fire. Checked against collision_events
-- BEFORE the new note is written, which is exactly what's wanted here -
-- the note about to be created doesn't count as "something already after
-- itself."
local function anything_after(tick)
  for i = 1, #collision_events do
    local notes = collision_events[i].notes
    for j = 1, #notes do
      if notes[j].startppq >= tick then return true end
    end
  end
  return false
end

-- The existing note (any string) with the smallest startppq strictly
-- greater than after_tick, or nil if none - used by commit_edit's
-- walk-to-next-note advance (see its own comment) to find what the Edit
-- popup should open next. A tie (a chord - two notes sharing the exact
-- same startppq on different strings) isn't specially ordered; the walk
-- simply doesn't visit a simultaneous note on another string, since "next
-- in time" has no single natural ordering across simultaneous notes - an
-- accepted limitation, not a bug.
local function next_note_after(after_tick)
  local best = nil
  for i = 1, #collision_events do
    local notes = collision_events[i].notes
    for j = 1, #notes do
      local n = notes[j]
      if n.startppq > after_tick and (not best or n.startppq < best.startppq) then
        best = n
      end
    end
  end
  return best
end

-- A rest writes no MIDI note at all - it just advances the create popup's
-- insertion point by rest_ticks and re-arms the SAME popup there,
-- UNCONDITIONALLY (unlike a real note's end-of-score-only auto-advance in
-- commit_create below). Nothing is written, so there's never anything to
-- collide with - a rest is a general "skip forward" tool usable anywhere
-- in the piece, not just while appending brand-new material at the tail
-- end. Duration resets to blank (rather than persisting, unlike the normal
-- same-length-run case) since the value that was just "used" was a rest
-- marker, not a real duration - the next note needs an explicit fresh
-- choice.
local function commit_rest(rest_ticks, used_quick)
  pending_create = { tick = pending_create.tick + rest_ticks, string_idx = pending_create.string_idx }
  create_status = nil
  fret_input_buf = ""
  create_duration_buf = ""
  if used_quick then
    create_quick_buf = ""
    focus_create_quick_input = true
  else
    focus_fret_input = true
  end
end

-- Deletes a note via MIDI_DeleteNote (same undo workaround as create - see
-- finalize_midi_write's own comment). Shared by the Delete button
-- (commit_delete) and the Edit popup's rest-shorthand delete (commit_edit,
-- when a "-N/D" duration is typed there) - both remove a note the exact
-- same way, they just differ in what happens to the popup afterward. Also
-- clears any guitar-technique tag this note held (write_note_technique
-- with a nil id) - the P_EXT map is keyed on startppq:chan:pitch, not the
-- note's own idx, so leaving a stale entry behind would silently tag
-- whatever future note ever lands on that exact same startppq/chan/pitch
-- again, which does happen (retyping the same fret/string/tick after
-- undo-then-redo-by-hand, or just coincidence in a repetitive riff).
local function delete_note(note)
  push_undo_snapshot(target_take)
  reaper.Undo_BeginBlock()
  reaper.MIDI_DeleteNote(target_take, note.idx)
  finalize_midi_write(target_take)
  write_note_technique(target_take, note.startppq, note.chan, note.pitch, nil)
  reaper.Undo_EndBlock("Delete note (tab/notation viewer)", UNDO_ALL)
  technique_changed = true
end

-- Deletes every note in selected_notes (see the drag-select rectangle
-- hit-test in check_system) in one undo step - the mass-delete half of
-- drag-to-select. Resolves each selected KEY back to its actual current
-- note (idx included) via collision_events rather than storing note
-- references directly in selected_notes, since a note's idx can shift
-- between the frame it was selected and the frame Delete is actually
-- pressed (any other edit elsewhere in the take renumbers idx) - keying by
-- startppq:chan:pitch instead (same convention the technique P_EXT map
-- already uses) stays valid across that gap the same way write_note_
-- technique's own map keys do.
--
-- Deletes in DESCENDING idx order - REAPER shifts every later note's idx
-- down by one as each earlier one is removed, so deleting low-to-high
-- would invalidate the very idx values already queued for the notes after
-- it; descending order means each delete only ever affects idx values
-- already consumed.
--
-- Technique tags are cleared via one read-modify-write of the whole P_EXT
-- map (not one call to write_note_technique per note, which would re-read
-- and re-serialize that same map N times for N notes) - same reasoning as
-- write_note_technique's own single-note version, just batched.
-- Resolves selected_notes' KEYS back to actual current note records (idx
-- included) via collision_events - shared by mass_delete_selected and
-- try_move_selected_to_string, both of which need the real, current note
-- data behind whatever's selected, not just the keys themselves.
local function gather_selected_notes()
  local notes_out = {}
  for i = 1, #collision_events do
    local notes = collision_events[i].notes
    for j = 1, #notes do
      local note = notes[j]
      if selected_notes[note.startppq .. ":" .. note.chan .. ":" .. note.pitch] then
        notes_out[#notes_out + 1] = note
      end
    end
  end
  return notes_out
end

local function mass_delete_selected()
  local doomed = gather_selected_notes()
  if #doomed == 0 then return end

  table.sort(doomed, function(a, b) return a.idx > b.idx end)

  push_undo_snapshot(target_take)
  reaper.Undo_BeginBlock()
  local map = midi_read.read_technique_map(target_take)
  for _, note in ipairs(doomed) do
    reaper.MIDI_DeleteNote(target_take, note.idx)
    map[note.startppq .. ":" .. note.chan .. ":" .. note.pitch] = nil
  end
  reaper.GetSetMediaItemTakeInfo_String(target_take, midi_read.TECH_EXT_KEY, midi_read.serialize_technique_map(map), true)
  finalize_midi_write(target_take)
  reaper.Undo_EndBlock(string.format("Delete %d notes (tab/notation viewer)", #doomed), UNDO_ALL)
  technique_changed = true

  selected_notes = {}
end

-- Moves every selected note onto target_string, KEEPING EACH NOTE'S OWN
-- PITCH fixed and re-deriving its fret from that (the opposite convention
-- from a single-note Edit popup retarget, which keeps FRET fixed and lets
-- pitch move - see commit_edit's own comment on why that one's different).
-- A pitch-preserving move is what "put this whole passage on one string"
-- actually means musically - the notes already ARE specific pitches, this
-- just changes which string plays them; re-deriving fret is the same
-- pitch -> string/fret math fret_heuristic.lua already does at read time
-- (a note's fret is never stored, only chan/pitch), so nothing else needs
-- to change once chan is rewritten to target_string.
--
-- Refuses (returns false, reason) rather than partially applying, on
-- either kind of impossibility:
--   - a note's required fret on target_string lands outside 0..max_fret
--   - two selected notes overlap in time (they can't both play on one
--     string at once)
--   - a selected note would overlap an EXISTING, non-selected note that's
--     already on target_string
-- All three are checked BEFORE any write happens, same "validate
-- everything, then commit once" shape commit_create/commit_edit already
-- use for their own single-note collision checks - a mass operation like
-- this one failing halfway through, with some notes already moved and
-- others not, would leave a much harder mess to undo out of by hand.
local function notes_overlap(a, b)
  return a.startppq < b.endppq and b.startppq < a.endppq
end

-- target_display is the typed/displayed string number (see
-- notation_model.display_string_number) - converted to the internal index
-- right after the range check, same pattern as parse_string_index, so
-- every message below can keep showing target_display (what the user
-- actually typed) while every real config.tuning/MIDI operation uses
-- target_string (the internal index).
local function try_move_selected_to_string(target_display)
  if not target_display or target_display < 1 or target_display > #config.tuning then
    return false, string.format("String must be between 1 and %d.", #config.tuning)
  end
  local target_string = notation_model.display_string_number(config, target_display)

  local doomed = gather_selected_notes()
  if #doomed == 0 then return false, "Nothing selected." end

  -- Fret range check - each note's own pitch against target_string.
  local moves = {}
  for _, note in ipairs(doomed) do
    local fret = note.pitch - config.tuning[target_string] - config.capo
    if fret < 0 or fret > config.max_fret then
      return false, string.format(
        "Can't move: the note at tick %d would need fret %s on string %d (must be 0-%s).",
        note.startppq, notation_model.display_fret_label(config, fret), target_display,
        notation_model.display_fret_label(config, config.max_fret))
    end
    moves[#moves + 1] = note
  end

  -- Selected notes can't overlap each other once they all share one string.
  for a = 1, #moves do
    for b = a + 1, #moves do
      if notes_overlap(moves[a], moves[b]) then
        return false, "Can't move: two of the selected notes overlap in time, so they can't both be on one string."
      end
    end
  end

  -- Nor can a selected note land on top of an existing, non-selected note
  -- already on target_string.
  local doomed_idx = {}
  for _, note in ipairs(doomed) do doomed_idx[note.idx] = true end
  for i = 1, #collision_events do
    local notes = collision_events[i].notes
    for j = 1, #notes do
      local other = notes[j]
      if other.string == target_string and not doomed_idx[other.idx] then
        for _, note in ipairs(moves) do
          if notes_overlap(other, note) then
            return false, string.format("Can't move: string %d already has a note during that time.", target_display)
          end
        end
      end
    end
  end

  push_undo_snapshot(target_take)
  reaper.Undo_BeginBlock()
  local map = midi_read.read_technique_map(target_take)
  for _, note in ipairs(moves) do
    local old_key = note.startppq .. ":" .. note.chan .. ":" .. note.pitch
    local technique = map[old_key]
    reaper.MIDI_SetNote(target_take, note.idx, nil, nil, nil, nil, target_string, nil, nil, nil)
    if technique then
      map[old_key] = nil
      map[note.startppq .. ":" .. target_string .. ":" .. note.pitch] = technique
    end
  end
  reaper.GetSetMediaItemTakeInfo_String(target_take, midi_read.TECH_EXT_KEY, midi_read.serialize_technique_map(map), true)
  finalize_midi_write(target_take)
  reaper.Undo_EndBlock(string.format("Move %d notes to string %d (tab/notation viewer)", #moves, target_display), UNDO_ALL)
  technique_changed = true

  selected_notes = {}
  return true, nil
end

local function commit_create(ctx)
  local quick_trimmed = (create_quick_buf or ""):match("^%s*(.-)%s*$")
  local classic_trimmed = (create_duration_buf or ""):match("^%s*(.-)%s*$")

  -- A leading "-" in either box means REST (see parse_rest_input/
  -- commit_rest) - checked first, before any fret/string validation, since
  -- a rest needs neither. Quick entry wins if both happen to be filled in,
  -- same override precedence as the note case below.
  local rest_source = quick_trimmed ~= "" and quick_trimmed or classic_trimmed
  if rest_source:sub(1, 1) == "-" then
    local rest_ticks = parse_rest_input(rest_source)
    if not rest_ticks then
      create_status = "Enter a valid rest (e.g. -1/4 for a quarter rest)."
      return
    end
    commit_rest(rest_ticks, quick_trimmed ~= "")
    return
  end

  -- Quick entry, when non-blank, OVERRIDES the three classic fields
  -- entirely rather than merging with them (see parse_quick_entry) - a
  -- half-filled quick box combined with stale classic fields would be
  -- ambiguous about which one the user actually meant.
  local used_quick = quick_trimmed ~= ""

  local string_idx, fret, duration_ticks, technique_id, velocity_override
  if used_quick then
    local err
    fret, string_idx, duration_ticks, technique_id, velocity_override, err = parse_quick_entry(create_quick_buf)
    if not fret then
      create_status = err
      return
    end
  else
    string_idx = parse_string_index(create_string_buf)
    if not string_idx then
      create_status = string.format("String must be between 1 and %d.", #config.tuning)
      return
    end

    fret, technique_id, velocity_override = parse_fret_input(fret_input_buf)
    if not fret then
      create_status = "Enter a valid fret number."
      return
    end
    if fret < 0 or fret > config.max_fret then
      create_status = string.format(
        "Fret must be between 0 and %s.", notation_model.display_fret_label(config, config.max_fret))
      return
    end

    duration_ticks = parse_duration_input(create_duration_buf)
    if not duration_ticks then
      create_status = "Enter a valid duration (e.g. 4 for a quarter note, 8T for an eighth-note triplet)."
      return
    end
  end

  -- Keep the classic fields in sync with whatever just won (quick entry or
  -- the fields themselves), so switching input modes mid-session never
  -- shows a stale value if the write below fails and the popup stays open.
  fret_input_buf = format_fret_with_technique(fret, technique_id, velocity_override)
  create_string_buf = tostring(notation_model.display_string_number(config, string_idx))
  create_duration_buf = denominator_for_ticks(duration_ticks)

  local start_tick = pending_create.tick
  local end_tick = start_tick + duration_ticks

  if string_occupied(string_idx, start_tick, end_tick, nil) then
    create_status = "A note already exists on this string here."
    return
  end

  -- Checked BEFORE the write, against the pre-insert state - see
  -- anything_after's own comment.
  local is_end_of_score = not anything_after(end_tick)

  local pitch = math.max(0, math.min(127, config.tuning[string_idx] + config.capo + fret))
  local vel = velocity_override or config.edit_default_velocity

  push_undo_snapshot(target_take)
  reaper.Undo_BeginBlock()
  reaper.MIDI_InsertNote(
    target_take, false, false, start_tick, end_tick, string_idx, pitch, vel, false)
  finalize_midi_write(target_take)
  if technique_id then
    write_note_technique(target_take, start_tick, string_idx, pitch, technique_id)
    technique_changed = true
  end
  reaper.Undo_EndBlock("Insert note (tab/notation viewer)", UNDO_ALL)

  if is_end_of_score then
    -- Fast tab-entry chaining: this note was appended at the very end of
    -- the piece (nothing existed after it), so immediately re-arm the SAME
    -- popup for the next note, right where this one just ended, rather
    -- than closing - lets a whole run be typed as fret-Enter-fret-Enter-...
    -- with no mouse clicks in between. Only fret_input_buf resets (blank,
    -- ready for the next fret number); create_string_buf and
    -- create_duration_buf deliberately keep whatever values were just
    -- used, since a fast-entry run is usually a string of same-string,
    -- equal-length notes - typing a new string number (or duration)
    -- overrides it for the rest of the run without needing to re-click the
    -- tab staff at all. Explicitly does NOT call CloseCurrentPopup - the
    -- popup stays open across frames exactly as if it had never closed,
    -- avoiding any close/reopen flicker. If a note already exists past
    -- this point instead (is_end_of_score false), this branch is skipped
    -- and the popup closes as normal - auto-advance is for building new
    -- material, not for inserts into the middle of an existing passage.
    pending_create = { tick = end_tick, string_idx = string_idx }
    fret_input_buf = ""
    create_status = nil
    if used_quick then
      -- Cursor lands back in the same box that was just used, not Fret -
      -- a quick-entry run stays a quick-entry run without needing to
      -- click or Tab back into it each time.
      create_quick_buf = ""
      focus_create_quick_input = true
    else
      focus_fret_input = true
    end
  else
    pending_create = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
end

-- Fret+string+duration edit commit - deliberately MIDI_SetNote, not
-- anywhere near MIDI_InsertNote/MIDI_DeleteNote, so it inherits the SAME
-- reliable undo note_editor.lua's edits have always had (see this file's
-- header). Edits ALL THREE fields in one write/one undo step, same as
-- commit_create validates and writes string+fret+duration together for a
-- new note. Unlike note_editor.lua's own View Mode correction (which keeps
-- PITCH fixed and re-derives fret when you retarget a string), this
-- follows Edit Mode's own established convention throughout the rest of
-- this file: string+fret are the primary, directly-typed values, and pitch
-- is always just computed fresh from whichever string+fret are currently
-- in the two fields at commit time - so retargeting a note to a different
-- string keeps its FRET NUMBER, not its pitch (the more natural reading
-- for someone typing tab directly rather than correcting a heuristic's
-- pitch guess). Same quick-entry override as commit_create - see its own
-- comment.
local function commit_edit(ctx)
  local note = pending_edit.note
  local quick_trimmed = (edit_quick_buf or ""):match("^%s*(.-)%s*$")
  local classic_trimmed = (edit_duration_buf or ""):match("^%s*(.-)%s*$")

  -- A leading "-" here means REST too, but a rest has no fret/string/pitch
  -- of its own to edit an existing note INTO - so this deletes the note
  -- instead (same action as the Delete button, via the shared delete_note
  -- helper), then walks to the next note exactly like a normal edit commit
  -- does below, rather than just closing.
  local rest_source = quick_trimmed ~= "" and quick_trimmed or classic_trimmed
  if rest_source:sub(1, 1) == "-" then
    if not parse_rest_input(rest_source) then
      edit_status = "Enter a valid rest (e.g. -1/4 for a quarter rest)."
      return
    end
    local used_quick_for_rest = quick_trimmed ~= ""
    local original_tick = note.startppq
    delete_note(note)

    local next_note = next_note_after(original_tick)
    if next_note then
      pending_edit = { note = next_note }
      edit_string_buf = tostring(notation_model.display_string_number(config, next_note.string or config.layout.x_notehead_string))
      edit_fret_buf = format_fret_with_technique(
        next_note.fret or 0, note_technique(target_take, next_note), next_note.vel)
      edit_duration_buf = denominator_for_ticks(next_note.endppq - next_note.startppq)
      edit_status = nil
      if used_quick_for_rest then
        edit_quick_buf = ""
        focus_edit_quick_input = true
      else
        focus_edit_fret_input = true
      end
    else
      pending_edit = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    return
  end

  local used_quick = quick_trimmed ~= ""

  local string_idx, fret, duration_ticks, technique_id, velocity_override
  if used_quick then
    local err
    fret, string_idx, duration_ticks, technique_id, velocity_override, err = parse_quick_entry(edit_quick_buf)
    if not fret then
      edit_status = err
      return
    end
  else
    string_idx = parse_string_index(edit_string_buf)
    if not string_idx then
      edit_status = string.format("String must be between 1 and %d.", #config.tuning)
      return
    end

    fret, technique_id, velocity_override = parse_fret_input(edit_fret_buf)
    if not fret then
      edit_status = "Enter a valid fret number."
      return
    end
    if fret < 0 or fret > config.max_fret then
      edit_status = string.format(
        "Fret must be between 0 and %s.", notation_model.display_fret_label(config, config.max_fret))
      return
    end

    duration_ticks = parse_duration_input(edit_duration_buf)
    if not duration_ticks then
      edit_status = "Enter a valid duration (e.g. 4 for a quarter note, 8T for an eighth-note triplet)."
      return
    end
  end

  edit_fret_buf = format_fret_with_technique(fret, technique_id, velocity_override)
  edit_string_buf = tostring(notation_model.display_string_number(config, string_idx))
  edit_duration_buf = denominator_for_ticks(duration_ticks)

  local new_end = note.startppq + duration_ticks

  -- Checked against the (possibly NEW) target string, not the note's own
  -- current one - retargeting to a different string can introduce a real
  -- collision there that simply changing duration in place never could,
  -- so this same check now also covers that case, not just a duration
  -- change. note.idx is still excluded so the note never collides with
  -- its own current span when the string is left unchanged.
  if string_occupied(string_idx, note.startppq, new_end, note.idx) then
    edit_status = "That duration would overlap another note on this string."
    return
  end

  local pitch = math.max(0, math.min(127, config.tuning[string_idx] + config.capo + fret))
  -- Always written explicitly (never left as nil/"unchanged"), same
  -- full-overwrite philosophy every other field here already follows -
  -- editing away a "pm"/"ph" suffix without retyping it should actually
  -- un-mute the note, not leave a stale muted velocity behind.
  local vel = velocity_override or config.edit_default_velocity

  -- Old key computed from the note's PRE-edit chan/pitch, so retargeting
  -- string/fret moves its technique tag along rather than leaving a stale
  -- entry at the old position - see write_note_technique's own comment.
  local old_key = note.startppq .. ":" .. note.chan .. ":" .. note.pitch

  push_undo_snapshot(target_take)
  reaper.Undo_BeginBlock()
  reaper.MIDI_SetNote(target_take, note.idx, nil, nil, nil, new_end, string_idx, pitch, vel, nil)
  write_note_technique(target_take, note.startppq, string_idx, pitch, technique_id, old_key)
  reaper.Undo_EndBlock("Edit note (tab/notation viewer)", UNDO_ALL)
  technique_changed = true

  -- Walk to the next existing note in time order (see next_note_after) so
  -- a whole passage can be rapid-fire re-tagged, Enter after Enter, rather
  -- than closing after every single note - the Edit-popup mirror of
  -- commit_create's own end-of-score chaining. note.startppq is this
  -- note's ORIGINAL onset (Edit Mode never changes a note's onset, only
  -- its fret/string/duration), so it's still the correct ordering key even
  -- though the note was just rewritten.
  local next_note = next_note_after(note.startppq)
  if next_note then
    pending_edit = { note = next_note }
    edit_string_buf = tostring(notation_model.display_string_number(config, next_note.string or config.layout.x_notehead_string))
    edit_fret_buf = format_fret_with_technique(
      next_note.fret or 0, note_technique(target_take, next_note), next_note.vel)
    edit_duration_buf = denominator_for_ticks(next_note.endppq - next_note.startppq)
    edit_status = nil
    if used_quick then
      edit_quick_buf = ""
      focus_edit_quick_input = true
    else
      focus_edit_fret_input = true
    end
  else
    pending_edit = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
end

local function commit_delete(ctx)
  delete_note(pending_edit.note)
  pending_edit = nil
  reaper.ImGui_CloseCurrentPopup(ctx)
end

local function draw_create_popup(ctx)
  reaper.ImGui_Text(ctx, "New note")

  local string_flags = reaper.ImGui_InputTextFlags_CharsDecimal()

  -- Quick entry: optional "string.fret.duration" box (see
  -- parse_quick_entry), e.g. "8.12.1/8+" or "8.12l.1/8+" for the same note
  -- legato-flagged - a compact, mostly-numpad alternative to the three
  -- fields below. No CharsDecimal here (unlike String, below) - a fret's
  -- own technique suffix (l/t/lt/pm/ph - see strip_technique_suffix) needs
  -- letters typeable, same reason Duration's own field has never used
  -- CharsDecimal. Leaving this blank falls back to String/Fret/Duration
  -- exactly as before (see commit_create); filling it in overrides them.
  if focus_create_quick_input then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    focus_create_quick_input = false
  end
  local _, new_quick_text = reaper.ImGui_InputText(ctx, "Tab Code (string.fret.duration)", create_quick_buf)
  create_quick_buf = new_quick_text
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, quick_entry_tooltip_create())
  end

  reaper.ImGui_Separator(ctx)

  -- String, drawn first - seeded from whichever row was actually clicked
  -- (pending_create.string_idx, set once when the popup opens) but freely
  -- retypeable from here on, same as Fret/Duration; commit_create reads
  -- the FIELD's value, not pending_create.string_idx, once the popup is
  -- open. String-before-Fret matches how a guitarist actually locates a
  -- note - pick the string first, then the fret on it - rather than the
  -- reverse.
  local _, new_string_text = reaper.ImGui_InputText(ctx, "String", create_string_buf, string_flags)
  create_string_buf = new_string_text

  -- Fret, drawn second but STILL given initial keyboard focus on a fresh
  -- popup open (see focus_fret_input below), even though it's no longer
  -- the first field visually - String is already correct from the click
  -- that opened this popup (it names which string row was clicked), so
  -- Fret is the one field that actually needs typing for a brand-new note,
  -- typed rapidly click-to-click without touching the mouse. Deliberately
  -- NOT InputTextFlags_EnterReturnsTrue: that flag's own doc note
  -- ("consider using IsItemDeactivatedAfterEdit instead") hints at exactly
  -- the bug it caused here - tabbing out of the Fret field (rather than
  -- pressing Enter in it) lost whatever had been typed, because the
  -- returned buffer isn't reliably kept in sync on a non-Enter defocus. No
  -- CharsDecimal here either, same reason as Quick entry above (a
  -- technique suffix needs letters) - plain InputText still syncs the
  -- buffer every frame regardless of how the field loses focus (Tab,
  -- click-away, or Enter).
  if focus_fret_input then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    focus_fret_input = false
  end
  local _, new_fret_text = reaper.ImGui_InputText(ctx, "Fret", fret_input_buf)
  fret_input_buf = new_fret_text
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, fret_tooltip())
  end

  -- No CharsDecimal here (unlike Fret, above) - a trailing T/t (e.g. "8T"
  -- for an eighth-note triplet, see parse_duration_input) needs to be
  -- typeable; CharsDecimal only allows "0123456789.+-*/" and would
  -- silently block the letter.
  local _, new_dur_text = reaper.ImGui_InputText(ctx, "Duration (N, N/D, -N/D rest)", create_duration_buf)
  create_duration_buf = new_dur_text
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, DURATION_TOOLTIP_CREATE)
  end

  -- Enter-to-commit: checked ONCE here, globally, rather than per-field
  -- gated on IsItemActive right after each InputText call (an earlier
  -- version did that and it silently never fired - Dear ImGui deactivates
  -- an InputText as PART of processing its own Enter keypress, within that
  -- same InputText() call, so by the time IsItemActive(ctx) was checked
  -- right after, the field had already gone inactive that same frame,
  -- same class of "who consumes the event first" timing issue as the
  -- earlier Tab/EnterReturnsTrue bug). A plain, unscoped IsKeyPressed is a
  -- raw keyboard-state query, not gated by which widget currently holds
  -- focus, so it reliably fires regardless of whether Fret, Duration, or
  -- neither currently has focus - matching standard "Enter submits the
  -- form" dialog behavior.
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false) then
    commit_create(ctx)
    return
  end

  if reaper.ImGui_Button(ctx, "Add") then
    commit_create(ctx)
    return
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Cancel") then
    pending_create = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
    return
  end

  if create_status then
    reaper.ImGui_TextWrapped(ctx, create_status)
  end
end

local function draw_edit_popup(ctx)
  reaper.ImGui_Text(ctx, "Edit Note")

  -- See draw_create_popup's matching comments throughout: no
  -- EnterReturnsTrue (buffer sync survives Tab-away), no CharsDecimal on
  -- Quick entry/Fret (both need letters typeable - a technique suffix on
  -- Fret, Duration's own trailing T/t, e.g. "8T"), CharsDecimal kept on
  -- String only, and Enter-to-commit checked once, globally, rather than
  -- gated on IsItemActive right after InputText (which never reliably
  -- fires).
  local string_flags = reaper.ImGui_InputTextFlags_CharsDecimal()

  -- Quick entry: same "string.fret.duration" box as draw_create_popup,
  -- overriding String/Fret/Duration below when non-blank (see commit_edit/
  -- parse_quick_entry).
  if focus_edit_quick_input then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    focus_edit_quick_input = false
  end
  local _, new_quick_text = reaper.ImGui_InputText(ctx, "Tab Code (string.fret.duration)", edit_quick_buf)
  edit_quick_buf = new_quick_text
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, quick_entry_tooltip_edit())
  end

  reaper.ImGui_Separator(ctx)

  -- String is drawn first, prepopulated with this note's CURRENT string
  -- (see M.end_frame) but freely retypeable to move the note to a
  -- different string entirely - commit_edit reads whatever's in the field
  -- at commit time, not the note's original string. String-before-Fret
  -- matches how a guitarist actually locates a note - pick the string
  -- first, then the fret on it.
  local _, new_string_text = reaper.ImGui_InputText(ctx, "String", edit_string_buf, string_flags)
  edit_string_buf = new_string_text

  -- Fret is drawn second but STILL gets initial keyboard focus on a fresh
  -- popup open (same rationale as draw_create_popup) - String is already
  -- correct from whichever existing note was clicked, so Fret is the one
  -- field that actually needs retyping most often.
  if focus_edit_fret_input then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    focus_edit_fret_input = false
  end
  local _, new_fret_text = reaper.ImGui_InputText(ctx, "Fret", edit_fret_buf)
  edit_fret_buf = new_fret_text
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, fret_tooltip())
  end

  local _, new_text = reaper.ImGui_InputText(ctx, "Duration (N, N/D, -N/D rest)", edit_duration_buf)
  edit_duration_buf = new_text
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, DURATION_TOOLTIP_EDIT)
  end

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false) then
    commit_edit(ctx)
    return
  end

  if reaper.ImGui_Button(ctx, "Update") then
    commit_edit(ctx)
    return
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Delete") then
    commit_delete(ctx)
    return
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Cancel") then
    pending_edit = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
    return
  end

  if edit_status then
    reaper.ImGui_TextWrapped(ctx, edit_status)
  end
end

-- "Move to String" popup - opened from the right-click context menu on an
-- active selection (see M.end_frame). Stays open with a status message on
-- failure, same convention as the Create/Edit popups above, so the reason
-- try_move_selected_to_string refused is visible right where the user just
-- asked for the move, not a fire-and-forget action with no feedback.
local function draw_move_popup(ctx)
  local count = 0
  for _ in pairs(selected_notes) do count = count + 1 end
  reaper.ImGui_Text(ctx, string.format("Move %d selected note%s to string:", count, count == 1 and "" or "s"))

  if focus_move_input then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    focus_move_input = false
  end
  local string_flags = reaper.ImGui_InputTextFlags_CharsDecimal()
  local _, new_text = reaper.ImGui_InputText(ctx, "String", move_string_buf, string_flags)
  move_string_buf = new_text

  local function commit_move()
    local target_display = tonumber(move_string_buf)
    local ok, err = try_move_selected_to_string(target_display and round(target_display) or nil)
    if ok then
      move_status = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    else
      move_status = err
    end
  end

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false) then
    commit_move()
    return
  end

  if reaper.ImGui_Button(ctx, "Move") then
    commit_move()
    return
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Cancel") then
    move_status = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
    return
  end

  if move_status then
    reaper.ImGui_TextWrapped(ctx, move_status)
  end
end

-- Call once per frame after every system has been checked. Opens whichever
-- popup applies to this frame's closest hit (an existing-note hit always
-- takes priority over an empty-cell hit, matching "click a note" reading
-- as more specific than "click near a note's grid cell"), then draws
-- whichever popup is currently open - same OpenPopup-this-frame/
-- BeginPopup-every-frame idiom as note_editor.end_frame.
function M.end_frame(ctx)
  if clicked and best_existing then
    pending_edit = { note = best_existing.note }
    pending_create = nil
    edit_status = nil
    edit_string_buf = tostring(notation_model.display_string_number(config, best_existing.note.string or config.layout.x_notehead_string))
    edit_fret_buf = format_fret_with_technique(
      best_existing.note.fret or 0, note_technique(target_take, best_existing.note), best_existing.note.vel)
    edit_duration_buf = denominator_for_ticks(best_existing.note.endppq - best_existing.note.startppq)
    edit_quick_buf = ""
    -- A fresh click (as opposed to the walk-to-next-note advance in
    -- commit_edit) always starts in Fret, regardless of whether quick
    -- entry was used last time - this is a new, unrelated note.
    focus_edit_fret_input = true
    reaper.ImGui_OpenPopup(ctx, EDIT_POPUP_ID)
  elseif clicked and best_empty then
    pending_create = { tick = best_empty.tick, string_idx = best_empty.string_idx }
    pending_edit = nil
    create_status = nil
    create_string_buf = tostring(notation_model.display_string_number(config, best_empty.string_idx))
    fret_input_buf = ""
    create_duration_buf = denominator_for_ticks(previous_note_duration(best_empty.tick))
    create_quick_buf = ""
    focus_fret_input = true
    reaper.ImGui_OpenPopup(ctx, CREATE_POPUP_ID)
  end

  -- Right-click anywhere (not just on a selected note - the selection
  -- itself, not the click position, is what the menu acts on) opens a
  -- small context menu offering mass delete as a discoverable click-only
  -- alternative to the Delete key below. Gated the same way the Delete key
  -- itself is - a live selection, no popup already open - and checked
  -- BEFORE this frame's BeginPopup call, same OpenPopup-then-BeginPopup
  -- ordering every other popup in this file already uses.
  if next(selected_notes) and not popup_was_open and reaper.ImGui_IsMouseClicked(ctx, 1) then
    reaper.ImGui_OpenPopup(ctx, CONTEXT_MENU_POPUP_ID)
  end

  local create_open = reaper.ImGui_BeginPopup(ctx, CREATE_POPUP_ID)
  if create_open then
    draw_create_popup(ctx)
    reaper.ImGui_EndPopup(ctx)
  end

  local edit_open = reaper.ImGui_BeginPopup(ctx, EDIT_POPUP_ID)
  if edit_open then
    draw_edit_popup(ctx)
    reaper.ImGui_EndPopup(ctx)
  end

  local context_open = reaper.ImGui_BeginPopup(ctx, CONTEXT_MENU_POPUP_ID)
  if context_open then
    local count = 0
    for _ in pairs(selected_notes) do count = count + 1 end
    if reaper.ImGui_Selectable(ctx, string.format("Delete %d Note%s", count, count == 1 and "" or "s"), false) then
      mass_delete_selected()
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    if reaper.ImGui_Selectable(ctx, "Move to String...", false) then
      -- Deferred to right after this popup's own EndPopup, below - opening
      -- a second, unrelated popup while this one is still active on the
      -- same frame isn't part of the OpenPopup-then-BeginPopup idiom every
      -- other popup in this file follows, so this just flags the request
      -- and lets the normal per-frame flow pick it up. Seeded from an
      -- arbitrary selected note's own current string (any one of them - a
      -- reasonable starting guess, not a source of truth) so the field
      -- isn't just a blank "1" every time.
      local seed = gather_selected_notes()[1]
      move_string_buf = tostring(notation_model.display_string_number(config, (seed and seed.string) or 1))
      move_status = nil
      focus_move_input = true
      open_move_popup = true
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    if reaper.ImGui_Selectable(ctx, "Clear Selection", false) then
      selected_notes = {}
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  if open_move_popup then
    open_move_popup = false
    reaper.ImGui_OpenPopup(ctx, MOVE_POPUP_ID)
  end

  local move_open = reaper.ImGui_BeginPopup(ctx, MOVE_POPUP_ID)
  if move_open then
    draw_move_popup(ctx)
    reaper.ImGui_EndPopup(ctx)
  end

  popup_was_open = create_open or edit_open or context_open or move_open

  -- Drag-to-select overlay + mass delete (see check_system's rectangle
  -- hit-test and mass_delete_selected above) - drawn/handled here rather
  -- than per-system since it's entirely screen-space, no per-system origin
  -- needed. Gated on no popup being open this frame - a fresh click
  -- already clears selected_notes in begin_frame before a popup can ever
  -- open, so this is a defensive guard, not something expected to matter
  -- in practice.
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  for _, mark in ipairs(selected_marks) do
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, mark.x, mark.y, SELECTION_MARK_RADIUS, SELECTION_MARK_FILL)
    reaper.ImGui_DrawList_AddCircle(draw_list, mark.x, mark.y, SELECTION_MARK_RADIUS, SELECTION_MARK_BORDER, 0, 2.0)
  end

  if drag_active and drag_is_selecting then
    local x0, x1 = math.min(drag_start_x, mouse_x), math.max(drag_start_x, mouse_x)
    local y0, y1 = math.min(drag_start_y, mouse_y), math.max(drag_start_y, mouse_y)
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x0, y0, x1, y1, SELECTION_RECT_FILL)
    reaper.ImGui_DrawList_AddRect(draw_list, x0, y0, x1, y1, SELECTION_RECT_BORDER)
  elseif next(selected_notes) and not popup_was_open then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Delete(), false) then
      mass_delete_selected()
    elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
      selected_notes = {}
    else
      -- Anchored near the mouse cursor, not a fixed window corner - this
      -- window has no separate scrolling child region for the score (see
      -- main.lua), so a fixed corner would sit on top of the settings UI
      -- above the score content instead of over the score itself.
      local count = 0
      for _ in pairs(selected_notes) do count = count + 1 end
      local text = string.format(
        "%d note%s selected - Delete or right-click to remove, Esc to clear", count, count == 1 and "" or "s")
      reaper.ImGui_DrawList_AddText(draw_list, mouse_x + 14, mouse_y + 14, SELECTION_HUD_COLOR, text)
    end
  end

  -- Ctrl+Z / Ctrl+Shift+Z (Ctrl+Y as the common Windows alias for redo) -
  -- see push_undo_snapshot/do_undo/do_redo's own comment for why this
  -- exists instead of relying on REAPER's native undo. Gated on no popup
  -- being open, same reasoning as the Delete/Escape handling above, but
  -- for a different hazard: Dear ImGui's own InputText has its own
  -- built-in Ctrl+Z for in-progress typing, and this shouldn't shadow that
  -- while a Fret/String/Duration/Tab Code field is focused.
  if not popup_was_open then
    local mods = reaper.ImGui_GetKeyMods(ctx)
    local ctrl_down = (mods & reaper.ImGui_Mod_Ctrl()) ~= 0
    local shift_down = (mods & reaper.ImGui_Mod_Shift()) ~= 0
    if ctrl_down and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z(), false) then
      if shift_down then do_redo() else do_undo() end
    elseif ctrl_down and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Y(), false) then
      do_redo()
    end
  end

  -- Returns true exactly once, the frame after a technique-only P_EXT
  -- write (a MIDI-data write, create/delete/duration/string/fret, already
  -- triggers main.lua's own hash-based recompute on its own - see
  -- write_note_technique's own comment on why P_EXT changes need this
  -- extra signal). Mirrors note_editor.lua's end_frame return exactly.
  local changed = technique_changed
  technique_changed = false
  return changed
end

return M
