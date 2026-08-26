-- Phase 6: bounded click-to-edit note correction. The fret-assignment
-- heuristic sometimes picks a musically-wrong string for an otherwise
-- correct pitch, and MIDI has no native "string" field to hold a
-- correction - so this is the write path back into the take. Deliberately
-- narrow scope (see the plan): pitch and string/fret reassignment only.
-- Duration changes, insert/delete, and any drag interaction stay REAPER-
-- piano-roll-only.
--
-- Hit-testing targets the TAB staff specifically (not the notation staff):
-- every playable note already has an unambiguous (x, string-row) position
-- there, which is the natural click target for "which string/fret is
-- this" - no separate bounding-box contract needed from draw_tab.lua,
-- just the same per-string y formula it already uses.
--
-- Each edit is exactly one atomic MIDI_SetNote call, wrapped in its own
-- Undo_BeginBlock/EndBlock (so REAPER's native Ctrl+Z undoes a panel edit
-- like any piano-roll one) and immediately closes the popup rather than
-- staying open for further edits. This sidesteps a real correctness trap:
-- MIDI_SetNote re-sorts the take, which can renumber OTHER notes sharing
-- the same tick (a chord) once their pitch order changes - note.idx (see
-- midi_read.lua) is only guaranteed valid up to the next sort. One edit
-- per click keeps every write using a freshly-verified idx.
--
-- Write-back repurposes MIDI channel as the string pin (see
-- fret_heuristic.lua's header): channel 0 = auto, 1..string_count = pinned
-- string.
--
-- Shamisen only, the popup also offers a technique tag (Sukui, Hajiki,
-- Uchi, Suri, Oshibachi/Suberi, Keshi), stored via midi_read.lua's
-- take-level P_EXT map (see that file's header for why this isn't a MIDI
-- event) - commit_technique reads the take's current map, updates/clears
-- this one note's entry, and writes the whole map back. Since P_EXT
-- changes are invisible to midi_read.get_notes_hash, this module has to
-- signal main.lua's cache-invalidation itself rather than relying on that
-- hash - see technique_changed/end_frame's return value below.

local config = require('config')
local ui_chrome = require('ui_chrome')
local midi_read = require('midi_read')

local M = {}

local HIT_RADIUS = 8 -- px around a fret-number/x's drawn position that counts as a click
local POPUP_ID = "note_editor_popup"
local UNDO_ALL = -1 -- Undo_EndBlock's extraflags: -1 = all undo-state flags, the standard idiom

-- Numbered per the source list this was requested from - the id is this
-- popup's own selection key, and also what draw_tab.lua's TECHNIQUE_SYMBOLS
-- indexes by to pick the real katakana glyph drawn on the tab staff, so
-- the two never disagree about which id means which technique.
local TECHNIQUES = {
  { id = 1, name = "Sukui" },
  { id = 2, name = "Hajiki" },
  { id = 3, name = "Uchi" },
  { id = 4, name = "Suri" },
  { id = 5, name = "Oshibachi/Suberi" },
  { id = 6, name = "Keshi" },
}

-- Per-frame click state (begin_frame..end_frame) and the note currently
-- targeted by an open popup, if any.
local mouse_x, mouse_y, clicked = 0, 0, false
local best = nil -- { note, dist } - closest hit across every system checked this frame
local target = nil -- { take, note } - the note the open popup (if any) is editing
local popup_was_open = false

-- Call once per frame before checking any system, right before the loop
-- that draws each system's tab staff. Captures the click edge-trigger once
-- (rather than re-querying it per system) and suppresses it entirely while
-- the popup is already open this frame - otherwise a click on the popup's
-- own buttons could also register as a stray tab-staff hit underneath it.
function M.begin_frame(ctx)
  mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  clicked = (not popup_was_open) and reaper.ImGui_IsMouseClicked(ctx, 0)
  best = nil
end

-- Call once per system, right after draw_tab.draw for that system - needs
-- the same (origin_x, tab_origin_y) that call was given. No-ops instantly
-- if this frame had no click, so it's cheap to call unconditionally.
function M.check_system(origin_x, tab_origin_y, events)
  if not clicked then return end
  local line_height = config.layout.line_height

  for i = 1, #events do
    local event = events[i]
    local x = origin_x + event.x
    for j = 1, #event.notes do
      local note = event.notes[j]
      if not note.tied_from_prev then
        local string_idx = note.string or config.layout.x_notehead_string
        local y = tab_origin_y + (string_idx - 1) * line_height
        local dx, dy = mouse_x - x, mouse_y - y
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist <= HIT_RADIUS and (not best or dist < best.dist) then
          best = { note = note, dist = dist }
        end
      end
    end
  end
end

-- Writes exactly one field (new_pitch or new_chan, whichever is non-nil)
-- back to the take via MIDI_SetNote, wrapped in its own undo block, then
-- closes the popup - see header for why this doesn't stay open for a
-- second edit against the same target.
local function commit_edit(ctx, new_pitch, new_chan)
  local note = target.note
  local pitch = new_pitch or note.pitch
  local chan = new_chan or note.chan
  pitch = math.max(0, math.min(127, pitch))

  reaper.Undo_BeginBlock()
  reaper.MIDI_SetNote(target.take, note.idx, nil, nil, nil, nil, chan, pitch, nil, nil)
  reaper.Undo_EndBlock("Edit note (tab/notation viewer)", UNDO_ALL)

  target = nil
  reaper.ImGui_CloseCurrentPopup(ctx)
end

-- Set once by commit_technique, read (and reset) by end_frame's return
-- value - this module's own "please recompute" signal, since a P_EXT
-- change is invisible to midi_read.get_notes_hash (see that file's
-- header). Mirrors ui_chrome.draw's own changed-boolean pattern.
local technique_changed = false

-- Sets (technique_id given) or clears (nil) this note's technique tag in
-- the take's technique map (midi_read.lua), then writes the whole map
-- back - P_EXT only holds one string per key per take, not a per-note
-- slot, so every write re-serializes the full map rather than patching a
-- single entry in place.
local function commit_technique(ctx, technique_id)
  local note = target.note
  local take = target.take
  -- Matches midi_read.lua's M.read_notes key construction exactly (same
  -- startppq/chan/pitch values, same .. concatenation) so the two always
  -- agree on this note's key.
  local key = note.startppq .. ":" .. note.chan .. ":" .. note.pitch

  local map = midi_read.read_technique_map(take)
  map[key] = technique_id

  reaper.Undo_BeginBlock()
  reaper.GetSetMediaItemTakeInfo_String(take, midi_read.TECH_EXT_KEY, midi_read.serialize_technique_map(map), true)
  reaper.Undo_EndBlock("Set shamisen technique (tab/notation viewer)", UNDO_ALL)

  technique_changed = true
  target = nil
  reaper.ImGui_CloseCurrentPopup(ctx)
