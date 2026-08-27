-- Edit Mode, Phase 1: click an empty tab-staff position to create a note
-- (type a fret number at a fixed grid duration), or click an existing note
-- to delete it. Coexists with (doesn't replace) note_editor.lua's View
-- Mode click-to-correct popup - main.lua branches which module's
-- check_system runs on a staff click based on ui_chrome.lua's Edit Mode
-- toggle. Phase 2 (drag-to-resize duration) is a separate, later effort -
-- see the plan; this module only ever writes a note at a single fixed
-- duration (config.layout.edit_grid_ticks).
--
-- Locating a click: layout_engine.lua's M.x_for_tick already gives a
-- correct tick->x (forward), but duration-class spacing isn't time-
-- proportional, so inverting it directly for an arbitrary click x would be
-- approximate at best. Instead this enumerates the fixed grid's candidate
-- ticks across the clicked system and reuses the existing, already-correct
-- forward function to find each one's x, picking whichever is closest to
-- the click - no new inverse math, no risk of it disagreeing with how
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
-- a short last system doesn't silently snap to its last grid tick.
--
-- Collision handling is refuse-only, never truncate: checked against RAW
-- MIDI note spans (assigned_events' startppq/endppq - fret_heuristic.
-- assign_events' output, passed in via begin_frame), not the render
-- model's duration_ticks, which is a notation-only gap-capped value, not a
-- note's real sustain (layout_engine.lua's own header explains why - see
-- also measure_correction.lua, which established this same precedent for
-- the same reason). If any existing note already occupies the target
-- string within the new note's duration window, placement is refused with
-- a status message rather than silently shortening the new note.
--
-- Write-back: reaper.MIDI_InsertNote(take, selected, muted, startppqpos,
-- endppqpos, chan, pitch, vel, noSortIn) - verified against REAPER's own
-- API docs before use, since this repo had zero existing call sites to
-- copy from (every prior edit in this app is MIDI_SetNote against a known
-- idx). Unlike MIDI_SetNote, an insert hands back no idx for the note it
-- just created - nothing here may read/reuse an idx after the call; the
-- popup closes immediately, and only a fresh midi_read.read_notes next
-- frame could ever identify the new note (not needed in Phase 1). A
-- created note's channel is always the clicked string (an explicit pin),
-- never 0/auto. Delete is the mirror-image: one reaper.MIDI_DeleteNote
-- call against an EXISTING note's already-known idx.

local config = require('config')
local layout_engine = require('layout_engine')

local M = {}

local HIT_RADIUS = 8 -- px - same value as note_editor.lua's own constant; duplicated rather than shared, see this file's header
local CREATE_POPUP_ID = "tab_editor_create_popup"
local DELETE_POPUP_ID = "tab_editor_delete_popup"
local UNDO_ALL = -1 -- Undo_EndBlock's extraflags: -1 = all undo-state flags, the standard idiom (matches note_editor.lua)
local CLICK_SLACK = 20 -- px - horizontal gate margin past a system's own barline_x range

local function round(v)
  return math.floor(v + 0.5)
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
local function finalize_midi_write(take)
  reaper.MIDI_Sort(take)
  local item = reaper.GetMediaItemTake_Item(take)
  reaper.UpdateItemInProject(item)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTake_Track(take), item)
end

-- Per-frame click state (begin_frame..end_frame), mirroring note_editor.
-- lua's own triplet convention - mouse polling is not centralized in this
-- app, each module polls independently.
local mouse_x, mouse_y, clicked = 0, 0, false
local best_existing = nil -- { note, dist } - closest existing-note hit within HIT_RADIUS across every system checked this frame
local best_empty = nil -- { tick, string_idx } - the empty grid cell hit for whichever system's gates passed this frame

local target_take = nil
local collision_events = nil -- assigned_events, for the raw-span occupancy check - see header

