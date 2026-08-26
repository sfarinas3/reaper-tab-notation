-- Redirects this app's EXISTING drawing calls into a pdf_writer.Doc
-- instead of the screen, by temporarily monkey-patching the specific
-- global reaper.ImGui_DrawList_Add*/PushFont/PopFont functions draw_
-- notation.lua/draw_tab.lua/score_render.lua call - not a separate PDF
-- renderer reimplementing the same layout/notation logic a second time
-- (which would inevitably drift from the on-screen version). Since those
-- calls are always `reaper.ImGui_DrawList_AddLine(draw_list, ...)` -
-- global function dispatch, not a method on draw_list itself - Lua's
-- first-class functions make this a clean, if unusual, technique: swap
-- the global for the duration of one export pass, run the exact same
-- M.draw functions the live view uses, then restore the originals.
--
-- Deliberately does NOT touch ImGui_CalcTextSize/ImGui_GetFontSize - those
-- stay real, since the layout code (fret-number/label width reservation,
-- text centering) needs real measurements against the actual ReaImGui
-- font to lay out correctly; only the functions that actually PUSH pixels
-- get redirected. This does mean PDF text is drawn with a base-14 font
-- (Helvetica) whose exact glyph widths differ slightly from whatever font
-- ReaImGui is using on screen, so a label's centering can be off by a
-- pixel or two in print - accepted, not worth embedding/parsing the
-- host's actual font just for this.
--
-- Japanese technique glyphs (draw_tab.lua's shamisen katakana markers,
-- drawn via ImGui_PushFont(jp_font)/AddText/PopFont): PDF's base-14 fonts
-- have no CJK glyphs, and embedding a real subset of msgothic.ttc is out
-- of scope here - text drawn while the jp font is active is simply
-- skipped (not drawn at all) rather than showing tofu boxes or wrong
-- glyphs. A future enhancement could embed a real CJK subset; documented
-- as a known gap in the meantime.
--
-- Color: callers should set the drawing modules' colors (draw_notation.
-- set_colors/draw_tab.set_colors) to a print-safe palette (black ink, not
-- this app's live white-on-dark default) BEFORE running a capture pass -
-- see pdf_export.lua. This module just decodes whatever 0xRRGGBBAA hex it
-- receives into PDF's 0-1 RGB and draws it as-is; it doesn't second-guess
-- the caller's palette choice, so any FIXED accent colors (COLOR_
-- UNREACHABLE, COLOR_TECHNIQUE, COLOR_NOTE_NAME) still come through as
-- their own real colors in the printed page.

local M = {}

local PATCHED_NAMES = {
  "ImGui_DrawList_AddLine",
  "ImGui_DrawList_AddCircleFilled",
  "ImGui_DrawList_AddCircle",
  "ImGui_DrawList_AddText",
  "ImGui_DrawList_AddTextEx",
  "ImGui_DrawList_AddRectFilled",
  "ImGui_DrawList_AddBezierCubic",
  "ImGui_PushFont",
  "ImGui_PopFont",
}

local originals = {}
local doc = nil
local scale, margin, page_height, base_font_size = 1, 0, 0, 13
local jp_depth = 0 -- >0 while inside a PushFont(jp_font)/PopFont pair - AddText calls in that window are skipped (see header)
local watched_jp_font = nil

local function decode_color(hex)
  hex = hex or 0xFFFFFFFF
  return ((hex >> 24) & 0xFF) / 255, ((hex >> 16) & 0xFF) / 255, ((hex >> 8) & 0xFF) / 255
end

-- ImGui's own convention (confirmed by how this app already uses these
-- calls, e.g. "y - h/2" to vertically center): (x,y) is the TOP-LEFT of
-- the drawn text. PDF instead positions the BASELINE - approximated as
-- ASCENT_RATIO of the font's own size below the top edge, a standard
-- rule-of-thumb for a typical sans-serif face's cap/ascender height.
local ASCENT_RATIO = 0.8

local function tx(x) return margin + x * scale end
local function ty(y) return page_height - margin - y * scale end
local function ty_baseline(top_y, size_px) return page_height - margin - (top_y + size_px * ASCENT_RATIO) * scale end

local function shim_add_line(draw_list, x1, y1, x2, y2, color, thickness)
  local r, g, b = decode_color(color)
  doc:line(tx(x1), ty(y1), tx(x2), ty(y2), r, g, b, (thickness or 1) * scale)