end

local function draw_popup(ctx)
  local note = target.note
  local n_strings = #config.tuning

  reaper.ImGui_Text(ctx, "Pitch: " .. ui_chrome.pitch_to_name(note.pitch))

  if reaper.ImGui_SmallButton(ctx, "-12") then commit_edit(ctx, note.pitch - 12, nil) end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, "-1") then commit_edit(ctx, note.pitch - 1, nil) end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, "+1") then commit_edit(ctx, note.pitch + 1, nil) end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, "+12") then commit_edit(ctx, note.pitch + 12, nil) end

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "String (pin, or Auto for the heuristic to choose):")

  local current_chan = note.chan or 0
  if reaper.ImGui_Selectable(ctx, current_chan == 0 and "Auto (current)" or "Auto", current_chan == 0) then
    commit_edit(ctx, nil, 0)
  end
  for s = 1, n_strings do
    local label = current_chan == s and ("String " .. s .. " (current)") or ("String " .. s)
    if reaper.ImGui_Selectable(ctx, label, current_chan == s) then
      commit_edit(ctx, nil, s)
    end
  end

  if config.instrument == "Shamisen" then
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "Technique:")

    local current_tech = note.technique
    if reaper.ImGui_Selectable(ctx, current_tech == nil and "None (current)" or "None", current_tech == nil) then
      commit_technique(ctx, nil)
    end
    for _, tech in ipairs(TECHNIQUES) do
      local base_label = tech.id .. " - " .. tech.name
      local label = current_tech == tech.id and (base_label .. " (current)") or base_label
      if reaper.ImGui_Selectable(ctx, label, current_tech == tech.id) then
        commit_technique(ctx, tech.id)
      end
    end
  end
end

-- Call once per frame after every system has been checked. Opens the
-- popup for this frame's closest hit (if any), then draws it if it's
-- currently open - the standard ImGui "OpenPopup this frame, BeginPopup
-- every frame" pattern. Returns true exactly once, the frame after a
-- technique commit - callers should treat that as "please recompute,"
-- the same role ui_chrome.draw's own return value plays for settings
-- changes (see this file's header for why a hash check alone can't
-- notice a technique change).
function M.end_frame(ctx, take)
  if clicked and best then
    target = { take = take, note = best.note }
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
  end

  local is_open = reaper.ImGui_BeginPopup(ctx, POPUP_ID)
  if is_open then
    draw_popup(ctx)
    reaper.ImGui_EndPopup(ctx)
  end
  popup_was_open = is_open

  local changed = technique_changed
  technique_changed = false
  return changed
end

return M
