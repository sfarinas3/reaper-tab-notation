-- Settings panel: score header info (title, composer, arranger - main.lua
-- draws these above the first system like a real printed score's title
-- page, see its header) in a "Score Info" section;
-- instrument (a one-click "swap to a completely different instrument"
-- preset - currently Guitar/Shamisen, see INSTRUMENTS), string count,
-- tuning (per-string note names, or a preset), capo, and max fret in one
-- collapsible "Instrument Settings" section, key signature in its own
-- separate "Key Signature" section, and a "Score Color Scheme" section with just
-- two options - background and one foreground "ink" color covering
-- everything else (noteheads, stems, text, staff/tab lines) - rather than
-- per-element colors, at least for now (see color_util.lua for how
-- secondary/dimmed elements like barlines and ties derive from those same
-- two colors instead of needing their own settings) - the pieces of
-- Phase 5 polish that needed an actual UI rather than just a config.lua
-- constant, since these are properties a user genuinely wants to change
-- per-project without editing source. Embedded at the top of the same
-- docked window rather than a separate script/dialog, so both are always
-- one click away and share REAPER's own docking for free.
--
-- Every string-count/tuning-scoped module (fret_heuristic.lua,
-- notation_model.lua, draw_tab.lua, draw_notation.lua, layout_engine.lua)
-- is already generic over #config.tuning, so swapping to a 3-string
-- instrument like shamisen needs no special-casing elsewhere - a 3-string
-- tuning already falls under draw_notation.lua's existing string_count > 6
-- grand-staff trigger being false, giving treble-clef-only notation for
-- free.
--
-- config.lua's table is otherwise static (loaded once at require time),
-- but every reader reads config.tuning/config.capo/config.max_fret/
-- config.key_count fresh on every call rather than caching a local copy -
-- so mutating those fields in place here (config.tuning = new_array, not
-- editing config itself) propagates everywhere with no further plumbing.
-- The one thing that DOES need explicit plumbing: none of these ever touch
-- the MIDI take, so main.lua's note-hash cache-invalidation check never
-- notices a change on its own - M.draw()'s return value is a second,
-- explicit "please recompute" signal alongside that hash check. A key
-- change additionally recomputes config.layout.left_margin right away
-- (see apply_key_margin) since layout_engine.compute reads that as the
-- starting x for the first note - a stale margin would visibly crowd or
-- gap the staff header until the next unrelated recompute.
--
-- Persistence is two-layered: save_persisted/load_persisted (ExtState) is
-- a single global "last used" fallback shared by every project/item, and
-- save_for_take/load_for_take additionally saves the same fields directly
-- on a specific MIDI take (via REAPER's own per-take P_EXT persistent-data
-- mechanism), so a guitar take and a shamisen take - or just two
-- differently-tuned guitar takes - each remember their own settings
-- instead of fighting over one shared value. main.lua calls load_for_take
-- whenever the ACTIVE TAKE ITSELF changes (not on every note edit), and
-- M.draw calls save_for_take on any settings change, same moment as the
-- ExtState save.

local config = require('config')
local notation_model = require('notation_model')
local draw_notation = require('draw_notation')

local M = {}

local EXT_SECTION = "reaper-tab-notation"
local MIN_STRINGS, MAX_STRINGS = 1, 9
local MAX_CAPO = 12
local MIN_MAX_FRET, MAX_MAX_FRET = 4, 24

local LETTER_SEMITONE = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }

-- Standard tunings per string count, high string first (config.tuning's
-- own convention). Extended-range entries follow the same "each added
-- string sits a perfect fourth below the last" convention as config.lua's
-- own 8-string default. String counts outside 6-9 have no real "standard"
-- guitar tuning, so they're left with no presets - just manual entry.
local PRESETS = {
  [6] = {
    { name = "Standard (E A D G B E)", tuning = { 64, 59, 55, 50, 45, 40 } },
    { name = "Drop D", tuning = { 64, 59, 55, 50, 45, 38 } },
  },
  [7] = {
    { name = "Standard (B E A D G B E)", tuning = { 64, 59, 55, 50, 45, 40, 35 } },
    { name = "Drop A", tuning = { 64, 59, 55, 50, 45, 40, 33 } },
  },
  [8] = {
    { name = "Standard (F#-B-E-A-D-G-B-E)", tuning = { 64, 59, 55, 50, 45, 40, 35, 30 } },
    { name = "Drop E", tuning = { 64, 59, 55, 50, 45, 40, 35, 28 } },
  },
  [9] = {
    { name = "Standard (C#-F#-B-E-A-D-G-B-E)", tuning = { 64, 59, 55, 50, 45, 40, 35, 30, 25 } },
  },
  -- Shamisen's three classic tunings (source: shamisen-zentrale.de's
  -- honchoshi/niagari/sansagari reference, using its own C3-F3-C4 example
  -- pitch - shamisen has no single fixed concert pitch the way guitar
  -- does, it's tuned relative to a singer/ensemble, so this is just a
  -- reasonable default octave, same as any other tuning field here).
  -- tuning[1] (thin/high string) first, matching this app's own
  -- high-to-low convention - which is also exactly how bunkafu itself
  -- draws it: thin string on the top line, thick string on the bottom.
  [3] = {
    { name = "Honchoshi (C4 F3 C3)", tuning = { 60, 53, 48 } },
    { name = "Niagari (C4 G3 C3)", tuning = { 60, 55, 48 } },
    { name = "Sansagari (Bb3 F3 C3)", tuning = { 58, 53, 48 } },
  },
}