local pending_create = nil -- { tick, string_idx } - what the open create popup is placing
local pending_delete = nil -- { note } - what the open delete popup would remove
local fret_input_buf = ""
local focus_fret_input = false
local create_status = nil
local popup_was_open = false

-- Call once per frame before checking any system, right before the loop
-- that draws each system's tab staff. assigned_events is main.lua's
-- cached_assigned_events (fret_heuristic.assign_events' output) - needed
-- for the collision check's raw note spans, not the render model.
function M.begin_frame(ctx, take, assigned_events)
  target_take = take
  collision_events = assigned_events
  mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  clicked = (not popup_was_open) and reaper.ImGui_IsMouseClicked(ctx, 0)
  best_existing = nil
  best_empty = nil
end

-- Grid ticks strictly within [system.tick_lo, system.tick_hi), the ticks a
-- newly created note may snap to in this system. Empty if the system's
-- tick range isn't known/finite (degenerate case - see M.check_system).
local function grid_ticks_for_system(system)
  local ticks = {}
  local grid = config.layout.edit_grid_ticks
  local lo, hi = system.tick_lo, system.tick_hi
  if not lo or not hi or hi == math.huge or hi <= lo then return ticks end
  local t = math.ceil(lo / grid) * grid
  while t < hi do
    ticks[#ticks + 1] = t
    t = t + grid
  end
  return ticks
end

-- x for an arbitrary tick within one system - reuses layout_engine's
-- existing forward tick->x, falling back to x_for_tick_from_boundaries for
-- a system with zero rendered events (an all-rest system), the same case
-- notation_model.detect_rests already has to handle the same way (see
-- layout_engine.lua's own comment on that function).
local function x_for_tick_in_system(system, tick)
  if #system.events > 0 then
    return layout_engine.x_for_tick(system.events, tick)
  end
  return layout_engine.x_for_tick_from_boundaries(system.ticks, system.barline_x, tick)
end

-- Nearest grid tick to click_x_local (already relative to this system's
-- own origin_x), or nil if this system has no candidate grid ticks at all.
local function nearest_grid_tick(system, click_x_local)
  local ticks = grid_ticks_for_system(system)
  if #ticks == 0 then return nil end
  local best_tick, best_dist = nil, nil
  for _, t in ipairs(ticks) do
    local d = math.abs(x_for_tick_in_system(system, t) - click_x_local)
    if not best_dist or d < best_dist then
      best_dist = d
      best_tick = t
    end
  end
  return best_tick
end

-- Call once per system, right after that system's score_render.draw_system
-- call - same slot as note_editor.check_system/measure_correction.
-- check_system. No-ops instantly if this frame had no click.
function M.check_system(origin_x, tab_origin_y, system)
  if not clicked then return end
  local line_height = config.layout.line_height
  local n_strings = #config.tuning

  -- Existing-note radius hit-test (candidate for delete) - identical
  -- convention to note_editor.check_system, checked across every system
  -- this frame the same way it is there.
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
  -- test above).
  local top = tab_origin_y - line_height / 2
  local bottom = tab_origin_y + (n_strings - 1) * line_height + line_height / 2
  if mouse_y < top or mouse_y > bottom then return end

  local xs = system.barline_x
  if #xs == 0 then return end
  local lo_x = origin_x + xs[1] - CLICK_SLACK
  local hi_x = origin_x + xs[#xs] + CLICK_SLACK
  if mouse_x < lo_x or mouse_x > hi_x then return end

  local string_idx = round((mouse_y - tab_origin_y) / line_height) + 1
  string_idx = math.max(1, math.min(n_strings, string_idx))

  local tick = nearest_grid_tick(system, mouse_x - origin_x)
  if not tick then return end

  best_empty = { tick = round(tick), string_idx = string_idx }
end

-- True if any existing note on string_idx overlaps [start_tick, end_tick) -
-- see header for why this reads collision_events (raw MIDI spans), not
-- the render model.
local function string_occupied(string_idx, start_tick, end_tick)
  for i = 1, #collision_events do
    local notes = collision_events[i].notes
    for j = 1, #notes do
      local note = notes[j]
      if note.string == string_idx and note.startppq < end_tick and note.endppq > start_tick then
        return true
      end
    end
  end
  return false
end

local function commit_create(ctx, fret_str)
  local fret = tonumber(fret_str)
  if not fret then
    create_status = "Enter a valid fret number."
    return
  end
  fret = round(fret)
  if fret < 0 or fret > config.max_fret then
    create_status = string.format("Fret must be between 0 and %d.", config.max_fret)
    return
  end

  local string_idx = pending_create.string_idx
  local start_tick = pending_create.tick
  local end_tick = start_tick + config.layout.edit_grid_ticks

  if string_occupied(string_idx, start_tick, end_tick) then
    create_status = "A note already exists on this string here."
    return
  end

  local pitch = math.max(0, math.min(127, config.tuning[string_idx] + config.capo + fret))

  reaper.Undo_BeginBlock()
  reaper.MIDI_InsertNote(
    target_take, false, false, start_tick, end_tick, string_idx, pitch, config.edit_default_velocity, false)
  finalize_midi_write(target_take)
  reaper.Undo_EndBlock("Insert note (tab/notation viewer)", UNDO_ALL)

  pending_create = nil
  reaper.ImGui_CloseCurrentPopup(ctx)
end

local function commit_delete(ctx)
  reaper.Undo_BeginBlock()
  reaper.MIDI_DeleteNote(target_take, pending_delete.note.idx)
  finalize_midi_write(target_take)
  reaper.Undo_EndBlock("Delete note (tab/notation viewer)", UNDO_ALL)

  pending_delete = nil
  reaper.ImGui_CloseCurrentPopup(ctx)
end

local function draw_create_popup(ctx)
  reaper.ImGui_Text(ctx, string.format("New note - String %d", pending_create.string_idx))

  if focus_fret_input then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    focus_fret_input = false
  end

  local flags = reaper.ImGui_InputTextFlags_EnterReturnsTrue() | reaper.ImGui_InputTextFlags_CharsDecimal()
  local rv, new_text = reaper.ImGui_InputText(ctx, "Fret", fret_input_buf, flags)
  fret_input_buf = new_text
  if rv then
    commit_create(ctx, new_text)
    return
  end

  if reaper.ImGui_Button(ctx, "Add") then
    commit_create(ctx, fret_input_buf)
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

local function draw_delete_popup(ctx)
  local note = pending_delete.note
  reaper.ImGui_Text(ctx, string.format("Delete note - String %d, Fret %d?", note.string or 0, note.fret or 0))
  if reaper.ImGui_Button(ctx, "Delete") then
    commit_delete(ctx)
    return
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Cancel") then
    pending_delete = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
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
    pending_delete = { note = best_existing.note }
    pending_create = nil
    create_status = nil
    reaper.ImGui_OpenPopup(ctx, DELETE_POPUP_ID)
  elseif clicked and best_empty then
    pending_create = { tick = best_empty.tick, string_idx = best_empty.string_idx }
    pending_delete = nil
    create_status = nil
    fret_input_buf = ""
    focus_fret_input = true
    reaper.ImGui_OpenPopup(ctx, CREATE_POPUP_ID)
  end

  local create_open = reaper.ImGui_BeginPopup(ctx, CREATE_POPUP_ID)
  if create_open then
    draw_create_popup(ctx)
    reaper.ImGui_EndPopup(ctx)
  end

  local delete_open = reaper.ImGui_BeginPopup(ctx, DELETE_POPUP_ID)
  if delete_open then
    draw_delete_popup(ctx)
    reaper.ImGui_EndPopup(ctx)
  end

  popup_was_open = create_open or delete_open
end

return M
