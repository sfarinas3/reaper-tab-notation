-- Orchestrates a print-to-PDF export: re-runs layout at PAGE width under
-- print-only spacing constants (instead of whatever the live window
-- happens to be, at on-screen spacing), paginates the resulting systems
-- across as many pages as needed, and runs score_render.lua's exact same
-- header/system drawing code once per page with pdf_capture.lua's shims
-- installed - see pdf_capture.lua's own header for why reusing the real
-- drawing code (rather than a separate PDF-specific renderer) is the
-- whole point of this design.
--
-- Page size/margins/scale are fixed constants for now (US Letter,
-- portrait, 0.5in margins, 0.75x this app's own pixel units) - easy to
-- make user-configurable later if that's ever wanted, not exposed yet to
-- keep the first version's surface area small.

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
-- points. 0.75 = 72/96, the standard px->pt conversion at a 96 DPI
-- reference (matching how config.layout's pixel constants read on a
-- normal screen) - NOT 1x or higher: this app's staff/spacing constants
-- are sized for a comfortably large on-screen panel, so printing them at
-- 1:1 (let alone enlarged) blows a page up to ~1 giant system and forces
-- absurd pagination. 0.75 keeps proportions faithful to the live view
-- while fitting a normal few-systems-per-page printed layout.
local SCALE = 0.75

-- Print-only layout compression, applied to a TEMPORARY copy of
-- config.layout for the duration of doc generation (installed below,
-- always restored afterward - even on failure - alongside the print
-- color palette). Never touches the live docked view's own config.layout.
--
-- HORIZONTAL_COMPRESSION shrinks inter-note spacing (min_gap and every
-- duration-class width) so more measures fit per printed line - notehead/
-- stem/font sizes are untouched (those come from SCALE alone), so notes
-- stay legible while packing closer together, the same tradeoff real
-- engraving software makes between note size and line density. 0.45 was
-- picked to go from ~1-2 measures/line (at plain SCALE with no horizontal
-- compression) to roughly 4 - retune this single constant if a piece's
-- own note density still lands short of that.
--
-- TAB_LINE_HEIGHT_COMPRESSION shrinks only the tab staff's string spacing
-- a little, tightening the tab block vertically without shrinking the
-- fret-number text itself - push this much further and fret numbers on
-- adjacent strings start touching (that's the real floor, not an
-- arbitrary one). Left at 1.0 for the notation staff's own line spacing,
-- since only the tab side was asked to condense.
local HORIZONTAL_COMPRESSION = 0.45
local TAB_LINE_HEIGHT_COMPRESSION = 0.82

-- Always black-on-white regardless of the live view's own color scheme
-- (which defaults to white ink on a dark panel - printing that literally
-- would put white notes on white paper) - see pdf_capture.lua's header.
local PRINT_COLOR_FG = 0x000000FF
local PRINT_COLOR_BG = 0xFFFFFFFF

-- Shallow-copies live_layout with HORIZONTAL_COMPRESSION/
-- TAB_LINE_HEIGHT_COMPRESSION applied - see those constants' own comments
-- above for what each does and why. Every other field (margins, notehead
-- radius, stem length, notation staff line spacing, etc.) passes through
-- unchanged.
local function build_print_layout(live_layout)
  local compressed_duration_classes = {}
  for i, c in ipairs(live_layout.duration_classes) do
    compressed_duration_classes[i] = { ticks = c.ticks, width = c.width * HORIZONTAL_COMPRESSION }
  end

  local print_layout = {}
  for k, v in pairs(live_layout) do print_layout[k] = v end
  print_layout.min_gap = live_layout.min_gap * HORIZONTAL_COMPRESSION
  print_layout.duration_classes = compressed_duration_classes
  print_layout.line_height = live_layout.line_height * TAB_LINE_HEIGHT_COMPRESSION
  return print_layout
end

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

-- Exports the CURRENTLY CACHED assigned_events (main.lua's own
-- cached_assigned_events/cached_measure_ticks/cached_measure_info -
-- passed in rather than recomputed from MIDI here, since main.lua already
-- keeps them current against note-hash/settings changes). Re-runs
-- layout_engine.compute() under print-only spacing (build_print_layout)
-- rather than reusing main.lua's cached_render_model, which was laid out
-- at live on-screen spacing - wrap_into_systems() only re-bins already-
-- computed x positions, so getting print's tighter measures-per-line
-- requires a second, print-specific layout pass, not just a narrower
-- wrap width. Returns true, or false+message on failure (nothing to
-- export, or a file-write error) - callers should show that message
-- rather than letting an export failure pass silently.
--
-- Must be called from within a live ImGui frame (ctx mid-Begin/End) -
-- text measurement (ImGui_CalcTextSize/GetFontSize, left un-shimmed, see
-- pdf_capture.lua) needs that to return correct values.
function M.export(ctx, cfg, cached_assigned_events, cached_measure_ticks, cached_measure_info, filepath)
  if not cached_assigned_events or #cached_assigned_events == 0 then
    return false, "Nothing to export - the current take has no notes."
  end

  local printable_w = (PAGE_WIDTH_PT - 2 * MARGIN_PT) / SCALE
  local printable_h = (PAGE_HEIGHT_PT - 2 * MARGIN_PT) / SCALE
  local max_width = math.max(printable_w - cfg.layout.right_margin, 50)

  local doc = pdf_writer.new()
  local base_font_size = reaper.ImGui_GetFontSize(ctx)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx) -- value unused once shimmed - every Add* call is redirected regardless of what's passed

  -- Print-safe palette and spacing for the duration of this export only -
  -- both always restored below (even on failure, via pcall) so the live
  -- view is never left clobbered by a print export.
  local live_fg, live_bg = cfg.color_fg, cfg.color_bg
  local live_layout = cfg.layout
  local print_color_dim = color_util.dim(PRINT_COLOR_FG, PRINT_COLOR_BG)
  draw_notation.set_colors(PRINT_COLOR_FG, PRINT_COLOR_BG)
  draw_tab.set_colors(PRINT_COLOR_FG, PRINT_COLOR_BG)
  cfg.layout = build_print_layout(live_layout)

  -- Only set true once pdf_capture.install() actually runs (inside the
  -- pcall below, after the systems/pages computation - an error there,
  -- e.g. "nothing to export", must NOT trigger an uninstall of shims that
  -- were never installed, which would stomp reaper.ImGui_* globals with
  -- nils instead of restoring them).
  local installed = false
  local beat_ticks_lookup = notation_model.beat_ticks_lookup(cached_measure_ticks, cached_measure_info)

  local ok, err = pcall(function()
    local render_model = layout_engine.compute(cached_assigned_events, {
      measure_width = draw_tab.make_measurer(ctx),
      beat_ticks_lookup = beat_ticks_lookup,
      measure_ticks = cached_measure_ticks,
    })

    local systems = layout_engine.wrap_into_systems(render_model, cached_measure_ticks, max_width)
    if #systems == 0 then
      error("Nothing to export - the current take has no notes.")
    end

    local geo = score_render.layout_geometry(ctx, cfg)
    local pages = paginate(systems, geo, printable_h)

    pdf_capture.install(doc, SCALE, MARGIN_PT, PAGE_HEIGHT_PT, base_font_size, draw_tab.get_jp_font())
    installed = true

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

  if installed then pdf_capture.uninstall() end
  draw_notation.set_colors(live_fg, live_bg)
  draw_tab.set_colors(live_fg, live_bg)
  cfg.layout = live_layout

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