-- One-click "swap to a different instrument" presets: unlike PRESETS
-- above (which only changes the tuning, scoped to the CURRENT string
-- count), picking one of these changes string count, tuning, and max_fret
-- together - the full configuration that makes this a different
-- instrument's tab, not just a different tuning of the same one. A 3-string
-- instrument never triggers the grand staff (draw_notation.lua's
-- is_grand check is string_count > 6), so shamisen gets treble-clef-only
-- notation automatically, with no separate flag needed.
local INSTRUMENTS = {
  { name = "Guitar", tuning = { 64, 59, 55, 50, 45, 40 }, max_fret = 24 },
  -- Bunkafu positions commonly run to about 18-19 on the top string.
  { name = "Shamisen", tuning = { 60, 53, 48 }, max_fret = 19 },
}

-- Short "which instrument/tuning is active" summary, drawn just below the
-- Instrument/Key dropdowns so it's obvious at a glance whether the wrong
-- instrument is selected - Instrument/tuning can drift out of sync
-- (tuning matches Shamisen's Honchoshi but the Instrument dropdown still
-- says Guitar, for instance - exactly what caused a rest-rendering bug
-- report before this existed). Returns two lines: a title ("Guitar - 8
-- string" / "Shamisen", omitting the string count for Shamisen per how
-- this was requested) and the per-string tuning, LOW string first
-- (reverse of config.tuning's own high-first storage order - this listing
-- is deliberately lowest-to-highest, left to right, per how it was
-- requested), each prefixed with its string number in parentheses - a
-- circled number would be the more polished look, but isn't guaranteed to
-- be in ReaImGui's default font (same reasoning as this app's other
-- placeholder glyphs - e.g. the plain "#"/"b" accidentals - so this
-- sticks to the always-renders fallback). The number itself still matches
-- config.tuning's own index (i.e. the "String N" fields' own numbering,
-- String 1 = highest), not this line's left-to-right reading order, so it
-- cross-references correctly against the edit fields and the note-editor
-- popup's string selector - it counts DOWN left to right here as a result
-- (lowest string is the highest-numbered one).
function M.instrument_summary(cfg)
  local name = cfg.instrument or "Guitar"
  local title = name
  if name ~= "Shamisen" then
    title = string.format("%s - %d string", name, #cfg.tuning)
  end

  local n = #cfg.tuning
  local parts = {}
  for i = 1, n do
    local string_idx = n - i + 1
    parts[i] = string.format("(%d) %s", string_idx, M.pitch_to_name(cfg.tuning[string_idx]))
  end

  return title, "Tuning: " .. table.concat(parts, " ")
end

-- Delegates to notation_model.pitch_to_name (moved there so draw_tab.lua/
-- draw_notation.lua can share the exact same spelling for the "show note
-- names" cheat-sheet overlay without requiring ui_chrome.lua themselves -
-- ui_chrome.lua already requires draw_notation.lua, so the reverse would
-- be a circular require). Kept as its own function here since note_editor.
-- lua and this file's own tuning-field code already call it by this name.
function M.pitch_to_name(pitch)
  return notation_model.pitch_to_name(pitch)
end

-- "E2", "f#1", " C#-1 " -> MIDI pitch, or nil if it doesn't parse (e.g.
-- still mid-edit). Same octave convention as pitch_to_name/notation_model
-- (octave 4 contains middle C = 60).
function M.name_to_pitch(name)
  local letter, sharp, octave = name:match("^%s*([A-Ga-g])(#?)(%-?%d+)%s*$")
  if not letter then return nil end
  local semitone = LETTER_SEMITONE[letter:upper()]
  if sharp == "#" then semitone = semitone + 1 end
  return (tonumber(octave) + 1) * 12 + semitone
end

local function copy_array(t)
  local out = {}
  for i = 1, #t do out[i] = t[i] end
  return out
end

-- "C major / A minor (no sharps/flats)" / "G major / E minor (1#)" /
-- "F major / D minor (1b)".
local function key_label(k)
  if k.count == 0 then
    return string.format("%s major / %s minor (no sharps/flats)", k.name, k.relative_minor)
  end
  local n = math.abs(k.count)
  local symbol = k.count > 0 and "#" or "b"
  return string.format("%s major / %s minor (%d%s)", k.name, k.relative_minor, n, symbol)
