-- Score header + per-system drawing (notation staff, tab staff, barlines,
-- measure/tempo labels), extracted out of main.lua so BOTH the live
-- docked view and pdf_export.lua's print pass call the exact same code -
-- a separate PDF-only reimplementation would inevitably drift from
-- whatever the live renderer does next (a new technique marking, a
-- layout tweak) unless every future change remembered to update two
-- copies. main.lua still owns the parts genuinely specific to the live
-- view - the playhead line, auto-scroll, and the frame's own
-- draw_list/origin (from reaper.ImGui_GetWindowDrawList/
-- GetCursorScreenPos) - none of which mean anything on a printed page.
--
-- Every function here takes color_fg/color_dim as explicit parameters
-- rather than reading config.color_fg/color_bg itself, so pdf_export.lua
-- can pass a print-safe black-ink palette without having to mutate (and
-- later restore) the shared config table's live colors.

local draw_notation = require('draw_notation')
local draw_tab = require('draw_tab')

local M = {}

local BARLINE_NOTE_GAP = 14 -- px a barline is shifted left of its exact tick position, so it doesn't sit on top of the next measure's first note
local FINAL_BARLINE_GAP = 3 -- px between the thin and thick strokes of the piece's closing barline
local FINAL_BARLINE_THICK_WIDTH = 3.0 -- px stroke weight of the final barline's thick stroke
local MEASURE_LABEL_ABOVE_GAP = 14 -- px above the notation staff's top line where the measure-number label sits
local TEMPO_LABEL_ABOVE_GAP = 28 -- px above the notation staff's top line where the tempo label sits (above the measure-number label)
local TOP_MARGIN = 32 -- px reserved above the first system, so its tempo/measure-number labels don't clip against the top edge
local TITLE_FONT_SCALE = 1.8 -- relative to the panel's base text size
local SCORE_INFO_LINE_GAP = 2 -- px between the stacked composer/arranger lines
local SCORE_HEADER_BOTTOM_GAP = 16 -- px between the header block and the first system's own reserved area

local function has_header(cfg)
  return (cfg.title and cfg.title ~= "") or (cfg.composer and cfg.composer ~= "") or (cfg.arranger and cfg.arranger ~= "")
end