end

local function shim_add_circle_filled(draw_list, cx, cy, radius, color)
  local r, g, b = decode_color(color)
  doc:circle_filled(tx(cx), ty(cy), radius * scale, r, g, b)
end

local function shim_add_circle(draw_list, cx, cy, radius, color, segments, thickness)
  local r, g, b = decode_color(color)
  doc:circle_stroke(tx(cx), ty(cy), radius * scale, r, g, b, (thickness or 1) * scale)
end

local function shim_add_text(draw_list, x, y, color, text)
  if jp_depth > 0 then return end -- see header: no CJK glyphs in a base-14 PDF font
  local r, g, b = decode_color(color)
  doc:text(tx(x), ty_baseline(y, base_font_size), base_font_size * scale, r, g, b, text)
end

local function shim_add_text_ex(draw_list, font, size, x, y, color, text)
  if jp_depth > 0 then return end
  local r, g, b = decode_color(color)
  doc:text(tx(x), ty_baseline(y, size), size * scale, r, g, b, text)
end

local function shim_add_rect_filled(draw_list, x1, y1, x2, y2, color)
  local r, g, b = decode_color(color)
  doc:rect_filled(tx(x1), ty(y1), tx(x2), ty(y2), r, g, b)
end

local function shim_add_bezier_cubic(draw_list, x1, y1, x2, y2, x3, y3, x4, y4, color, thickness)
  local r, g, b = decode_color(color)
  doc:bezier(tx(x1), ty(y1), tx(x2), ty(y2), tx(x3), ty(y3), tx(x4), ty(y4), r, g, b, (thickness or 1) * scale)
end

local function shim_push_font(ctx, font, size)
  if font == watched_jp_font then jp_depth = jp_depth + 1 end
  return originals.ImGui_PushFont(ctx, font, size)
end

local function shim_pop_font(ctx)
  if jp_depth > 0 then jp_depth = jp_depth - 1 end
  return originals.ImGui_PopFont(ctx)
end

local SHIMS = {
  ImGui_DrawList_AddLine = shim_add_line,
  ImGui_DrawList_AddCircleFilled = shim_add_circle_filled,
  ImGui_DrawList_AddCircle = shim_add_circle,
  ImGui_DrawList_AddText = shim_add_text,
  ImGui_DrawList_AddTextEx = shim_add_text_ex,
  ImGui_DrawList_AddRectFilled = shim_add_rect_filled,
  ImGui_DrawList_AddBezierCubic = shim_add_bezier_cubic,
  ImGui_PushFont = shim_push_font,
  ImGui_PopFont = shim_pop_font,
}

-- Installs the shims - call once per export, before any drawing.
-- target_doc: the pdf_writer.Doc whose CURRENT PAGE every draw call
-- appends to (see pdf_writer.lua - Doc:new_page switches the target, so
-- the caller just calls doc:new_page() between pages without touching
-- this module again). px_scale: "our pixel units" -> PDF points.
-- margin_pt/page_height_pt: this document's fixed page geometry (assumed
-- the same for every page - see pdf_export.lua). base_font_size_px: the
-- live ReaImGui font size at capture time (reaper.ImGui_GetFontSize(ctx)),
-- used for plain AddText calls, which unlike AddTextEx carry no explicit
-- size of their own. jp_font: the same font handle main.lua attaches for
-- katakana technique markers, so PushFont/PopFont can recognize it.
function M.install(target_doc, px_scale, margin_pt, page_height_pt, base_font_size_px, jp_font)
  doc = target_doc
  scale = px_scale
  margin = margin_pt
  page_height = page_height_pt
  base_font_size = base_font_size_px
  watched_jp_font = jp_font
  jp_depth = 0

  for _, name in ipairs(PATCHED_NAMES) do
    originals[name] = reaper[name]
    reaper[name] = SHIMS[name]
  end
end

-- Restores the real reaper.ImGui_* functions - call once after the export
-- pass finishes (in a pcall-protected caller, so a mid-export error still
-- restores live rendering rather than leaving the shims installed).
function M.uninstall()
  for _, name in ipairs(PATCHED_NAMES) do
    if originals[name] then reaper[name] = originals[name] end
  end
  originals = {}
  doc = nil
end

return M
