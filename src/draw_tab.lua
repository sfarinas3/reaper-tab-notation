-- ImGui draw-list rendering for the tab staff: one horizontal line per
-- string (config.tuning's length, so this scales automatically for
-- extended-range instruments), fret numbers positioned by
-- layout_engine.lua's x-map, ties drawn as a small arc instead of a
-- repeated number, a stacked "TAB" label at the start of every system
-- (the standard convention, mirroring the clef on the notation staff
-- above it). A note with no valid string/fret (outside the instrument's
-- playable range - usually a mute/scrape) is shown as "x" text at
-- config.layout.x_notehead_string's row, the standard tab convention,
-- rather than a fret number - matching the X notehead the notation staff
-- draws for the same notes. Consumes layout_engine.compute()'s render
-- model - does no layout math of its own.
--
-- When config.instrument == "Shamisen", numbers also get bunkafu-style
-- duration dashes stacked underneath (source: shamisen-zentrale.de's
-- bunkafu guide - a note with no dash is the piece's base duration, each
-- added dash halves it: 1 dash = an eighth, 2 = a sixteenth, and so on),
-- and rests get the same treatment as a big filled dot instead of a
-- number - the source's own words: "rests are rhythmically coded the same
-- way as normal notes. A rest is indicated by a big black dot on one of
-- the three lines." Which of the three lines isn't specified by the
-- source; this always uses the middle string, the same "one fixed
-- reference line regardless of context" simplification
-- draw_notation.lua's own rest placement already makes (see that file's
-- comment) rather than guessing at real bunkafu convention. Both reuse
-- notation_model.duration_dash_count, the exact same halving rule
-- draw_notation.lua's stem flags use, so no two staves ever disagree
-- about how many marks a given duration gets. Guitar (or any other
-- instrument) never draws either - this is deliberately not a generic tab
-- feature.
--
-- "Let ring" (draw_let_ring_line, all instruments): guitar/shamisen notes
-- routinely overlap in time without sharing a start tick (an open chord
-- left ringing under a moving line, fingerstyle, pedal tones). Rather
-- than true multi-voice notation (a second independent rhythmic layer -
-- how notation software handles this in general, but a much bigger
-- feature than this app's scope justifies), this uses the same
-- purpose-built convention real guitar notation already has for exactly
-- this case: a dashed line off the fret number showing the note keeps
-- ringing past its own written position, detected directly from the
-- note's own endppq outlasting the next event's start tick. See
-- draw_notation.lua's matching header comment - both staves show this the
-- same way.

local config = require('config')
local notation_model = require('notation_model')
local layout_engine = require('layout_engine')
local color_util = require('color_util')

local M = {}

-- Defaults match config.lua's pre-Colors-section look; M.set_colors
-- overwrites these once per frame from config.color_fg/color_bg (main.lua
-- calls it before drawing). COLOR_UNREACHABLE/COLOR_TECHNIQUE stay fixed -
-- they're semantic accent colors (an unplayable note, a technique marker),
-- not part of the "everything else" ink this app's Colors section covers.
local COLOR_LINE = 0x808080FF
local COLOR_TEXT = 0xFFFFFFFF
local COLOR_TIE = 0xC0C0C0FF
local COLOR_UNREACHABLE = 0xFF4040FF
local COLOR_TECHNIQUE = 0xFFC040FF

function M.set_colors(fg, bg)
  COLOR_TEXT = fg
  COLOR_LINE = color_util.dim(fg, bg)
  COLOR_TIE = COLOR_LINE
end

-- The Japanese-capable font technique markers draw with (see M.set_jp_font
-- below) - nil until main.lua sets one, in which case markers silently
-- fall back to whatever font is already active (tofu boxes rather than a
-- crash, if the host system has no font by that name).
local jp_font = nil

function M.set_jp_font(font)
  jp_font = font
end

local TAB_LABEL_X_OFFSET = 4 -- px right of the staff start where the "TAB" label sits
local TAB_LABEL_LINE_HEIGHT = 12 -- px between the stacked T/A/B letters

local DASH_WIDTH = 8 -- px, each duration dash's horizontal length
local DASH_GAP = 3 -- px between stacked dashes
local DASH_TOP_GAP = 2 -- px between the number's bottom edge and the first dash
local REST_DOT_RADIUS = 4 -- px - bigger than a notehead-sized dot would be, matching "a big black dot"
local TECHNIQUE_BELOW_GAP = 7 -- px between the last duration dash's own bottom edge (or the number's, if there are none) and its technique marker below
local LET_RING_GAP = 3 -- px between the fret number's edge and where the let-ring dashing starts
local LET_RING_DASH_LEN = 4 -- px length of each dash
local LET_RING_GAP_LEN = 3 -- px gap between dashes
local TIE_STUB_REACH = 16 -- px a system-crossing tie's incoming half reaches back from where it ends (mirrors draw_notation.lua's own constant)