-- Computes everything about vertical layout that has to be known BEFORE
-- any drawing happens (every system's position depends on it) - shared by
-- the live view (which needs it once per frame for auto-scroll math too)
-- and pdf_export.lua (which needs it to paginate systems across pages,
-- before it knows which systems even land on which page). Only reads
-- text sizes via ctx - draws nothing.
function M.layout_geometry(ctx, cfg)
  local notation_above, notation_below = draw_notation.vertical_extents()
  local tab_staff_height = (#cfg.tuning - 1) * cfg.layout.line_height
  local system_pitch = notation_above + notation_below + cfg.layout.staff_gap + tab_staff_height + cfg.layout.system_gap

  local base_font_size = reaper.ImGui_GetFontSize(ctx)
  local header_height = 0
  if has_header(cfg) then
    local title_h = (cfg.title and cfg.title ~= "") and (base_font_size * TITLE_FONT_SCALE) or 0
    local side_h = 0
    if cfg.composer and cfg.composer ~= "" then
      local _, h = reaper.ImGui_CalcTextSize(ctx, cfg.composer)
      side_h = side_h + h
    end
    if cfg.arranger and cfg.arranger ~= "" then
      local _, h = reaper.ImGui_CalcTextSize(ctx, "arr. " .. cfg.arranger)
      side_h = side_h + ((cfg.composer and cfg.composer ~= "") and (h + SCORE_INFO_LINE_GAP) or h)
    end
    header_height = math.max(title_h, side_h) + SCORE_HEADER_BOTTOM_GAP
  end

  return {
    notation_above = notation_above,
    notation_below = notation_below,
    tab_staff_height = tab_staff_height,
    system_pitch = system_pitch,
    header_height = header_height,
    -- top_margin: the fixed clearance every page/frame needs above its
    -- OWN first system (so that system's own measure/tempo labels don't
    -- clip against the top edge), separate from header_height (which only
    -- applies once, above the very first system of the whole piece).
    -- pdf_export.lua needs both separately to paginate correctly - every
    -- page after the first starts at top_margin, not top_reserve.
    top_margin = TOP_MARGIN,
    top_reserve = TOP_MARGIN + header_height,
  }
end

-- Draws the title (centered, enlarged) and composer/arranger (stacked,
-- top-right) at (origin_x, origin_y) within max_width - a no-op (draws
-- nothing) if none of the three are set, matching config.lua's "blank by
-- default, no visual change" intent.
function M.draw_header(ctx, draw_list, origin_x, origin_y, cfg, max_width, color_fg, color_dim)
  if not has_header(cfg) then return end

  local base_font_size = reaper.ImGui_GetFontSize(ctx)

  if cfg.title and cfg.title ~= "" then
    local title_size = base_font_size * TITLE_FONT_SCALE
    local scale = title_size / base_font_size
    local w = reaper.ImGui_CalcTextSize(ctx, cfg.title)
    local title_x = origin_x + (max_width - w * scale) / 2
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, title_size, title_x, origin_y, color_fg, cfg.title)
  end

  local side_y = origin_y
  if cfg.composer and cfg.composer ~= "" then
    local w, h = reaper.ImGui_CalcTextSize(ctx, cfg.composer)
    reaper.ImGui_DrawList_AddText(draw_list, origin_x + max_width - w, side_y, color_fg, cfg.composer)
    side_y = side_y + h + SCORE_INFO_LINE_GAP
  end
  if cfg.arranger and cfg.arranger ~= "" then
    local arranger_text = "arr. " .. cfg.arranger
    local w = reaper.ImGui_CalcTextSize(ctx, arranger_text)
    reaper.ImGui_DrawList_AddText(draw_list, origin_x + max_width - w, side_y, color_dim, arranger_text)
  end
end

-- Draws ONE system: notation staff, tab staff, barlines (with the final
-- thin+thick closing pair when this is truly the LAST system of the whole
-- piece - s/n_systems are the GLOBAL index/count across every system,
-- not just whatever page a PDF export caller happens to be emitting),
-- measure numbers, and tempo-change labels. Deliberately does NOT draw
-- the playhead - that's live-view-only, kept in main.lua, since it needs
-- REAPER's live transport position which means nothing on a printed page.
--
-- sys_top_local_y: this system's own top y, relative to origin_y (the
-- caller already knows this from M.layout_geometry's system_pitch and
-- top_reserve - computed by the caller, not here, so both the live
-- per-frame loop and pdf_export.lua's per-page loop can each apply their
-- own "y_used so far on this page" bookkeeping around it).
-- geo: M.layout_geometry's own return table (notation_above/below,
-- tab_staff_height reused here to position the tab staff under the
-- notation staff and size the barlines).
--
-- Returns (notation_width, tab_width, bar_top, bar_bottom) - the caller
-- needs bar_top/bar_bottom for its own playhead line (live) or just to
-- track total content width (both).
function M.draw_system(ctx, draw_list, origin_x, origin_y, sys_top_local_y, cfg, geo,
    system, s, n_systems, cached_measure_info, beat_ticks_lookup, color_dim)
  local sys_origin_y = origin_y + sys_top_local_y
  local middle_c_y = sys_origin_y + geo.notation_above

  -- Time signature shown at this system only if its first measure is the
  -- very start of the piece, or the meter differs from the previous
  -- measure - same "only at start/changes" rule as tempo markings.
  local first_idx = system.item_measure_start
  local this_info, prev_info = cached_measure_info[first_idx], cached_measure_info[first_idx - 1]
  local time_sig = nil
  if this_info and (first_idx == 1 or not prev_info
      or prev_info.timesig_num ~= this_info.timesig_num
      or prev_info.timesig_denom ~= this_info.timesig_denom) then
    time_sig = { num = this_info.timesig_num, denom = this_info.timesig_denom }
  end

  local notation_width = draw_notation.draw(
    ctx, draw_list, origin_x, middle_c_y, system.events, beat_ticks_lookup, system.ticks, time_sig, system.barline_x)

  local tab_origin_y = middle_c_y + geo.notation_below + cfg.layout.staff_gap
  local tab_width = draw_tab.draw(ctx, draw_list, origin_x, tab_origin_y, system.events, system.ticks, system.barline_x)

  -- Barlines span the full height (notation staff down through tab), a
  -- single continuous line unifying the two staves.
  local bar_top, bar_bottom = sys_origin_y, tab_origin_y + geo.tab_staff_height
  for bi, local_x in ipairs(system.barline_x) do
    local x = origin_x + local_x - BARLINE_NOTE_GAP
    reaper.ImGui_DrawList_AddLine(draw_list, x, bar_top, x, bar_bottom, color_dim, 1.0)

    -- Final barline: only the LAST system's LAST barline entry is the
    -- true end of the piece - every other system's own final entry is
    -- just its closing boundary, shared with the next system's opening
    -- one.
    if s == n_systems and bi == #system.barline_x then
      local thick_x = x + FINAL_BARLINE_GAP
      reaper.ImGui_DrawList_AddLine(draw_list, thick_x, bar_top, thick_x, bar_bottom, color_dim, FINAL_BARLINE_THICK_WIDTH)
    end
  end

  -- Measure numbers (item-relative and REAPER's absolute project number)
  -- plus a tempo label wherever the tempo changes (or at the very start).
  for j = 1, #system.ticks - 1 do
    local global_idx = system.item_measure_start + j - 1
    local measure_info = cached_measure_info[global_idx]
    local label = string.format("%d (R%d)", global_idx, measure_info.reaper_measure)
    local x = origin_x + system.barline_x[j] - BARLINE_NOTE_GAP
    reaper.ImGui_DrawList_AddText(draw_list, x, bar_top - MEASURE_LABEL_ABOVE_GAP, color_dim, label)

    local prev_measure_info = cached_measure_info[global_idx - 1]
    if global_idx == 1 or not prev_measure_info or prev_measure_info.tempo ~= measure_info.tempo then
      local tempo_label = measure_info.tempo .. " BPM"
      reaper.ImGui_DrawList_AddText(draw_list, x, bar_top - TEMPO_LABEL_ABOVE_GAP, color_dim, tempo_label)
    end
  end

  return notation_width, tab_width, bar_top, bar_bottom
end

return M