end

-- The exact key-signature wording for cfg.key_count - shared by M.draw's
-- own "Key Signature" summary line and score_render.lua's printed score
-- header (M.instrument_summary/this together are the "guitar, tuning, and
-- key" info both places show), so the two never disagree about how a key
-- is described.
function M.current_key_label(cfg)
  local current = nil
  for _, k in ipairs(notation_model.KEYS) do
    if k.count == (cfg.key_count or 0) then current = k end
  end
  current = current or notation_model.KEYS[1]
  return key_label(current)
end

-- config.layout.left_margin has to grow with the key signature's own
-- width (more accidentals = more room needed before the first note) -
-- draw_notation.lua owns the actual glyph geometry that determines how
-- much, so this just defers to it. Called whenever key_count changes,
-- including at startup after load_persisted.
local function apply_key_margin(cfg)
  cfg.layout.left_margin = draw_notation.left_margin_for_key(cfg.key_count or 0)
end

-- The preset name matching the current tuning exactly, or "Custom" if none
-- do (including right after any manual per-string edit) - this is how the
-- preset dropdown "auto-switches to Custom" with no separate flag needed.
local function detect_preset(tuning)
  local list = PRESETS[#tuning]
  if list then
    for _, p in ipairs(list) do
      if #p.tuning == #tuning then
        local match = true
        for i = 1, #tuning do
          if p.tuning[i] ~= tuning[i] then
            match = false
            break
          end
        end
        if match then return p.name end
      end
    end
  end
  return "Custom"
end

-- Resizes tuning to exactly n strings: truncates from the low end, or
-- extends by adding new lower strings a perfect fourth below the previous
-- lowest (matching the convention real extended-range tunings already
-- follow - see PRESETS above).
local function resize_tuning(tuning, n)
  local out = {}
  for i = 1, math.min(n, #tuning) do out[i] = tuning[i] end
  for i = #tuning + 1, n do out[i] = out[i - 1] - 5 end
  return out
end

function M.save_persisted(cfg)
  local parts = {}
  for i = 1, #cfg.tuning do parts[i] = tostring(cfg.tuning[i]) end
  reaper.SetExtState(EXT_SECTION, "tuning", table.concat(parts, ","), true)
  reaper.SetExtState(EXT_SECTION, "capo", tostring(cfg.capo), true)
  reaper.SetExtState(EXT_SECTION, "key_count", tostring(cfg.key_count or 0), true)
  reaper.SetExtState(EXT_SECTION, "max_fret", tostring(cfg.max_fret), true)
  reaper.SetExtState(EXT_SECTION, "instrument", cfg.instrument or "Guitar", true)
  -- Colors are a global display preference (not an instrument/tuning
  -- property), so unlike the fields above they're only ever saved here -
  -- there's no save_for_take counterpart for them.
  reaper.SetExtState(EXT_SECTION, "color_bg", tostring(cfg.color_bg), true)
  reaper.SetExtState(EXT_SECTION, "color_fg", tostring(cfg.color_fg), true)
  -- Same "global display preference, no per-take save" treatment as colors
  -- above - see config.lua's header.
  reaper.SetExtState(EXT_SECTION, "show_note_names", cfg.show_note_names and "1" or "0", true)
  reaper.SetExtState(EXT_SECTION, "print_scale", tostring(cfg.print_scale or 0.4), true)
  -- Composer/arranger are the one "last used globally" convenience that
  -- makes sense for score-header info - see config.lua's header. title is
  -- piece-specific and deliberately has no global fallback, so it's saved
  -- only in save_for_take, below.
  reaper.SetExtState(EXT_SECTION, "composer", cfg.composer or "", true)
  reaper.SetExtState(EXT_SECTION, "arranger", cfg.arranger or "", true)
end

-- Applies any persisted tuning/capo over config's defaults. Call once at
-- script startup, before the first frame - main.lua's cached render model
-- is built from config.tuning/config.capo on the very first hash check
-- (last_hash starts nil), so this has to land before that.
function M.load_persisted(cfg)
  local tuning_str = reaper.GetExtState(EXT_SECTION, "tuning")
  if tuning_str and tuning_str ~= "" then
    local tuning = {}
    for token in tuning_str:gmatch("[^,]+") do
      local n = tonumber(token)
      if n then table.insert(tuning, n) end
    end
    if #tuning >= MIN_STRINGS and #tuning <= MAX_STRINGS then
      cfg.tuning = tuning
    end
  end

  local capo_str = reaper.GetExtState(EXT_SECTION, "capo")
  if capo_str and capo_str ~= "" then
    local n = tonumber(capo_str)
    if n then cfg.capo = n end
  end

  local key_str = reaper.GetExtState(EXT_SECTION, "key_count")
  if key_str and key_str ~= "" then
    local n = tonumber(key_str)
    if n then cfg.key_count = n end
  end

  local max_fret_str = reaper.GetExtState(EXT_SECTION, "max_fret")
  if max_fret_str and max_fret_str ~= "" then
    local n = tonumber(max_fret_str)
    if n then cfg.max_fret = n end
  end

  local instrument_str = reaper.GetExtState(EXT_SECTION, "instrument")
  if instrument_str and instrument_str ~= "" then
    cfg.instrument = instrument_str
  end

  local bg_str = reaper.GetExtState(EXT_SECTION, "color_bg")
  if bg_str and bg_str ~= "" then
    local n = tonumber(bg_str)
    if n then cfg.color_bg = n end
  end

  local fg_str = reaper.GetExtState(EXT_SECTION, "color_fg")
  if fg_str and fg_str ~= "" then
    local n = tonumber(fg_str)
    if n then cfg.color_fg = n end
  end

  local show_names_str = reaper.GetExtState(EXT_SECTION, "show_note_names")
  if show_names_str ~= "" then
    cfg.show_note_names = (show_names_str == "1")
  end

  local print_scale_str = reaper.GetExtState(EXT_SECTION, "print_scale")
  if print_scale_str and print_scale_str ~= "" then
    local n = tonumber(print_scale_str)
    if n then cfg.print_scale = n end
  end

  local composer_str = reaper.GetExtState(EXT_SECTION, "composer")
  if composer_str and composer_str ~= "" then
    cfg.composer = composer_str
  end

  local arranger_str = reaper.GetExtState(EXT_SECTION, "arranger")
  if arranger_str and arranger_str ~= "" then
    cfg.arranger = arranger_str
  end

  apply_key_margin(cfg)
end

-- Per-take persistence: the ExtState above is a single GLOBAL "last used"
-- fallback shared across every project/item, so switching from a guitar
-- take to a shamisen take (or just a differently-tuned guitar take) never
-- remembered which was which - whatever was last touched anywhere applied
-- to everything. This instead saves/loads the same fields on the MIDI
-- take ITSELF, via REAPER's own per-take persistent-data mechanism
-- (P_EXT:xyz - a plain string, saved with the project, documented as
-- exactly this: "extension-specific persistent data"), so a specific take
-- remembers its own instrument/tuning independent of any other.
--
-- Packed into one delimited string rather than one ExtState-style key per
-- field, since P_EXT only holds a single string per key per take (not a
-- whole namespaced section the way ExtState's section+key model does).
local TAKE_EXT_KEY = "P_EXT:reaper-tab-notation"

-- Score-header fields (config.lua's header) get their OWN separate P_EXT
-- keys instead of joining TAKE_EXT_KEY's packed string above: they're free
-- text a user might type a ";" or "=" into, which the packed format's own
-- delimiters can't safely round-trip. A dedicated key per field sidesteps
-- that entirely - no escaping needed since each one is just its own raw
-- string.
local TAKE_EXT_TITLE = "P_EXT:reaper-tab-notation-title"
local TAKE_EXT_COMPOSER = "P_EXT:reaper-tab-notation-composer"
local TAKE_EXT_ARRANGER = "P_EXT:reaper-tab-notation-arranger"

local function serialize_for_take(cfg)
  local tuning_parts = {}
  for i = 1, #cfg.tuning do tuning_parts[i] = tostring(cfg.tuning[i]) end
  return string.format(
    "instrument=%s;tuning=%s;capo=%d;max_fret=%d;key_count=%d",
    cfg.instrument or "Guitar", table.concat(tuning_parts, ","), cfg.capo, cfg.max_fret, cfg.key_count or 0)
end

local function deserialize_for_take(cfg, str)
  local instrument = str:match("instrument=([^;]+)")
  if instrument then cfg.instrument = instrument end

  local tuning_str = str:match("tuning=([^;]+)")
  if tuning_str then
    local tuning = {}
    for token in tuning_str:gmatch("[^,]+") do
      local n = tonumber(token)
      if n then table.insert(tuning, n) end
    end
    if #tuning >= MIN_STRINGS and #tuning <= MAX_STRINGS then
      cfg.tuning = tuning
    end
  end

  local capo = tonumber(str:match("capo=(%-?%d+)"))
  if capo then cfg.capo = capo end

  local max_fret = tonumber(str:match("max_fret=(%d+)"))
  if max_fret then cfg.max_fret = max_fret end

  local key_count = tonumber(str:match("key_count=(%-?%d+)"))
  if key_count then cfg.key_count = key_count end
end

-- Saves cfg's current instrument/tuning/capo/max_fret/key_count onto
-- take's own persistent data - called alongside save_persisted, same
-- trigger (any settings-panel change), so a take always remembers
-- whatever was last set while it was the active one.
function M.save_for_take(take, cfg)
  if not take then return end
  reaper.GetSetMediaItemTakeInfo_String(take, TAKE_EXT_KEY, serialize_for_take(cfg), true)
  reaper.GetSetMediaItemTakeInfo_String(take, TAKE_EXT_TITLE, cfg.title or "", true)
  reaper.GetSetMediaItemTakeInfo_String(take, TAKE_EXT_COMPOSER, cfg.composer or "", true)
  reaper.GetSetMediaItemTakeInfo_String(take, TAKE_EXT_ARRANGER, cfg.arranger or "", true)
end

-- Loads take's own settings onto cfg, overriding whatever's currently
-- active - call whenever the ACTIVE TAKE ITSELF changes (a different item
-- got selected), not on every note-hash change (which fires for edits to
-- the SAME take too). A take with nothing saved (never configured, or
-- created before this existed) is left alone entirely - whatever's
-- currently active stays in effect rather than snapping to a hardcoded
-- default, the same "no surprise reset" reasoning as the ExtState
-- fallback this sits alongside. Returns true if it actually changed
-- anything, for the caller's own cache-invalidation signal.
function M.load_for_take(take, cfg)
  if not take then return false end
  local changed = false

  local ok, str = reaper.GetSetMediaItemTakeInfo_String(take, TAKE_EXT_KEY, "", false)
  if ok and str ~= "" then
    deserialize_for_take(cfg, str)
    apply_key_margin(cfg)
    changed = true
  end

  -- title is piece-specific (see config.lua's header) - a take with none
  -- saved gets a blank one, not whatever the previously active take
  -- happened to show, unlike the "leave it alone" rule everything else in
  -- this function follows. Read unconditionally (not gated behind the
  -- packed key above) since a user might set a title without ever
  -- touching instrument/tuning.
  local ok_title, title = reaper.GetSetMediaItemTakeInfo_String(take, TAKE_EXT_TITLE, "", false)
  cfg.title = (ok_title and title) or ""

  -- composer/arranger DO inherit whatever's already active (the global
  -- "last used" fallback from load_persisted, or another take's value) if
  -- this take never set its own - see config.lua's header for why.
  local ok_c, composer = reaper.GetSetMediaItemTakeInfo_String(take, TAKE_EXT_COMPOSER, "", false)
  if ok_c and composer ~= "" then cfg.composer = composer end
  local ok_a, arranger = reaper.GetSetMediaItemTakeInfo_String(take, TAKE_EXT_ARRANGER, "", false)
  if ok_a and arranger ~= "" then cfg.arranger = arranger end

  return changed
end

-- Per-string InputText buffers, keyed by string index, so a note name
-- mid-edit (e.g. "E" before the octave digit lands) can be typed freely
-- without being clobbered every frame by re-formatting config.tuning[i] -
-- only a successfully-parsed edit ever writes back into config.tuning.
local string_buf = {}
local buffers_initialized = false

local function sync_buffers(tuning)
  for i = 1, #tuning do
    string_buf[i] = M.pitch_to_name(tuning[i])
  end
  for i = #tuning + 1, #string_buf do
    string_buf[i] = nil
  end
end

-- Print/export path field state - a plain module-level buffer (not saved
-- to cfg/ExtState, unlike everything else this file persists) since it's
-- a one-shot destination for the NEXT export, not a setting worth
-- remembering across sessions the way instrument/tuning/colors are.
local export_path_buf = nil
local export_status = nil -- { ok = bool, message = string } from the last export attempt, or nil before any attempt this session

-- "Revert All Manual Changes" status - same pattern as export_status
-- above (a one-shot message from the last click, not a persisted field).
local revert_status = nil
local REVERT_CONFIRM_POPUP_ID = "ui_chrome_revert_confirm_popup" -- "are you sure?" gate in front of the actual revert - see M.draw_score_settings

-- Edit Mode (tab_editor.lua): toggles the tab staff between today's View
-- Mode (note_editor.lua's click-to-correct popup, unchanged) and a new
-- surface for creating/deleting notes directly. Module-local, not
-- persisted to ExtState/take like the settings above - every fresh
-- script start opens in View Mode (false) so a session never opens
-- silently armed to write MIDI on a stray staff click.
local edit_mode = false

-- A best-effort starting point for the path field: the current project's
-- own folder (reaper.GetProjectPath, pcall-guarded since this isn't a
-- function this codebase has called before and it's not worth a hard
-- failure if its exact signature ever differs) plus a filename derived
-- from the score's own title, falling back to just the bare filename
-- (relative to REAPER's own working directory) if the project path isn't
-- available - e.g. an unsaved project.
local function default_export_path(cfg)
  local name = (cfg.title and cfg.title ~= "") and cfg.title or "tab"
  name = name:gsub('[\\/:*?"<>|]', "_") -- strip characters a filename can't safely contain
  local dir = ""
  local ok, path = pcall(reaper.GetProjectPath)
  if ok and path and path ~= "" then
    local last = path:sub(-1)
    dir = path .. ((last == "\\" or last == "/") and "" or "\\")
  end
  return dir .. name .. ".pdf"
end

-- Draws the "Score Settings" section: score header info (title/composer/
-- arranger, see config.lua's header), instrument preset, string count,
-- tuning preset dropdown, per-string note-name fields, capo, max fret, key
-- signature, colors, and Manual Overrides (Revert All Manual Changes,
-- behind its own confirmation popup) - everything about how the score is
-- CONFIGURED, nested under one outer collapsing header so the whole panel
-- reads as a short menu (Score Settings / Measure Correction Tool / Print
-- & Export / mode toggles - see main.lua for why they're split across
-- three functions instead of staying one monolithic M.draw) rather than
-- five separate top-level sections competing for space. Each piece keeps
-- its own nested CollapsingHeader (Dear ImGui nests these fine), so
-- collapsing "Score Settings" itself hides all of them at once, and each
-- can still be individually expanded/collapsed within it.
-- The instrument/tuning/key summary itself (M.instrument_summary/M.
-- current_key_label) is drawn by the CALLER, not here - score_render.lua's
-- own header (both the live view and the printed page) reuses the exact
-- same two functions, so every place this info shows up is worded
-- identically.
-- Returns true if anything changed this frame - callers should treat that
-- as "please recompute," alongside their own note-hash check (see header
-- comment: none of these settings touch the MIDI take directly - except
-- Revert All Manual Changes, which does, and reports its own change via
-- on_revert_all's return, folded into this same return value).
-- take: the currently active take (may be nil, e.g. nothing selected) -
-- used only to also save_for_take on a change, so this specific item
-- remembers it; safe to pass nil, that save just no-ops.
-- on_revert_all: optional function() -> did_something (boolean), called
-- once the user confirms the "Revert All Manual Changes" prompt - main.lua
-- supplies note_editor.revert_all closed over the current take, since this
-- UI-only module has no business touching the MIDI take directly. Omit it
-- and the button still draws but does nothing once confirmed.
function M.draw_score_settings(ctx, cfg, take, on_revert_all)
  if not buffers_initialized then
    sync_buffers(cfg.tuning)
    buffers_initialized = true
  end

  local changed = false

  if not reaper.ImGui_CollapsingHeader(ctx, "Score Settings", nil) then
    return changed
  end

  -- Indented for the rest of this function (one Unindent right before the
  -- final save/return below) so the five sub-sections read as visually
  -- nested under "Score Settings" rather than flush with it - Dear ImGui's
  -- CollapsingHeader doesn't indent its own body by default, which made
  -- the whole panel read as one flat list of headers regardless of
  -- nesting. Each sub-section ALSO indents its own body one further level
  -- (see each one below), so a field reads as belonging to e.g. "Score
  -- Info" specifically, not just "somewhere under Score Settings."
  reaper.ImGui_Indent(ctx)

  if reaper.ImGui_CollapsingHeader(ctx, "Score Info", nil) then
    reaper.ImGui_Indent(ctx)
    local rv_title, new_title = reaper.ImGui_InputText(ctx, "Title", cfg.title or "")
    if rv_title then
      cfg.title = new_title
      changed = true
    end

    local rv_composer, new_composer = reaper.ImGui_InputText(ctx, "Composer", cfg.composer or "")
    if rv_composer then
      cfg.composer = new_composer
      changed = true
    end

    local rv_arranger, new_arranger = reaper.ImGui_InputText(ctx, "Arranger", cfg.arranger or "")
    if rv_arranger then
      cfg.arranger = new_arranger
      changed = true
    end
    reaper.ImGui_Unindent(ctx)
  end

  if reaper.ImGui_CollapsingHeader(ctx, "Instrument Settings", nil) then
    reaper.ImGui_Indent(ctx)
    cfg.instrument = cfg.instrument or "Guitar"
    if reaper.ImGui_BeginCombo(ctx, "Instrument", cfg.instrument) then
      for _, instrument in ipairs(INSTRUMENTS) do
        local is_selected = (instrument.name == cfg.instrument)
        if reaper.ImGui_Selectable(ctx, instrument.name, is_selected) then
          cfg.instrument = instrument.name
          cfg.tuning = copy_array(instrument.tuning)
          cfg.max_fret = instrument.max_fret
          sync_buffers(cfg.tuning)
          changed = true
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    reaper.ImGui_Separator(ctx)

    local n = #cfg.tuning

    local rv_n, new_n = reaper.ImGui_InputInt(ctx, "String Count", n, 1)
    if rv_n then
      new_n = math.max(MIN_STRINGS, math.min(MAX_STRINGS, new_n))
      if new_n ~= n then
        cfg.tuning = resize_tuning(cfg.tuning, new_n)
        sync_buffers(cfg.tuning)
        changed = true
        n = new_n
      end
    end

    local current_preset = detect_preset(cfg.tuning)
    if reaper.ImGui_BeginCombo(ctx, "Tuning Preset", current_preset) then
      local list = PRESETS[n] or {}
      for _, p in ipairs(list) do
        local is_selected = (p.name == current_preset)
        if reaper.ImGui_Selectable(ctx, p.name, is_selected) then
          cfg.tuning = copy_array(p.tuning)
          sync_buffers(cfg.tuning)
          changed = true
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    for i = 1, n do
      local rv_s, new_text = reaper.ImGui_InputText(ctx, "String " .. i, string_buf[i] or "")
      if rv_s then
        string_buf[i] = new_text
        local pitch = M.name_to_pitch(new_text)
        if pitch then
          cfg.tuning[i] = pitch
          changed = true
        end
      end
    end

    local rv_capo, new_capo = reaper.ImGui_InputInt(ctx, "Capo", cfg.capo, 1)
    if rv_capo then
      new_capo = math.max(0, math.min(MAX_CAPO, new_capo))
      if new_capo ~= cfg.capo then
        cfg.capo = new_capo
        changed = true
      end
    end

    local rv_fret, new_fret = reaper.ImGui_InputInt(ctx, "Max Fret", cfg.max_fret, 1)
    if rv_fret then
      new_fret = math.max(MIN_MAX_FRET, math.min(MAX_MAX_FRET, new_fret))
      if new_fret ~= cfg.max_fret then
        cfg.max_fret = new_fret
        changed = true
      end
    end
    reaper.ImGui_Unindent(ctx)
  end

  if reaper.ImGui_CollapsingHeader(ctx, "Key Signature", nil) then
    reaper.ImGui_Indent(ctx)
    local current_key_count = cfg.key_count or 0
    local current_key = nil
    for _, k in ipairs(notation_model.KEYS) do
      if k.count == current_key_count then current_key = k end
    end
    current_key = current_key or notation_model.KEYS[1]

    if reaper.ImGui_BeginCombo(ctx, "Key", key_label(current_key)) then
      for _, k in ipairs(notation_model.KEYS) do
        local is_selected = (k.count == current_key_count)
        if reaper.ImGui_Selectable(ctx, key_label(k), is_selected) then
          cfg.key_count = k.count
          apply_key_margin(cfg)
          changed = true
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    reaper.ImGui_Unindent(ctx)
  end

  if reaper.ImGui_CollapsingHeader(ctx, "Score Color Scheme", nil) then
    reaper.ImGui_Indent(ctx)
    local bg_changed, new_bg = reaper.ImGui_ColorEdit4(ctx, "Background", cfg.color_bg)
    if bg_changed then
      cfg.color_bg = new_bg
      changed = true
    end
    -- Single foreground color for everything else (noteheads, stems,
    -- text, staff/tab lines) - see color_util.lua for how secondary/dimmed
    -- elements (barlines, ties, labels) derive from just these two colors
    -- rather than needing their own settings.
    local fg_changed, new_fg = reaper.ImGui_ColorEdit4(ctx, "Foreground (text, staff, tab)", cfg.color_fg)
    if fg_changed then
      cfg.color_fg = new_fg
      changed = true
    end
    reaper.ImGui_Unindent(ctx)
  end

  if reaper.ImGui_CollapsingHeader(ctx, "Manual Overrides", nil) then
    reaper.ImGui_Indent(ctx)
    reaper.ImGui_TextWrapped(ctx,
      "Clears every manual string/fret pin and shamisen technique tag on this take, letting the heuristic " ..
      "re-decide everything. One REAPER undo step - Ctrl+Z brings it all back.")
    -- Gated behind a confirmation popup rather than acting the instant
    -- the button is clicked - this wipes every manual correction on the
    -- take at once, the kind of broad, hard-to-notice-until-later action
    -- worth an explicit "are you sure" even though it's undoable.
    if reaper.ImGui_Button(ctx, "Revert All Manual Changes") then
      reaper.ImGui_OpenPopup(ctx, REVERT_CONFIRM_POPUP_ID)
    end
    if reaper.ImGui_BeginPopup(ctx, REVERT_CONFIRM_POPUP_ID) then
      reaper.ImGui_Text(ctx, "Revert all manual string/fret pins and technique tags?")
      reaper.ImGui_TextWrapped(ctx, "The fret-assignment heuristic will re-decide everything.\nThis can be undone with Ctrl+Z.")
      if reaper.ImGui_Button(ctx, "Revert") then
        if on_revert_all then
          local did_something = on_revert_all()
          revert_status = did_something and "Reverted." or "Nothing to revert - no manual pins or technique tags on this take."
        else
          revert_status = "Reverting isn't wired up."
        end
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Cancel") then
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_EndPopup(ctx)
    end
    if revert_status then
      reaper.ImGui_TextWrapped(ctx, revert_status)
    end
    reaper.ImGui_Unindent(ctx)
  end

  reaper.ImGui_Unindent(ctx)

  if changed then
    M.save_persisted(cfg)
    M.save_for_take(take, cfg)
  end

  return changed
end

-- Draws the "Print / Export" section - output path, print scale, and the
-- Export to PDF button/status. Split out of the old monolithic M.draw so
-- main.lua can position it between Measure Correction Tool and the Edit
-- Mode/Show Note Names toggles (see main.lua's own comment for why that
-- ordering matters and why this can't just live inside M.draw_score_
-- settings).
-- on_export: optional function(filepath) -> ok, message, called when the
-- "Export to PDF" button is clicked - main.lua supplies this, closing over
-- its own cached render model/ctx (pdf_export.lua's actual export function
-- needs both, neither of which this UI-only module has any business
-- knowing about). Omit it (or pass nil) and the section still draws but
-- the button just does nothing - safe for any future caller that doesn't
-- wire printing up yet.
function M.draw_print_export(ctx, cfg, on_export)
  if not reaper.ImGui_CollapsingHeader(ctx, "Print / Export", nil) then
    return
  end
  reaper.ImGui_Indent(ctx)

  if not export_path_buf then
    export_path_buf = default_export_path(cfg)
  end

  local rv_path, new_path = reaper.ImGui_InputText(ctx, "Output Path", export_path_buf)
  if rv_path then
    export_path_buf = new_path
  end

  -- Trades text/notehead size against measures-per-line - see config.lua's
  -- print_scale comment for what pdf_export.lua does with this. Range
  -- floors at 0.15 (well past the point of legibility, but still a finite
  -- page) and caps at 1.0 (this app's own on-screen pixel size - going
  -- higher would only reproduce the original "prints out massive" problem
  -- this field exists to fix).
  local rv_scale, new_scale = reaper.ImGui_SliderDouble(ctx, "Print Scale", cfg.print_scale or 0.4, 0.15, 1.0, "%.2f")
  if rv_scale then
    cfg.print_scale = new_scale
    M.save_persisted(cfg)
  end

  if reaper.ImGui_Button(ctx, "Export to PDF") then
    local path = export_path_buf
    if not path:lower():match("%.pdf$") then path = path .. ".pdf" end
    if on_export then
      local ok, message = on_export(path)
      export_status = { ok = ok, message = message or (ok and ("Saved to " .. path) or "Export failed") }
    else
      export_status = { ok = false, message = "Printing isn't wired up." }
    end
  end

  if export_status then
    -- Fixed status colors (not this app's own foreground/background
    -- palette) - a status message is chrome, not part of the printed
    -- score itself, so it doesn't need to track the Colors section.
    local status_color = export_status.ok and 0x60FF60FF or 0xFF6060FF
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), status_color)
    reaper.ImGui_TextWrapped(ctx, export_status.message)
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Unindent(ctx)
end

-- Draws Edit Mode and Show Note Names on ONE row, last in the settings
-- panel - both are quick, frequently-flipped toggles rather than one-time
-- setup fields, so neither is tucked in a collapsing section, and they
-- share a row (via SameLine) rather than each taking a full line.
-- Returns edit_mode (boolean) - whether the tab staff is currently in Edit
-- Mode (tab_editor.lua) rather than View Mode (note_editor.lua) - the
-- caller uses this to pick which module's check_system runs on a staff
-- click each frame (see main.lua). Unlike M.draw_score_settings, this has
-- no "please recompute" return: edit_mode only decides which module gets
-- clicks (no render-model impact), and show_note_names is read live at
-- DRAW TIME by draw_tab.lua/draw_notation.lua/score_render.lua, never
-- baked into cached_render_model - so there's nothing here a caller would
-- ever need to treat as a cache-invalidation signal.
-- take: passed through only to save_for_take when Show Note Names
-- changes, same as every other persisted field - safe to pass nil.
function M.draw_mode_toggles(ctx, cfg, take)
  -- Module-local edit_mode, not persisted to ExtState/take (see its own
  -- comment above) - every fresh script start opens in View Mode so a
  -- session never opens silently armed to write MIDI on a stray staff
  -- click.
  local edit_mode_changed, new_edit_mode = reaper.ImGui_Checkbox(ctx, "Edit Mode (create/delete notes)", edit_mode)
  if edit_mode_changed then
    edit_mode = new_edit_mode
  end

  reaper.ImGui_SameLine(ctx)

  local nn_changed, new_show_note_names = reaper.ImGui_Checkbox(ctx, "Show Note Names", cfg.show_note_names or false)
  if nn_changed then
    cfg.show_note_names = new_show_note_names
    M.save_persisted(cfg)
    M.save_for_take(take, cfg)
  end

  return edit_mode
end

return M
