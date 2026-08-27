-- "Correct Similar Measures": propagates a manual string/fret correction
-- (note_editor.lua's per-note string pin - MIDI channel 1..string_count,
-- see fret_heuristic.lua's header) from one measure you've just fixed onto
-- every SUBSEQUENT measure that's at least 75% similar to it, instead of
-- repeating the same click-to-correct edit by hand on every repeat of a
-- riff.
--
-- Click-to-select (M.begin_frame/M.check_system, called from main.lua's
-- systems loop the same way note_editor.lua's own hit-testing is) targets
-- a whole MEASURE rather than a note: clicking anywhere within a measure's
-- rendered column on the tab staff (including directly on a note - that's
-- fine, selecting the measure a note you just corrected belongs to is the
-- expected use) sets selected_measure_idx. No popup needed (contrast
-- note_editor.lua) - results are drawn inline in M.draw_panel, called once
-- from main.lua alongside ui_chrome.draw.
--
-- Similarity (see similarity(), below) requires two measures to have the
-- SAME NUMBER OF EVENTS and the SAME NUMBER OF NOTES PER EVENT to be
-- comparable at all - without that there's no reliable way to say which
-- note in one measure corresponds to which note in the other, and the
-- score is 0 (excluded), not partial credit. Within a comparable pair,
-- each note-slot scores on a 50/50 blend of the parent event's relative-
-- tick offset (same rhythmic position within the measure) and the note's
-- own pitch, so a repeated riff with one note changed still scores high
-- rather than being an all-or-nothing match. Notes within one event are
-- paired by ARRAY POSITION, not re-sorted by pitch/string - the same
-- chord played with its notes in a different underlying order would score
-- lower than a human would expect; accepted as a v1 simplification.
--
-- Propagation only ever copies a source note's STRING PIN (its MIDI
-- channel) onto a note at the same (event, note) position in a matched
-- measure, and only when that note's PITCH matches the source's exactly -
-- a differing pitch is left untouched rather than guessed at, since the
-- source's fret might not even be reachable at a different pitch. This is
-- also what makes the whole batch write safe to wrap in a single
-- Undo_BeginBlock/EndBlock: every MIDI_SetNote call here changes chan
-- only, never pitch or position, so it can't trigger the take-resort that
-- would otherwise invalidate a later note's own idx mid-batch (see
-- midi_read.lua/note_editor.lua's header for that risk in the pitch-
-- changing case) - one Ctrl+Z still reverts the whole batch if the match
-- set turns out wrong.
--
-- Operates on assigned_events (fret_heuristic.assign_events' output, the
-- flat post-heuristic/pre-layout event list main.lua also feeds
-- layout_engine.compute) rather than the render model layout_engine
-- produces from it: layout_engine.compute can split a note that crosses a
-- barline into tied segments, which would corrupt this module's "same
-- number of notes per event" comparison and, worse, its note.idx-based
-- write-back (a split segment doesn't correspond 1:1 with a real MIDI
-- note). assigned_events has neither problem - every note in it is a real
-- MIDI note with its own stable idx, exactly what M.apply's MIDI_SetNote
-- calls need.

local M = {}

local SIMILARITY_THRESHOLD = 0.75

-- ---------------------------------------------------------------------
-- Click-to-select
-- ---------------------------------------------------------------------

local mouse_x, mouse_y, clicked = 0, 0, false
local selected_measure_idx = nil -- 1-based, into the whole-take measure list bucket_measures produces
local search_results = nil -- array of {measure_idx, reaper_measure, score}, or nil before a search / after a selection change
local apply_status = nil -- plain string, or nil before any Apply this session

function M.begin_frame(ctx)
  mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  clicked = reaper.ImGui_IsMouseClicked(ctx, 0)
end

