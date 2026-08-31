-- Faint vertical grid lines drawn through both staves (notation and tab),
-- at a fixed rhythmic subdivision (config.grid_denominator/grid_triplet,
-- set via ui_chrome.lua's "Show Grid Lines"/"Grid"/"Triplet" row) -
-- clicking anywhere on a system, at a gridline, seeks playback/the edit
-- cursor there (one reaper.SetEditCurPos2 call, same as clicking REAPER's
-- own ruler). A live-view-only overlay, drawn directly by main.lua after
-- each system's score_render.draw_system call - never touched by pdf_
-- export.lua's print pass, so gridlines never appear on a printed/exported
-- page, the same separation the live playhead line already relies on (see
-- main.lua's own header).
--
-- Grid ticks are anchored to each MEASURE's own start, not a single
-- global tick 0 - the same reasoning notation_model.detect_rests' own
-- beat-alignment uses: a fixed step counted from tick 0 would drift out
-- of alignment with barlines the moment an earlier measure's own length
-- doesn't divide evenly by the grid step (any measure following a time-
-- signature change, in particular). Anchoring per-measure instead keeps
-- every measure's own grid starting exactly on its downbeat regardless of
-- what came before it.
--
-- Click hit-testing spans the WHOLE system (bar_top..bar_bottom - notation
-- staff, gap, and tab staff alike), not just the blank gap between the two
-- staves: an earlier version scoped it to just that gap specifically to
-- avoid colliding with note_editor.lua/tab_editor.lua's own staff hit-
-- testing, but the gap alone turned out to be an unreliably thin target to
-- click (~19-26px). Editing now wins the conflict explicitly instead: the
-- caller (main.lua) passes `consumed`, true whenever note_editor.
-- would_hit_note/tab_editor.would_hit_editable says this same click also
-- matches an existing note or a creatable empty cell - main.lua checks
-- those BEFORE calling here, so a click meant for editing is never also
-- read as a seek.
local config = require('config')
local layout_engine = require('layout_engine')

local M = {}

local mouse_x, mouse_y, clicked = 0, 0, false

-- Call once per frame, before checking any system - mirrors every other
-- click-handling module in this app (note_editor.lua/tab_editor.lua/
-- measure_correction.lua all capture the click edge once up front).
function M.begin_frame(ctx)
  mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  clicked = reaper.ImGui_IsMouseClicked(ctx, 0)
end

-- Ticks per grid subdivision - the same plain "N"/triplet convention
-- tab_editor.lua's own Duration field uses (ticks_for_denominator/
-- ticks_for_triplet_denominator there), reproduced here rather than
-- shared cross-module since it's two lines of arithmetic, not worth a new
-- coupling for.
local function span_ticks(cfg)
  local denom = cfg.grid_denominator or 16
  if denom <= 0 then return nil end
  local straight = 4 * config.layout.ppq_per_quarter / denom
  if cfg.grid_triplet then
    return straight * 2 / 3
  end
  return straight
end

-- Grid tick positions within one system, anchored to each measure's own
-- start (system.ticks - see this file's header for why per-measure, not
-- global).
local function ticks_for_system(system, span)
  local ticks = {}
  local boundaries = system.ticks
  for i = 1, #boundaries - 1 do
    local lo, hi = boundaries[i], boundaries[i + 1]
    local t = lo
    while t < hi do
      ticks[#ticks + 1] = t
      t = t + span
    end
  end
  return ticks
end

-- Call once per system, right after that system's score_render.
-- draw_system call - needs the same (origin_x, bar_top, bar_bottom) that
-- call returned/was given. cfg: main.lua's config, read fresh each call so
-- grid_denominator/grid_triplet changes take effect immediately, no cache
-- to invalidate. consumed: true if this same click already matches an
-- editing target elsewhere (see this file's header) - lines still draw,
-- but the click itself won't seek.
function M.draw_and_check(ctx, draw_list, origin_x, take, system, bar_top, bar_bottom, cfg, color_faint, consumed)
  local span = span_ticks(cfg)
  if not span then return end

  local ticks = ticks_for_system(system, span)
  local click_in_system = clicked and not consumed and mouse_y >= bar_top and mouse_y <= bar_bottom
  local closest_tick, closest_dist = nil, nil

  for _, t in ipairs(ticks) do
    local x = origin_x + layout_engine.x_for_tick_in_system(system, t)
    reaper.ImGui_DrawList_AddLine(draw_list, x, bar_top, x, bar_bottom, color_faint, 1.0)

    if click_in_system then
      local d = math.abs(x - mouse_x)
      if not closest_dist or d < closest_dist then
        closest_dist = d
        closest_tick = t
      end
    end
  end

  if click_in_system and closest_tick then
    local time = reaper.MIDI_GetProjTimeFromPPQPos(take, closest_tick)
    reaper.SetEditCurPos2(0, time, true, true)
  end
end

return M