-- "Let ring" marking: a dashed horizontal line from a note's own position
-- out to where its actual MIDI sustain (endppq) really ends - see this
-- file's header for the detection rule and rationale.
local function draw_let_ring_line(draw_list, x0, x1, y)
  local x = x0
  while x < x1 do
    local seg_end = math.min(x + LET_RING_DASH_LEN, x1)
    reaper.ImGui_DrawList_AddLine(draw_list, x, y, seg_end, y, COLOR_TIE, 1.5)
    x = x + LET_RING_DASH_LEN + LET_RING_GAP_LEN
  end
end

-- The standard tab convention: "TAB" with its letters stacked vertically,
-- centered on the staff regardless of string count (fixed spacing, not
-- stretched to fill an extended-range instrument's taller staff).
local function draw_tab_label(ctx, draw_list, x, origin_y, staff_height)
  local mid_y = origin_y + staff_height / 2
  local letters = { "T", "A", "B" }
  local total_h = (#letters - 1) * TAB_LABEL_LINE_HEIGHT
  local start_y = mid_y - total_h / 2
  for i, letter in ipairs(letters) do
    local _, h = reaper.ImGui_CalcTextSize(ctx, letter)
    local y = start_y + (i - 1) * TAB_LABEL_LINE_HEIGHT - h / 2
    reaper.ImGui_DrawList_AddText(draw_list, x, y, COLOR_TEXT, letter)
  end
end

-- Stacks count short horizontal dashes directly beneath (x, number_bottom_y)
-- - bunkafu's duration marking, shamisen only (see this file's header).
local function draw_duration_dashes(draw_list, x, number_bottom_y, count)
  for i = 0, count - 1 do
    local y = number_bottom_y + DASH_TOP_GAP + i * DASH_GAP
    reaper.ImGui_DrawList_AddLine(draw_list, x - DASH_WIDTH / 2, y, x + DASH_WIDTH / 2, y, COLOR_TEXT, 1.0)
  end
end

-- The real bunkafu katakana abbreviation for each technique (see
-- note_editor.lua's TECHNIQUES for the id<->name mapping this indexes by),
-- rather than an invented placeholder - sourced from jonkara.com's 文化譜
-- chart (ハ/ウ/ス for hajiki/uchi/sukui, confirmed independently by
-- shamisen-zentrale.de's own description of hajiki) plus suri's own
-- two-character スリ; oshibachi/suberi (オシ) and keshi (ケ) follow the
-- same "abbreviate to the technique's own leading kana" pattern the
-- confirmed ones share, since neither source spelled those two out
-- explicitly - worth double-checking against a print bunkafu score if this
-- ever needs to be authoritative rather than merely readable.
local TECHNIQUE_SYMBOLS = {
  [1] = "ス",   -- Sukui
  [2] = "ハ",   -- Hajiki
  [3] = "ウ",   -- Uchi
  [4] = "スリ", -- Suri
  [5] = "オシ", -- Oshibachi/Suberi
  [6] = "ケ",   -- Keshi
}

-- Drawn beneath the fret number, below its duration dashes (dashes_bottom_y
-- is already past those, or just the number's own bottom edge if it has
-- none) - the placement the user asked for, matching how a real bunkafu
-- score stacks technique marks under the position/duration info rather
-- than mixing them into one line. Needs a Japanese-capable font (M.set_jp_font)
-- to render as real katakana instead of tofu boxes; falls back to whatever
-- font is already active if none was set.
local function draw_technique_marker(ctx, draw_list, x, dashes_bottom_y, technique_id)
  local text = TECHNIQUE_SYMBOLS[technique_id]
  if not text then return end
  local size = reaper.ImGui_GetFontSize(ctx)
  if jp_font then reaper.ImGui_PushFont(ctx, jp_font, size) end
  local w, h = reaper.ImGui_CalcTextSize(ctx, text)
  reaper.ImGui_DrawList_AddText(draw_list, x - w / 2, dashes_bottom_y + TECHNIQUE_BELOW_GAP, COLOR_TECHNIQUE, text)
  if jp_font then reaper.ImGui_PopFont(ctx) end
end

-- Label a note would render as - used both for measurement (before layout
-- is computed) and drawing, so the two never disagree about width.
local function label_for(note)
  if note.tied_from_prev then
    return nil -- ties draw an arc instead of text; no width to reserve beyond the gap
  end
  if note.string then
    return tostring(note.fret)
  end
  return "x"
end

-- Returns a function(render_model_event) -> pixels, suitable for
-- layout_engine.compute's opts.measure_width. Bound to ctx because
-- ImGui_CalcTextSize needs a context to know the active font.
function M.make_measurer(ctx)
  return function(event)
    local max_w = 0
    for i = 1, #event.notes do
      local label = label_for(event.notes[i])
      if label then
        local w = reaper.ImGui_CalcTextSize(ctx, label)
        if w > max_w then max_w = w end
      end
    end
    return max_w
  end
end

-- Draws the tab staff for render_model (layout_engine.compute's output)
-- into draw_list, anchored at (origin_x, origin_y) in screen coordinates.
-- measure_ticks: optional - only used (for shamisen's rest dots) to seed
-- notation_model.detect_rests' leading-silence check, exactly like
-- draw_notation.lua's own measure_ticks param; omit it and rests just
-- won't account for silence before the first note.
-- Returns (width, height) consumed, so the caller can reserve that much
-- space in the window's layout (e.g. via ImGui_Dummy).
function M.draw(ctx, draw_list, origin_x, origin_y, render_model, measure_ticks)
  local n_strings = #config.tuning
  local line_height = config.layout.line_height
  local staff_height = (n_strings - 1) * line_height

  local content_width = 0
  for i = 1, #render_model do
    if render_model[i].x > content_width then content_width = render_model[i].x end
  end
  content_width = content_width + config.layout.right_margin

  for s = 1, n_strings do
    local y = origin_y + (s - 1) * line_height
    reaper.ImGui_DrawList_AddLine(draw_list, origin_x, y, origin_x + content_width, y, COLOR_LINE, 1.0)
  end

  draw_tab_label(ctx, draw_list, origin_x + TAB_LABEL_X_OFFSET, origin_y, staff_height)

  local last_x_by_string = {}
  local is_shamisen = config.instrument == "Shamisen"

  for i = 1, #render_model do
    local event = render_model[i]
    local x = origin_x + event.x

    for j = 1, #event.notes do
      local note = event.notes[j]
      local string_idx = note.string or config.layout.x_notehead_string
      local y = origin_y + (string_idx - 1) * line_height
      local label_end_x = x -- tied notes draw no label (an arc instead), so dashing can start right at x

      if note.string and note.tied_from_prev and last_x_by_string[note.string] then
        local x0 = last_x_by_string[note.string]
        local arc_y = y - line_height * 0.4
        reaper.ImGui_DrawList_AddBezierCubic(
          draw_list, x0, y, x0, arc_y, x, arc_y, x, y, COLOR_TIE, 1.5, 0)
      else
        local label = label_for(note)
        local w, h = reaper.ImGui_CalcTextSize(ctx, label)
        local color = note.string and COLOR_TEXT or COLOR_UNREACHABLE
        reaper.ImGui_DrawList_AddText(draw_list, x - w / 2, y - h / 2, color, label)
        label_end_x = x + w / 2

        -- Incoming half of a tie crossing a system break (mirrors
        -- draw_notation.lua's own tied_from_prev/i==1 branch - see its
        -- comment for the full reasoning: M.draw is called once per
        -- system with fresh local state, so a tie continuing from the
        -- PREVIOUS system's last note has no local predecessor here,
        -- which is exactly why this fell into the label branch instead of
        -- the tie-arc one above). Ends just left of the repeated number
        -- rather than at its own center, so the two don't overlap -
        -- showing both together (number + incoming stub) is itself a
        -- legitimate, common real tab convention for a line-break
        -- continuation, clearer here than an arc alone since tab relies
        -- on explicit numbers rather than notehead position.
        if note.string and note.tied_from_prev and i == 1 then
          local stub_end_x = x - w / 2 - LET_RING_GAP
          local stub_x = stub_end_x - TIE_STUB_REACH
          local arc_y = y - line_height * 0.4
          reaper.ImGui_DrawList_AddBezierCubic(
            draw_list, stub_x, arc_y, stub_x, arc_y, stub_end_x, arc_y, stub_end_x, y, COLOR_TIE, 1.5, 0)
        end

        if is_shamisen then
          local number_bottom_y = y + h / 2
          local dash_count = notation_model.duration_dash_count(event.duration_ticks)
          local dashes_bottom_y = number_bottom_y
          if dash_count > 0 then
            draw_duration_dashes(draw_list, x, number_bottom_y, dash_count)
            -- draw_duration_dashes' own formula for its LAST dash's y is
            -- number_bottom_y + DASH_TOP_GAP + (dash_count - 1) * DASH_GAP -
            -- that's the line's own drawn position (its vertical center,
            -- give or take its 1px stroke), not a point below it. Half
            -- DASH_GAP pushes past that into real clearance instead of
            -- landing right on the last dash itself, which is what let the
            -- technique glyph below visibly touch it at 2+ dashes.
            dashes_bottom_y = number_bottom_y + DASH_TOP_GAP + (dash_count - 1) * DASH_GAP + DASH_GAP / 2
          end
          if note.technique then
            draw_technique_marker(ctx, draw_list, x, dashes_bottom_y, note.technique)
          end
        end
      end

      -- Let ring: this note's actual MIDI sustain outlasts its own
      -- written position (still audible when the next event starts,
      -- whatever string/pitch it turns out to be) - see this file's
      -- header. Excludes tied_to_next (layout_engine.compute's barline-
      -- crossing split) so a barline-split note's tie curve doesn't also
      -- get a redundant let-ring line - see draw_notation.lua's matching
      -- guard for the full reasoning. Same cross-system limitation as
      -- draw_notation.lua's version: only checked against the immediately
      -- following event.
      if note.string and note.endppq and not note.tied_to_next
          and render_model[i + 1] and note.endppq > render_model[i + 1].tick then
        local ring_end_x = origin_x + layout_engine.x_for_tick(render_model, note.endppq)
        draw_let_ring_line(draw_list, label_end_x + LET_RING_GAP, ring_end_x, y)
      end

      -- Hanging tie: mirrors draw_notation.lua's own version (see that
      -- file's comment for the full reasoning - M.draw is called once per
      -- system with fresh local state, so a tie continuing into the NEXT
      -- system has no visibility into it here). The INCOMING side at the
      -- start of a system already works for free: a new system's first
      -- note has no last_x_by_string entry yet, so it falls through to
      -- the normal label branch above and shows the fret number again -
      -- a legitimate, common real tab convention for a line-break
      -- continuation, arguably clearer here than on the notation staff
      -- since tab relies on explicit numbers rather than notehead
      -- position. Only the OUTGOING side, at the end of a system, needs
      -- this.
      if note.string and note.tied_to_next and i == #render_model then
        local edge_x = origin_x + content_width
        local arc_y = y - line_height * 0.4
        reaper.ImGui_DrawList_AddBezierCubic(draw_list, x, y, x, arc_y, edge_x, arc_y, edge_x, arc_y, COLOR_TIE, 1.5, 0)
      end

      if note.string then
        last_x_by_string[note.string] = x
      end
    end
  end

  if is_shamisen then
    local rest_string = math.ceil(n_strings / 2) -- the middle string - see this file's header
    local rest_y = origin_y + (rest_string - 1) * line_height
    local leading_tick = measure_ticks and measure_ticks[1]
    local rests = notation_model.detect_rests(render_model, leading_tick, measure_ticks)
    for _, rest in ipairs(rests) do
      local x = origin_x + layout_engine.x_for_tick(render_model, rest.tick)
      reaper.ImGui_DrawList_AddCircleFilled(draw_list, x, rest_y, REST_DOT_RADIUS, COLOR_TEXT, 0)
      local dash_count = notation_model.duration_dash_count(rest.duration_ticks)
      if dash_count > 0 then
        draw_duration_dashes(draw_list, x, rest_y + REST_DOT_RADIUS, dash_count)
      end
    end
  end

  return content_width, staff_height
end

return M