-- Call once per system, right after score_render.draw_system for that
-- system - needs the same bar_top/bar_bottom that call returns (the
-- system's own vertical span) and the system table itself (for
-- ticks/barline_x/item_measure_start - see layout_engine.wrap_into_
-- systems). No-ops instantly if this frame had no click, so it's cheap to
-- call unconditionally.
function M.check_system(origin_x, bar_top, bar_bottom, system)
  if not clicked then return end
  if mouse_y < bar_top or mouse_y > bar_bottom then return end

  local xs = system.barline_x
  for m = 1, #xs - 1 do
    local lo_x = origin_x + xs[m]
    local hi_x = origin_x + xs[m + 1]
    if mouse_x >= lo_x and mouse_x < hi_x then
      selected_measure_idx = system.item_measure_start + m - 1
      search_results = nil
      apply_status = nil
      return
    end
  end
end

-- ---------------------------------------------------------------------
-- Measure bucketing
-- ---------------------------------------------------------------------

-- Groups assigned_events (flat, tick-ordered, whole take) into one entry
-- per measure via measure_ticks (notation_model.measure_boundaries'
-- output - n+1 tick boundaries bounding n measures). Cheap single pass
-- since both are already tick-ordered - recomputed fresh whenever the
-- panel needs it rather than cached, matching how the rest of this app
-- treats recompute as cheap at its scale (see main.lua's header).
local function bucket_measures(assigned_events, measure_ticks, measure_info)
  local n_measures = #measure_ticks - 1
  local measures = {}
  for m = 1, n_measures do
    measures[m] = {
      tick_lo = measure_ticks[m],
      tick_hi = measure_ticks[m + 1],
      reaper_measure = (measure_info[m] and measure_info[m].reaper_measure) or m,
      events = {},
    }
  end

  local m = 1
  for i = 1, #assigned_events do
    local event = assigned_events[i]
    while m < n_measures and event.tick >= measure_ticks[m + 1] do
      m = m + 1
    end
    table.insert(measures[m].events, event)
  end

  return measures
end

-- ---------------------------------------------------------------------
-- Similarity
-- ---------------------------------------------------------------------

local function measures_comparable(a, b)
  if #a.events ~= #b.events then return false end
  for i = 1, #a.events do
    if #a.events[i].notes ~= #b.events[i].notes then return false end
  end
  return true
end

-- 0..1 - see this file's header for the timing/pitch blend and the
-- structural-comparability gate. Two full-measure rests (no events at
-- all) score 1.0 - nothing to differ on - though in practice that case
-- never reaches here, since a source measure must have at least one
-- pinned note (pinned_notes, below) to search from at all.
local function similarity(a, b)
  if not measures_comparable(a, b) then return 0 end

  local total, matched = 0, 0
  for i = 1, #a.events do
    local ea, eb = a.events[i], b.events[i]
    local timing_ok = (ea.tick - a.tick_lo) == (eb.tick - b.tick_lo)
    for j = 1, #ea.notes do
      local pitch_ok = ea.notes[j].pitch == eb.notes[j].pitch
      matched = matched + (timing_ok and 0.5 or 0) + (pitch_ok and 0.5 or 0)
      total = total + 1
    end
  end

  if total == 0 then return 1.0 end
  return matched / total
end

-- Notes in `measure` carrying a manual string pin (MIDI channel
-- 1..string_count, not 0/Auto - see fret_heuristic.lua's header) - the
-- actual "corrections" a search propagates. Returns each as its (event,
-- note) POSITION within the measure plus the pinned chan/pitch, not the
-- note table itself, since that position is exactly how the corresponding
-- note in a different, structurally-comparable measure is found.
local function pinned_notes(measure)
  local out = {}
  for i = 1, #measure.events do
    local notes = measure.events[i].notes
    for j = 1, #notes do
      local note = notes[j]
      if note.chan and note.chan >= 1 then
        out[#out + 1] = { event_idx = i, note_idx = j, chan = note.chan, pitch = note.pitch }
      end
    end
  end
  return out
end

-- Matches strictly AFTER source_idx - this feature is framed as "correct
-- OTHER SIMILAR measures" going forward from a just-fixed one, not a
-- general find-similar search in both directions.
local function find_matches(measures, source_idx)
  local source = measures[source_idx]
  local results = {}
  for m = source_idx + 1, #measures do
    local score = similarity(source, measures[m])
    if score >= SIMILARITY_THRESHOLD then
      results[#results + 1] = { measure_idx = m, reaper_measure = measures[m].reaper_measure, score = score }
    end
  end
  return results
end

-- See this file's header for why batching every write into one undo block
-- is safe here (chan-only edits, never pitch/position). Returns the
-- number of notes actually written (a pitch mismatch skips that one note
-- silently - see header).
local function apply_corrections(take, source, target_measures)
  local corrections = pinned_notes(source)
  if #corrections == 0 then return 0 end

  local write_count = 0
  reaper.Undo_BeginBlock()
  for _, target in ipairs(target_measures) do
    for _, c in ipairs(corrections) do
      local t_note = target.events[c.event_idx].notes[c.note_idx]
      if t_note.pitch == c.pitch then
        reaper.MIDI_SetNote(take, t_note.idx, nil, nil, nil, nil, c.chan, t_note.pitch, nil, nil)
        write_count = write_count + 1
      end
    end
  end
  reaper.Undo_EndBlock("Correct similar measures (tab/notation viewer)", -1)
  return write_count
end

-- ---------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------

-- Draws the "Measure Correction Tool" section - call once per frame, e.g.
-- alongside ui_chrome.draw, AFTER main.lua's own recompute block so
-- assigned_events/measure_ticks/measure_info reflect this frame's take.
-- Self-contained: does its own MIDI_SetNote writes (via apply_corrections)
-- rather than returning a "please recompute" signal, since those writes
-- change real MIDI note data, which main.lua's existing note-hash check
-- already notices on its own (contrast note_editor.lua's technique tags,
-- which live outside MIDI events and need their own signal).
function M.draw_panel(ctx, take, assigned_events, measure_ticks, measure_info)
  if not take or not assigned_events or not measure_ticks or #measure_ticks < 2 then
    return
  end

  if not reaper.ImGui_CollapsingHeader(ctx, "Measure Correction Tool", nil) then
    return
  end

  if not selected_measure_idx then
    reaper.ImGui_TextWrapped(
      ctx, "After manually correcting a measure, you can apply those changes to similar measures automatically.")
    return
  end

  local measures = bucket_measures(assigned_events, measure_ticks, measure_info)
  if selected_measure_idx > #measures then
    -- Stale selection - e.g. the take got shorter since this was set.
    selected_measure_idx = nil
    search_results = nil
    return
  end

  local source = measures[selected_measure_idx]
  local corrections = pinned_notes(source)

  reaper.ImGui_Text(ctx, string.format("Selected measure: %d", source.reaper_measure))
  reaper.ImGui_Text(ctx, string.format(
    "%d corrected note%s in this measure", #corrections, #corrections == 1 and "" or "s"))

  if #corrections == 0 then
    reaper.ImGui_TextWrapped(
      ctx, "Pin at least one note's string in this measure (click its fret number) before searching.")
    return
  end

  if reaper.ImGui_Button(ctx, "Find Similar Measures") then
    search_results = find_matches(measures, selected_measure_idx)
    apply_status = nil
  end

  if search_results then
    if #search_results == 0 then
      reaper.ImGui_TextWrapped(ctx, "No measures at least 75% similar found after this one.")
    else
      reaper.ImGui_Text(ctx, string.format(
        "%d match%s found:", #search_results, #search_results == 1 and "" or "es"))
      for _, r in ipairs(search_results) do
        reaper.ImGui_Text(ctx, string.format(
          "  Measure %d - %d%% similar", r.reaper_measure, math.floor(r.score * 100 + 0.5)))
      end

      if reaper.ImGui_Button(ctx, "Apply to All Matches") then
        local targets = {}
        for _, r in ipairs(search_results) do
          targets[#targets + 1] = measures[r.measure_idx]
        end
        local write_count = apply_corrections(take, source, targets)
        apply_status = string.format(
          "Applied %d correction%s across %d measure%s.",
          write_count, write_count == 1 and "" or "s", #targets, #targets == 1 and "" or "s")
        search_results = nil
      end
    end
  end

  if apply_status then
    reaper.ImGui_TextWrapped(ctx, apply_status)
  end
end

return M
