-- Orchestrates a print-to-PDF export: re-wraps the already-cached render
-- model at PAGE width (instead of whatever the live window happens to
-- be), paginates the resulting systems across as many pages as needed,
-- and runs score_render.lua's exact same header/system drawing code once
-- per page with pdf_capture.lua's shims installed - see pdf_capture.lua's
-- own header for why reusing the real drawing code (rather than a
-- separate PDF-specific renderer) is the whole point of this design.
--
-- Page size/margins/scale are fixed constants for now (US Letter,
-- portrait, 0.5in margins) - easy to make user-configurable later if
-- that's ever wanted, not exposed yet to keep the first version's
-- surface area small.

local pdf_writer = require('pdf_writer')
local pdf_capture = require('pdf_capture')
local score_render = require('score_render')
local layout_engine = require('layout_engine')
local notation_model = require('notation_model')
local draw_notation = require('draw_notation')
local draw_tab = require('draw_tab')
local color_util = require('color_util')

local M = {}

local PAGE_WIDTH_PT, PAGE_HEIGHT_PT = 612, 792 -- US Letter, portrait, points (72pt/in)
local MARGIN_PT = 36 -- 0.5in on all sides

-- "app pixel units" (the same units config.layout's constants use) -> PDF
-- points. pdf_capture.lua applies this SAME factor uniformly to every x/y
-- position, line thickness, notehead radius, and font size - so lowering
-- it shrinks the whole page proportionally (more content fits per line/
-- page, at a uniformly smaller size) rather than distorting spacing
-- relative to note/text size. That uniform behavior is deliberate: an
-- earlier version of this file additionally compressed just the
-- horizontal note-spacing constants (to pack more measures per line
-- without shrinking noteheads/text) and it looked exactly like what it
-- was - notes smooshed together at their original size. This SCALE is
-- the only knob for "how much fits per page" now. 0.3 targets ~4
-- measures/line at typical note density - the cost is a typical 13-15px
-- UI font printing at roughly 4-4.5pt, on the small side even for a
-- printed page; if that reads as too small in practice, raise this
-- toward 0.4-0.5 (fewer measures/line, more legible text) rather than
-- reaching for the old horizontal-only trick.
local SCALE = 0.3

-- Always black-on-white regardless of the live view's own color scheme
-- (which defaults to white ink on a dark panel - printing that literally
-- would put white notes on white paper) - see pdf_capture.lua's header.
local PRINT_COLOR_FG = 0x000000FF
local PRINT_COLOR_BG = 0xFFFFFFFF

-- Splits the FULL (unwrapped-into-pages) systems array into pages, each a
-- list of {system, global_index} entries - global_index is the system's
-- own position in the original array, needed by score_render.draw_system
-- to correctly identify the piece's true LAST system (for the final
-- barline) regardless of which page it lands on. A system is never split
-- across pages; page 1 reserves geo.top_reserve (header + top margin),
-- every later page just geo.top_margin.
local function paginate(systems, geo, printable_h)
  local pages = {}
  local cur = {}
  local y_used = geo.top_reserve
  local is_first_page = true

  local function flush()
    if #cur > 0 then
      table.insert(pages, { entries = cur, is_first_page = is_first_page })
    end
    cur = {}
    is_first_page = false
    y_used = geo.top_margin
  end

  for s = 1, #systems do
    if y_used + geo.system_pitch > printable_h and #cur > 0 then
      flush()
    end
    table.insert(cur, { system = systems[s], global_index = s })
    y_used = y_used + geo.system_pitch
  end
  flush()

  return pages
end

-- Exports the CURRENTLY CACHED render model to filepath (main.lua's own
-- cached_render_model/cached_measure_ticks/cached_measure_info - passed
-- in rather than recomputed here, since main.lua already keeps them
-- current against note-hash/settings changes). Returns true, or
-- false+message on failure (nothing to export, or a file-write error) -
-- callers should show that message rather than letting an export failure
-- pass silently.
--
-- Must be called from within a live ImGui frame (ctx mid-Begin/End) -
-- text measurement (ImGui_CalcTextSize/GetFontSize, left un-shimmed, see
-- pdf_capture.lua) needs that to return correct values.
function M.export(ctx, cfg, cached_render_model, cached_measure_ticks, cached_measure_info, filepath)
  if not cached_render_model or #cached_render_model == 0 then
    return false, "Nothing to export - the current take has no notes."
  end

  local printable_w = (PAGE_WIDTH_PT - 2 * MARGIN_PT) / SCALE
  local printable_h = (PAGE_HEIGHT_PT - 2 * MARGIN_PT) / SCALE
  local max_width = math.max(printable_w - cfg.layout.right_margin, 50)

  local systems = layout_engine.wrap_into_systems(cached_render_model, cached_measure_ticks, max_width)
  if #systems == 0 then
    return false, "Nothing to export - the current take has no notes."
  end

  local geo = score_render.layout_geometry(ctx, cfg)
  local beat_ticks_lookup = notation_model.beat_ticks_lookup(cached_measure_ticks, cached_measure_info)
  local pages = paginate(systems, geo, printable_h)

  local doc = pdf_writer.new()
  local base_font_size = reaper.ImGui_GetFontSize(ctx)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx) -- value unused once shimmed - every Add* call is redirected regardless of what's passed

  -- Print-safe palette for the duration of the capture pass only - always
  -- restored below (even on failure, via pcall) so the live view's own
  -- colors are never left clobbered by a print export.
  local live_fg, live_bg = cfg.color_fg, cfg.color_bg
  local print_color_dim = color_util.dim(PRINT_COLOR_FG, PRINT_COLOR_BG)
  draw_notation.set_colors(PRINT_COLOR_FG, PRINT_COLOR_BG)
  draw_tab.set_colors(PRINT_COLOR_FG, PRINT_COLOR_BG)

  pdf_capture.install(doc, SCALE, MARGIN_PT, PAGE_HEIGHT_PT, base_font_size, draw_tab.get_jp_font())

  local ok, err = pcall(function()
    for _, page in ipairs(pages) do
      doc:new_page(PAGE_WIDTH_PT, PAGE_HEIGHT_PT)
      local y_used

      if page.is_first_page then
        score_render.draw_header(ctx, draw_list, 0, 0, cfg, printable_w, PRINT_COLOR_FG, print_color_dim)
        y_used = geo.top_reserve
      else
        y_used = geo.top_margin
      end

      for _, entry in ipairs(page.entries) do
        score_render.draw_system(
          ctx, draw_list, 0, 0, y_used, cfg, geo,
          entry.system, entry.global_index, #systems, cached_measure_info, beat_ticks_lookup, print_color_dim)
        y_used = y_used + geo.system_pitch
      end
    end
  end)

  pdf_capture.uninstall()
  draw_notation.set_colors(live_fg, live_bg)
  draw_tab.set_colors(live_fg, live_bg)

  if not ok then
    return false, "PDF export failed: " .. tostring(err)
  end

  local save_ok, save_err = doc:save(filepath)
  if not save_ok then
    return false, "Could not write " .. tostring(filepath) .. ": " .. tostring(save_err)
  end

  return true
end

return M
