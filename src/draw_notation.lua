-- ImGui draw-list rendering for the standard notation staff: single treble
-- clef for <=6 strings, grand staff (treble+bass) for extended-range
-- instruments. Phase 4b added beat-grouped beams (flat, not contour-sloped
-- - a hobbyist-scope simplification) and flags for un-beamed short notes.
-- Phase 4c added ledger lines and accidentals, with measure-scoped
-- suppression (an accidental only needs to be shown once per measure per
-- diatonic position; a different one - including a natural - is drawn if
-- a later note in the same measure needs to override it). Symbols are
-- plain "#"/"b"/"n" text (and "x"/"bb" for the rare double-sharp/flat -
-- see notation_model.lua's header), not real engraved glyphs - font glyph
-- coverage for proper Unicode accidentals (♯/♭/♮) isn't guaranteed, so
-- this is the pragmatic, guaranteed-to-render choice.
--
-- Spelling and the accidental-suppression baseline are key-signature-aware
-- (config.key_count, set via ui_chrome.lua's "Key Signature" dropdown):
-- notation_model.diatonic_position spells each pitch according to the
-- current key, and a note only gets an accidental symbol here when its
-- spelling differs from what the key signature already implies for that
-- letter - not always "natural" as a fixed baseline. The key signature
-- itself (the sharp/flat glyphs after the clef) is drawn by
-- draw_key_signature, on every system same as the clef.
--
-- Phase 4d adds ties (a small arc between same-pitch same-string notes,
-- reusing layout_engine's tied_from_prev flag - unlike the tab staff, the
-- tied note still gets its own full notehead/stem, matching real
-- notation) and rests (detected as gaps in the timeline by
-- notation_model.detect_rests, greedily classified into a single standard
-- duration rather than decomposed exactly - see that function's comment).
-- Rest glyphs are simplified stand-ins (rectangles/zigzag/hook), not true
-- engraved shapes, same pragmatic choice as the accidental symbols. No
-- tuplet brackets - punted per the plan's own "lowest priority" framing,
-- since detecting tuplets from raw MIDI timing is a rhythm-transcription
-- problem disproportionate to the rest of this project's scope.
--
-- A note with no valid string/fret (fret_heuristic couldn't place it
-- within the instrument's range) gets an X notehead instead of a filled
-- circle - most often this represents a string mute/scrape rather than a
-- real pitch, so it also skips accidental logic (which implies a real,
-- spellable pitch) while still getting ledger lines/stems/beams normally,
-- since its rhythmic placement is still meaningful even if its "pitch"
-- isn't a real played note.
--
-- Phase 4e adds a real (curved, approximated via two bezier arcs meeting
-- at a point) brace glyph for a grand staff, replacing the plain
-- connecting line, plus threads notation_model's staff-split hysteresis
-- through (prev_staff, updated note-by-note) so a phrase hovering near
-- the treble/bass boundary doesn't flicker between staves. Cross-staff
-- beam joining (one sloped beam physically crossing the gap, with stems
-- reaching across) is NOT implemented - that's a much harder geometry
-- problem than anything else in this phase (variable-length stems, a beam
-- that isn't just a flat horizontal bar). Instead, an entire beamed group
-- is assigned ONE staff together (notation_model.staff_for_group, from
-- the group's own collective average pitch, decided the moment Step A
-- below reaches the group's first member) rather than letting each
-- member's individual hysteresis potentially land on different staves -
-- which, for guitar's fast extended-range runs, came up often enough to
-- matter: a straddling group used to render as a majority beam plus one
-- or more notes stranded alone on the other staff. The trade-off is the
-- reverse of hysteresis's own: a note can render on the staff its GROUP
-- belongs to rather than the staff its own pitch would suggest in
-- isolation (with extra ledger lines as needed, same as any other note
-- whose staff doesn't match its raw pitch).
--
-- Consumes layout_engine.compute()'s render model for note positions;
-- also calls layout_engine.x_for_tick directly for rests, since rest
-- positions aren't part of that render model.
--
-- Two correctness fixes made together (both fell out of the same
-- investigation): stem attachment side was backwards from standard
-- notation (verified against reference material) - stem-down should
-- attach on the notehead's LEFT edge, stem-up on the RIGHT, not the other
-- way around as this file previously had it; and chord "seconds" (two
-- notes a diatonic step apart) now get their noteheads pushed to either
-- side of the stem (compute_notehead_offsets) instead of drawing directly
-- on top of each other, which is what the wrong stem side had been
-- masking - a chord second wasn't visibly broken before because nothing
-- offset the overlapping noteheads at all, on either side.
--
-- "Let ring" (draw_let_ring_line): guitar notes routinely overlap in time
-- without sharing a start tick (an open chord left ringing under a moving
-- line, fingerstyle, pedal tones) - real multi-voice notation (a second,
-- independent rhythmic layer) is how notation software handles this in
-- general, but it's a much bigger feature than this app's scope
-- justifies. Real guitar notation software also uses a lighter-weight,
-- purpose-built convention for exactly this case: mark the sustained note
-- with a dashed line (sometimes "L.R.") showing it keeps ringing past its
-- own written duration, with every note still laid out at its own single,
-- sequential position - no second voice/layer needed. That's what this
-- draws: detected directly from each note's own endppq outlasting the
-- next event's start tick, regardless of what instrument/string that next
-- event is on.

local config = require('config')
local notation_model = require('notation_model')
local layout_engine = require('layout_engine')
local color_util = require('color_util')

local M = {}

-- Defaults match config.lua's pre-Colors-section look; M.set_colors
-- overwrites these once per frame from config.color_fg/color_bg (main.lua
-- calls it before drawing) so every drawing function below can keep
-- referencing these as plain module-level constants.
local COLOR_LINE = 0x808080FF
local COLOR_NOTE = 0xFFFFFFFF
local COLOR_LET_RING = 0xC0C0C0FF

function M.set_colors(fg, bg)
  COLOR_NOTE = fg
  COLOR_LINE = color_util.dim(fg, bg)
  COLOR_LET_RING = COLOR_LINE
end

-- Diatonic offsets from middle C for each staff's 5 lines, bottom to top.
local TREBLE_OFFSETS = { 2, 4, 6, 8, 10 }   -- E4 G4 B4 D5 F5
local BASS_OFFSETS = { -10, -8, -6, -4, -2 } -- G2 B2 D3 F3 A3

local WHOLE_NOTE_TICKS = config.layout.ppq_per_quarter * 4
local FLAG_SPACING = 6 -- px between stacked flags along a stem, for 16th/32nd/64th notes
local BEAM_BAR_GAP = 4 -- px between stacked parallel beam bars, for 16th/32nd/64th beamed groups
local LET_RING_GAP = 3 -- px between the notehead's edge and where the let-ring dashing starts
local LET_RING_DASH_LEN = 4 -- px length of each dash
local LET_RING_GAP_LEN = 3 -- px gap between dashes
local LEDGER_OVERHANG = 3 -- px a ledger line extends past the notehead on each side
local ACCIDENTAL_GAP = 3 -- px between an accidental symbol and the notehead it applies to
local TIE_ARC_HEIGHT = 6 -- px the tie curve rises above the notes it connects
local REST_RECT_W, REST_RECT_H = 8, 4 -- whole/half rest rectangle size
local BRACE_X_OFFSET = 6 -- px left of the staff lines' start where the brace sits
local BRACE_BULGE = 8 -- px further left the brace bulges at its midpoint
local CLEF_X_OFFSET = 4 -- px right of the staff start where the clef sits
local CLEF_FONT_SCALE = 2.4 -- clef text size, relative to the window's base font size
local CLEF_TREBLE_OFFSET = 4 -- G4 line
local CLEF_BASS_OFFSET = -4 -- F3 line
local CLEF_DOT_RADIUS = 1.5
local CLEF_DOT_GAP = 5 -- px above/below the F line for the bass clef's two dots
local TIMESIG_BASE_X_OFFSET = 42 -- where the time signature sits when there's no key signature (after the clef)
local TIMESIG_TAIL_RESERVE = 48 -- px reserved after wherever the time signature starts, for its own digits + gap before the first note - matches the original fixed layout (90 left_margin - 42 timesig offset)
local TIMESIG_FONT_SCALE = 1.6

local KEYSIG_X_OFFSET = 28 -- px right of the staff start where key-signature glyphs start (after the clef, before the time signature)
local KEYSIG_GLYPH_ADVANCE = 9 -- px each key-signature accidental glyph advances (symbol width + spacing) - a flat estimate, not measured per-glyph
local KEYSIG_FONT_SCALE = 1.3

-- Shared with the per-note accidental symbols below (draw_notation's own
-- guaranteed-to-render placeholder-glyph convention - see this file's
-- header). +-2 (double sharp/flat) only arises in an extreme key (6-7
-- sharps/flats) - see notation_model.lua's header.
local ACCIDENTAL_SYMBOLS = { [-2] = "bb", [-1] = "b", [0] = "n", [1] = "#", [2] = "x" }

-- Standard engraver's key-signature accidental staff positions (diatonic
-- offset from middle C) - fixed per letter+clef+sharp-or-flat, independent
-- of what octave any given piece's notes actually use. Sharps and flats
-- use different positions for the same letter (two separately-memorized
-- "staircase" shapes, not one shared per-letter rule), hence four tables.
local KEYSIG_SHARP_TREBLE = { F = 10, C = 7, G = 11, D = 8, A = 5, E = 9, B = 6 }
local KEYSIG_FLAT_TREBLE = { B = 6, E = 9, A = 5, D = 8, G = 4, C = 7, F = 3 }
local KEYSIG_SHARP_BASS = { F = -4, C = -7, G = -3, D = -6, A = -9, E = -5, B = -8 }
local KEYSIG_FLAT_BASS = { B = -8, E = -5, A = -9, D = -6, G = -10, C = -7, F = -11 }

-- Where the time signature starts, and how wide a left_margin the whole
-- staff header (clef + key signature + time signature + gap) needs -
-- both grow with the key signature's accidental count. ui_chrome.lua calls
-- left_margin_for_key whenever the key changes, since config.layout.
-- left_margin also feeds layout_engine.compute's starting x for the first
-- note - a stale margin would either crowd the header or leave a gap.
function M.timesig_x_offset(key_count)
  return TIMESIG_BASE_X_OFFSET + math.abs(key_count) * KEYSIG_GLYPH_ADVANCE
end

function M.left_margin_for_key(key_count)
  return M.timesig_x_offset(key_count) + TIMESIG_TAIL_RESERVE
end

local function middle_line_offset(staff)
  return staff == "treble" and 6 or -6
end

-- Simplified clef stand-ins: a large "G"/"F" letter, matching both the
-- clefs' actual historical origin and the pragmatic choice used elsewhere
-- in this file (accidentals, rests) - guaranteed-to-render text rather
-- than a real engraved glyph, which risks the same font-coverage problem
-- Unicode clef symbols have. Scaled up from the window's base font size
-- via AddTextEx (no custom font load needed), since a clef is one of the
-- more visually prominent elements on a real staff. Bass also gets two
-- small dots straddling the F line, its single most recognizable feature.
local function draw_clef(ctx, draw_list, x, y_at, staff)
  local base_size = reaper.ImGui_GetFontSize(ctx)
  local clef_size = base_size * CLEF_FONT_SCALE
  local scale = clef_size / base_size

  if staff == "treble" then
    local y = y_at(CLEF_TREBLE_OFFSET)
    local _, h = reaper.ImGui_CalcTextSize(ctx, "G")
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, clef_size, x, y - (h * scale) / 2, COLOR_NOTE, "G")
  else
    local y = y_at(CLEF_BASS_OFFSET)
    local w, h = reaper.ImGui_CalcTextSize(ctx, "F")
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, clef_size, x, y - (h * scale) / 2, COLOR_NOTE, "F")
    local dot_x = x + w * scale + 3
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, dot_x, y - CLEF_DOT_GAP, CLEF_DOT_RADIUS, COLOR_NOTE, 0)
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, dot_x, y + CLEF_DOT_GAP, CLEF_DOT_RADIUS, COLOR_NOTE, 0)
  end
end

-- Draws the key signature's accidentals in order (notation_model.
-- key_signature_letters, already in standard drawing order) at fixed
-- engraver's staff positions, left to right starting at x. A no-op (0
-- width consumed) for key_count == 0.
local function draw_key_signature(ctx, draw_list, x, y_at, staff, key_count)
  local letters = notation_model.key_signature_letters(key_count)
  if #letters == 0 then return end

  local sharp_table = staff == "treble" and KEYSIG_SHARP_TREBLE or KEYSIG_SHARP_BASS
  local flat_table = staff == "treble" and KEYSIG_FLAT_TREBLE or KEYSIG_FLAT_BASS

  local base_size = reaper.ImGui_GetFontSize(ctx)
  local sym_size = base_size * KEYSIG_FONT_SCALE
  local scale = sym_size / base_size

  local cx = x
  for _, entry in ipairs(letters) do
    local offset_table = entry.accidental > 0 and sharp_table or flat_table
    local offset = offset_table[entry.letter]
    local symbol = ACCIDENTAL_SYMBOLS[entry.accidental]
    local _, h = reaper.ImGui_CalcTextSize(ctx, symbol)
    reaper.ImGui_DrawList_AddTextEx(draw_list, nil, sym_size, cx, y_at(offset) - (h * scale) / 2, COLOR_NOTE, symbol)
    cx = cx + KEYSIG_GLYPH_ADVANCE
  end
end

-- Numerator centered in the staff's upper half, denominator in the lower
-- half - e.g. for treble (lines at offsets 2/4/6/8/10), numerator centers
-- on the D5 line (8), denominator on the G4 line (4).
local function timesig_offsets(staff)
  if staff == "treble" then
    return 8, 4
  end
  return -4, -8
end

local function draw_time_sig(ctx, draw_list, x, y_at, staff, num, denom)
  local base_size = reaper.ImGui_GetFontSize(ctx)
  local sig_size = base_size * TIMESIG_FONT_SCALE
  local scale = sig_size / base_size

  local num_offset, denom_offset = timesig_offsets(staff)
  local num_str, denom_str = tostring(num), tostring(denom)
  local _, nh = reaper.ImGui_CalcTextSize(ctx, num_str)
  local _, dh = reaper.ImGui_CalcTextSize(ctx, denom_str)

  reaper.ImGui_DrawList_AddTextEx(
    draw_list, nil, sig_size, x, y_at(num_offset) - (nh * scale) / 2, COLOR_NOTE, num_str)
  reaper.ImGui_DrawList_AddTextEx(
    draw_list, nil, sig_size, x, y_at(denom_offset) - (dh * scale) / 2, COLOR_NOTE, denom_str)
end

-- A single flag as a bold diagonal stroke off the stem tip, on the same
-- side as the stem's own attachment and angled back TOWARD the notehead:
-- a stem-down note's stem attaches on the LEFT of the notehead (see
-- stem_x_offset's own comment), so its flag also sits on the left,
-- starting at the bottom tip and angling up-left, back toward the
-- notehead above; a stem-up note's stem attaches on the RIGHT, so its
-- flag sits on the right, starting at the top tip and angling down-right,
-- back toward the notehead below. Replaces an earlier small hooked-curve
-- version that was hard to count reliably at a glance (1 vs 2 vs 3
-- closely-spaced curves); a thicker straight stroke reads as a distinct,
-- countable mark instead. Stacked flags step back up the stem toward the
-- notehead.
local FLAG_DIAGONAL_DX = 9 -- px horizontal reach of each flag stroke
local FLAG_DIAGONAL_DY = 5 -- px vertical reach, back toward the notehead
local function draw_flags(draw_list, stem_x, tip_y, count, direction)
  local step = direction == "down" and -FLAG_SPACING or FLAG_SPACING
  local dx = direction == "down" and -FLAG_DIAGONAL_DX or FLAG_DIAGONAL_DX
  local dy = direction == "down" and -FLAG_DIAGONAL_DY or FLAG_DIAGONAL_DY
  for k = 0, count - 1 do
    local y0 = tip_y + k * step
    reaper.ImGui_DrawList_AddLine(draw_list, stem_x, y0, stem_x + dx, y0 + dy, COLOR_NOTE, 2.5)
  end
end

local REST_HOOK_DX = 6 -- px horizontal reach of each rest hook (back over the stroke, toward -x)
local REST_HOOK_DY = 4 -- px vertical rise of each rest hook
local REST_HOOK_SPACING = 5 -- px between stacked hooks (sixteenth rest's second hook)

-- Hook(s) near the top of an eighth/sixteenth rest's main stroke - same
-- "1 hook = eighth, 2 hooks = sixteenth" convention as their note
-- counterparts. The main stroke is a forward slash (bottom-left to
-- top-right - see draw_rest below); the hook(s) sit at that top-right
-- end and curve back up-LEFT over the stroke (always up - unlike a
-- note's flag, a rest has no stem direction to point opposite of),
-- stacked downward (toward the stroke's own middle) for a second hook.
-- Deliberately NOT drawn via draw_flags: that function's direction
-- ("up"/"down") means "which way does this NOTE's stem point, so the
-- flag sits on that same side and curves back toward the notehead" - a
-- rest has neither a stem nor a notehead, so that semantic doesn't carry
-- over; reusing it here (as an earlier version of this file did) left
-- the hook's exact placement dependent on draw_flags' own note-specific
-- convention rather than a rest's actual, fixed shape.
local function draw_rest_hooks(draw_list, x, top_y, count)
  for k = 0, count - 1 do
    local y0 = top_y + k * REST_HOOK_SPACING
    reaper.ImGui_DrawList_AddLine(draw_list, x, y0, x - REST_HOOK_DX, y0 - REST_HOOK_DY, COLOR_NOTE, 2.0)
  end
end

-- "Let ring" marking: a dashed horizontal line from a note's own position
-- out to where its actual MIDI sustain (endppq) really ends - the
-- standard guitar-notation way to show a note kept ringing while later,
-- different notes are played (open chords, fingerstyle, pedal tones),
-- without needing true multi-voice notation (a second independent
-- rhythmic layer) just to represent overlap. See this file's header for
-- the detection rule.
local function draw_let_ring_line(draw_list, x0, x1, y, color)
  local x = x0
  while x < x1 do
    local seg_end = math.min(x + LET_RING_DASH_LEN, x1)
    reaper.ImGui_DrawList_AddLine(draw_list, x, y, seg_end, y, color, 1.5)
    x = x + LET_RING_DASH_LEN + LET_RING_GAP_LEN
  end
end

-- Bucket a rest's classified duration into which stand-in glyph to draw.
local function rest_shape(duration_ticks)
  local quarter = config.layout.ppq_per_quarter
  if duration_ticks >= quarter * 4 then return "whole" end
  if duration_ticks >= quarter * 2 then return "half" end
  if duration_ticks >= quarter then return "quarter" end
  if duration_ticks >= quarter / 2 then return "eighth" end
  return "sixteenth"
end

-- Simplified stand-in rest glyphs, not true engraved shapes (same
-- pragmatic choice as the "#"/"n" accidental symbols): whole/half rests
-- as small rectangles hanging from/sitting on the reference line, quarter
-- as a rough zigzag (three alternating diagonal strokes, loosely evoking
-- the real rest's squiggle - not a literal reproduction), eighth/sixteenth
-- as a diagonal stroke with 1 or 2 hooks (draw_rest_hooks) near its top.
local function draw_rest(draw_list, x, y, shape)
  if shape == "whole" then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x - REST_RECT_W / 2, y, x + REST_RECT_W / 2, y + REST_RECT_H, COLOR_NOTE)
  elseif shape == "half" then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x - REST_RECT_W / 2, y - REST_RECT_H, x + REST_RECT_W / 2, y, COLOR_NOTE)
  elseif shape == "quarter" then
    reaper.ImGui_DrawList_AddLine(draw_list, x - 3, y - 8, x + 3, y - 2, COLOR_NOTE, 1.5)
    reaper.ImGui_DrawList_AddLine(draw_list, x + 3, y - 2, x - 3, y + 4, COLOR_NOTE, 1.5)
    reaper.ImGui_DrawList_AddLine(draw_list, x - 3, y + 4, x + 3, y + 8, COLOR_NOTE, 1.5)
  else
    local hooks = shape == "eighth" and 1 or 2
    reaper.ImGui_DrawList_AddLine(draw_list, x - 2, y + 8, x + 2, y - 8, COLOR_NOTE, 1.5)
    draw_rest_hooks(draw_list, x + 2, y - 8, hooks)
  end
end

-- A curved brace connecting a grand staff's two halves, approximated as
-- two bezier arcs meeting at a point that bulges left at the midpoint -
-- not a true calligraphic brace glyph, but reads as one rather than a
-- plain line.
local function draw_brace(draw_list, x, top_y, bottom_y)
  local mid_y = (top_y + bottom_y) / 2
  local tip_x = x - BRACE_BULGE * 1.5
  reaper.ImGui_DrawList_AddBezierCubic(
    draw_list, x, top_y, x - BRACE_BULGE, top_y, tip_x, mid_y, tip_x, mid_y, COLOR_LINE, 2.0, 0)
  reaper.ImGui_DrawList_AddBezierCubic(
    draw_list, tip_x, mid_y, tip_x, mid_y, x - BRACE_BULGE, bottom_y, x, bottom_y, COLOR_LINE, 2.0, 0)
end

-- Chord "seconds" (two notes a diatonic step apart on the same staff)
-- would otherwise draw their noteheads on top of each other. Standard
-- engraving instead keeps the note on the stem's own side at the normal
-- (centered) position and pushes the other note a full notehead-width to
-- the opposite side - which one stays put depends on stem direction:
-- stem-down attaches on the LEFT (see the stem-drawing code below), so
-- the LOWER note of a conflicting pair stays centered and the HIGHER one
-- is pushed right; stem-up attaches on the RIGHT, so the HIGHER note
-- stays and the LOWER is pushed left.
--
-- note_diatonic_offset is each note's diatonic position relative to
-- middle C (note_diatonic[j] - mc, matching middle_line_offset's own
-- units) - used instead of pixel y so this needs no pixel-mapping
-- context of its own.
--
-- For 3+ consecutive seconds (rare for guitar/shamisen content - more a
-- piano cluster-chord scenario), this alternates sides outward from the
-- anchored (stem-side) end; standard references note that only the outer
-- two notes of such a run land on their individually-correct side, with
-- any notes in between necessarily sharing a column with a neighbor -
-- this reproduces that shape without chasing every edge case a dedicated
-- engraving reference would cover.
--
-- Returns note index -> pixel x shift (0 if no conflict).
local function compute_notehead_offsets(note_staff, note_diatonic_offset, radius)
  local shift = {}
  for j = 1, #note_staff do shift[j] = 0 end

  local by_staff = {}
  for j = 1, #note_staff do
    local staff = note_staff[j]
    by_staff[staff] = by_staff[staff] or {}
    table.insert(by_staff[staff], j)
  end

  for staff, indices in pairs(by_staff) do
    if #indices >= 2 then
      table.sort(indices, function(a, b) return note_diatonic_offset[a] < note_diatonic_offset[b] end)

      local sum = 0
      for _, j in ipairs(indices) do sum = sum + note_diatonic_offset[j] end
      -- Local to this event's own notes on this staff, not the beam
      -- group's overall average (computed later, in Pass 2/3) - a
      -- deliberate simplification that only disagrees with the group's
      -- real stem direction in the rare case an event's own local
      -- average pitch sits on the opposite side of the middle line from
      -- its beam group's overall average.
      local stem_down = (sum / #indices) >= middle_line_offset(staff)

      local order = {}
      if stem_down then
        for k = 1, #indices do order[k] = indices[k] end -- low to high (anchor = lowest)
      else
        for k = #indices, 1, -1 do order[#order + 1] = indices[k] end -- high to low (anchor = highest)
      end

      local away_sign = stem_down and 1 or -1 -- pixel direction away from the stem's own side
      local is_offset = false
      for k = 2, #order do
        local cur, prev = order[k], order[k - 1]
        if math.abs(note_diatonic_offset[cur] - note_diatonic_offset[prev]) == 1 then
          is_offset = not is_offset
        else
          is_offset = false
        end
        if is_offset then
          shift[cur] = away_sign * 2 * radius
        end
      end
    end
  end

  return shift
end

-- Pixel extents above/below middle_c_y this staff needs, independent of
-- any particular render_model (fixed by string count alone) - lets the
-- caller pick middle_c_y before drawing, e.g. to stack the tab staff
-- underneath without a two-pass draw.
function M.vertical_extents()
  local half_step = config.layout.notation_line_spacing / 2
  local is_grand = #config.tuning > 6

  local top_offset = TREBLE_OFFSETS[#TREBLE_OFFSETS] + 6
  local bottom_offset = is_grand and (BASS_OFFSETS[1] - 6) or (TREBLE_OFFSETS[1] - 12)

  return top_offset * half_step, -bottom_offset * half_step
end

-- Draws the notation staff for render_model at (origin_x, middle_c_y):
-- middle_c_y is the pixel y representing middle C, the shared reference
-- every note's vertical position is measured from (notation_model's grand
-- staff formula needs this as its anchor). Returns (width, height_above,
-- height_below) - the pixel extents above/below middle_c_y actually used,
-- so the caller can position this relative to other content sharing the
-- window (e.g. the tab staff) without guessing.
-- time_sig: optional {num, denom} - when given, draws the time signature
-- at this system's start (in addition to the clef, which is always
-- drawn). Callers should pass it only for the piece's first system and
-- any system/measure where the meter actually changes, not every system.
function M.draw(ctx, draw_list, origin_x, middle_c_y, render_model, beat_ticks_lookup, measure_ticks, time_sig)
  local half_step = config.layout.notation_line_spacing / 2
  local radius = config.layout.notehead_radius
  local stem_length = config.layout.stem_length
  local string_count = #config.tuning
  local is_grand = string_count > 6
  local key_count = config.key_count or 0
  local mc = notation_model.diatonic_position(notation_model.MIDDLE_C_WRITTEN, key_count)
  local key_acc_map = notation_model.key_accidentals(key_count)

  local function y_at(offset)
    return notation_model.y_for_diatonic(mc + offset, middle_c_y, half_step, mc)
  end

  local content_width = 0
  for i = 1, #render_model do
    if render_model[i].x > content_width then content_width = render_model[i].x end
  end
  content_width = content_width + config.layout.right_margin

  local function draw_staff_lines(offsets)
    for _, offset in ipairs(offsets) do
      local y = y_at(offset)
      reaper.ImGui_DrawList_AddLine(draw_list, origin_x, y, origin_x + content_width, y, COLOR_LINE, 1.0)
    end
  end

  draw_staff_lines(TREBLE_OFFSETS)
  if is_grand then
    draw_staff_lines(BASS_OFFSETS)
    draw_brace(draw_list, origin_x - BRACE_X_OFFSET, y_at(TREBLE_OFFSETS[#TREBLE_OFFSETS]), y_at(BASS_OFFSETS[1]))
  end

  -- Clef and key signature are drawn on every system (a reader needs both
  -- on each new line); the time signature only when the caller says so
  -- (first system, or a meter change) - see time_sig's doc above. The time
  -- signature's x shifts right with the key signature's own width so they
  -- never overlap (see M.timesig_x_offset).
  draw_clef(ctx, draw_list, origin_x + CLEF_X_OFFSET, y_at, "treble")
  draw_key_signature(ctx, draw_list, origin_x + KEYSIG_X_OFFSET, y_at, "treble", key_count)
  if is_grand then
    draw_clef(ctx, draw_list, origin_x + CLEF_X_OFFSET, y_at, "bass")
    draw_key_signature(ctx, draw_list, origin_x + KEYSIG_X_OFFSET, y_at, "bass", key_count)
  end
  if time_sig then
    local timesig_x = origin_x + M.timesig_x_offset(key_count)
    draw_time_sig(ctx, draw_list, timesig_x, y_at, "treble", time_sig.num, time_sig.denom)
    if is_grand then
      draw_time_sig(ctx, draw_list, timesig_x, y_at, "bass", time_sig.num, time_sig.denom)
    end
  end

  -- Pass 1: ledger lines, accidentals, and noteheads, plus per-event/
  -- per-staff y stats for chord-aware stemming and beam geometry (both
  -- need min/max/avg of a note cluster, so compute once here rather than
  -- per consumer). Stem direction itself is NOT decided here - see the
  -- dedicated direction-finalization pass below (after beam grouping) for
  -- why it has to wait until group membership is known.
  local event_staff = {} -- event_staff[i][staff] = {ys, min_y, max_y, avg_y, direction, tie_inherited} - direction/tie_inherited filled in later
  local event_note_staff = {} -- event_note_staff[i] = that event's own note_staff array (Step A), kept for the direction pass below

  -- Accidental-suppression state, reset every time we cross into a new
  -- measure. measure_ticks and render_model are both tick-ordered, so a
  -- single forward pointer is enough - no need to search per note.
  local measure_ptr = 1
  local accidental_state = {} -- diatonic_position -> "sharp" | "natural" (last shown this measure)

  -- Ties connect a note to its predecessor's plotted position - tracked by
  -- string (matching layout_engine's own tie-detection key), not pitch,
  -- since that's what tied_from_prev was computed against.
  local last_notehead_by_string = {}
  local last_staff_by_string = {}
  -- Stem direction a tied note's predecessor last used, by string - a
  -- tied note is one continuous sound, so its stem shouldn't flip
  -- direction mid-tie just because the surrounding chord happens to
  -- change at some point along it (an event's direction is otherwise
  -- decided by ITS OWN chord's average pitch, which can genuinely differ
  -- from one link of the tie to the next even though the tied note's own
  -- pitch never does). Updated below every time an event+staff's
  -- direction is finalized, tied or not, so it always reflects the most
  -- recent decision for that string.
  local last_direction_by_string = {}

  -- Grand-staff split hysteresis: which staff the previous note landed
  -- on, so a phrase hovering near the boundary doesn't flicker between
  -- staves note-to-note (see notation_model.staff_for_note).
  local prev_staff = nil

  -- Beam grouping is computed here, BEFORE Step A's staff decisions below
  -- (not in its usual later spot, alongside stem direction) specifically
  -- so a whole group can be assigned one staff together (group_staff,
  -- filled in as Step A reaches each group's first member) instead of
  -- letting individual notes' hysteresis split a group across the grand
  -- staff - which, since cross-staff beam joining isn't implemented,
  -- otherwise renders as a majority beam plus one or more notes stranded
  -- alone on the other staff. Only needs tick/duration data, which is
  -- already on render_model regardless of any staff/pitch decisions, so
  -- computing it early costs nothing.
  local groups = notation_model.group_beams(render_model, beat_ticks_lookup)
  local event_to_group = {}
  for gi, group in ipairs(groups) do
    for _, ei in ipairs(group) do event_to_group[ei] = gi end
  end
  local group_staff = {} -- group_staff[gi] = "treble" | "bass", decided once per group

  for i = 1, #render_model do
    local event = render_model[i]
    local x = origin_x + event.x
    local by_staff = {}

    if measure_ticks then
      while measure_ptr <= #measure_ticks and event.tick >= measure_ticks[measure_ptr] do
        accidental_state = {}
        measure_ptr = measure_ptr + 1
      end
    end

    -- The first time we reach a group's first member, decide that whole
    -- group's staff at once, from every member's written pitch - not just
    -- this one event's. prev_staff still reflects whatever came right
    -- before this group (the ordinary per-note update below keeps it
    -- current), so the group as a whole gets the same hysteresis
    -- treatment a single note would.
    local gi = event_to_group[i]
    if gi and not group_staff[gi] then
      local written_pitches = {}
      for _, ei in ipairs(groups[gi]) do
        for _, n in ipairs(render_model[ei].notes) do
          if n.string then
            table.insert(written_pitches, notation_model.written_pitch(n.pitch))
          end
        end
      end
      group_staff[gi] = notation_model.staff_for_group(written_pitches, string_count, prev_staff, key_count)
    end

    -- Step A: determine staff/spelling/y for every note in this event, in
    -- original note order - preserves the grand-staff hysteresis's own
    -- note-to-note order dependency (prev_staff), which is unrelated to
    -- the notehead-offset computation in Step B below (that only reads
    -- these results afterward, in a re-sorted order of its own).
    local note_staff, note_diatonic, note_accidental, note_letter, note_y = {}, {}, {}, {}, {}
    for j = 1, #event.notes do
      local note = event.notes[j]
      local wp = notation_model.written_pitch(note.pitch)
      local staff, diatonic, accidental, letter

      if note.string then
        if note.tied_from_prev and last_staff_by_string[note.string] then
          -- Same sounding note as its predecessor - inherit its staff
          -- directly rather than re-deciding via hysteresis, which is
          -- keyed off whatever note happened to render immediately
          -- before this one (possibly an unrelated sibling in the same
          -- chord), not this note's own tie-predecessor. Recomputing
          -- independently could otherwise land a tied note on the other
          -- staff, which - since diatonic position (and so y) is
          -- unaffected by staff choice, but the middle-line comparison
          -- used for stem direction is staff-relative - would flip that
          -- note's stem direction relative to the rest of the tie for no
          -- musical reason.
          staff = last_staff_by_string[note.string]
        elseif gi then
          -- Part of a beamed group - use the whole group's own staff
          -- decision (above) rather than this note's individual
          -- hysteresis, so a beamed run never splits across the grand
          -- staff (cross-staff beam joining isn't implemented - see this
          -- file's header - so a split group would otherwise render as a
          -- majority beam plus one or more notes stranded alone on the
          -- other staff).
          staff = group_staff[gi]
        else
          staff = notation_model.staff_for_note(wp, string_count, prev_staff, key_count)
        end
        diatonic, accidental, letter = notation_model.diatonic_position(wp, key_count)
      else
        -- Outside the instrument's playable range - usually a mute/scrape,
        -- not a real pitch, so pin it to config.layout.x_notehead_offset
        -- (default: middle C) rather than wherever its raw MIDI pitch
        -- would otherwise land, and treat it as belonging to the treble
        -- staff for stemming purposes (consistent with that default).
        staff = "treble"
        diatonic = mc + config.layout.x_notehead_offset
      end
      prev_staff = staff

      note_staff[j] = staff
      note_diatonic[j] = diatonic
      note_accidental[j] = accidental
      note_letter[j] = letter
      note_y[j] = notation_model.y_for_diatonic(diatonic, middle_c_y, half_step, mc)
    end

    -- Step B: notehead x-offsets for chord seconds (see
    -- compute_notehead_offsets' own comment).
    local note_diatonic_offset = {}
    for j = 1, #event.notes do note_diatonic_offset[j] = note_diatonic[j] - mc end
    local note_x_offset = compute_notehead_offsets(note_staff, note_diatonic_offset, radius)

    -- Step C: draw (ledger lines, accidental, notehead, tie), using each
    -- note's own actual x (this event's x plus its offset, if any) -
    -- everywhere a note's own visual position matters. The stem itself
    -- (Pass 2/3, below) stays at the event's own x - only conflicting
    -- noteheads move, never the stem.
    for j = 1, #event.notes do
      local note = event.notes[j]
      local staff, diatonic = note_staff[j], note_diatonic[j]
      local accidental, letter = note_accidental[j], note_letter[j]
      local y = note_y[j]
      local actual_x = x + note_x_offset[j]

      for _, ledger_offset in ipairs(notation_model.ledger_line_offsets(diatonic - mc, is_grand)) do
        local ly = y_at(ledger_offset)
        reaper.ImGui_DrawList_AddLine(
          draw_list, actual_x - radius - LEDGER_OVERHANG, ly, actual_x + radius + LEDGER_OVERHANG, ly, COLOR_LINE, 1.0)
      end

      -- Accidentals imply a real, spellable pitch - skip them for notes
      -- outside the instrument's playable range (see the X-notehead
      -- branch below), which don't represent one. The baseline to compare
      -- against is the key signature's own accidental for this letter
      -- (not always "natural") - a note whose spelling matches what the
      -- key signature already implies needs no symbol; accidental_state
      -- then remembers whatever was last actually shown at this position
      -- this measure, so a repeat within the measure doesn't re-show it
      -- and a later note reverting it shows the correct symbol (including
      -- a natural, if the key signature itself had altered this letter).
      if note.string then
        local baseline = accidental_state[diatonic]
        if baseline == nil then baseline = key_acc_map[letter] or 0 end
        if baseline ~= accidental then
          local symbol = ACCIDENTAL_SYMBOLS[accidental] or "?"
          local w, h = reaper.ImGui_CalcTextSize(ctx, symbol)
          reaper.ImGui_DrawList_AddText(draw_list, actual_x - radius - ACCIDENTAL_GAP - w, y - h / 2, COLOR_NOTE, symbol)
          accidental_state[diatonic] = accidental
        end
      end

      if note.string then
        reaper.ImGui_DrawList_AddCircleFilled(draw_list, actual_x, y, radius, COLOR_NOTE, 0)
      else
        -- Outside the instrument's playable range - the fret heuristic
        -- found no valid string/fret for this pitch. Most often this
        -- represents a string mute or scrape rather than a real note, so
        -- it gets an X notehead (standard notation convention for
        -- percussive/indefinite-pitch sounds) instead of a filled circle.
        reaper.ImGui_DrawList_AddLine(draw_list, actual_x - radius, y - radius, actual_x + radius, y + radius, COLOR_NOTE, 1.5)
        reaper.ImGui_DrawList_AddLine(draw_list, actual_x - radius, y + radius, actual_x + radius, y - radius, COLOR_NOTE, 1.5)
      end

      -- Let ring: this note's actual MIDI sustain outlasts its own
      -- written position - i.e. it's still audible when the NEXT event
      -- starts, whatever string/pitch that next event turns out to be.
      -- Distinct from a tie (a same-pitch/same-string continuation via a
      -- separate MIDI note, already shown by the tie arc above) - this is
      -- one note's sustain genuinely overlapping a DIFFERENT note's onset,
      -- the common "open chord ringing under a moving line" guitar case.
      -- Excludes tied_to_next (layout_engine.compute's barline-crossing
      -- split - see its header) for the same reason: render_model[i + 1]
      -- there is the NEXT TIED SEGMENT OF THIS SAME NOTE, not a different
      -- one, and note.endppq (the note's one true, unsplit end) is always
      -- past that segment's own tick by construction - without this
      -- guard, every non-final segment of a barline-split note would get
      -- a spurious let-ring line alongside the tie curve that already
      -- shows the same continuation.
      -- Only checked against the immediately following event, so a note
      -- ringing across a system-wrap boundary won't get a marking - out
      -- of scope for now, the same class of limitation as this file's
      -- other cross-system simplifications (rests, likewise, only look
      -- within their own system's slice of the render model).
      if note.string and note.endppq and not note.tied_to_next
          and render_model[i + 1] and note.endppq > render_model[i + 1].tick then
        local ring_end_x = origin_x + layout_engine.x_for_tick(render_model, note.endppq)
        draw_let_ring_line(draw_list, actual_x + radius + LET_RING_GAP, ring_end_x, y, COLOR_LET_RING)
      end

      if note.tied_from_prev and note.string and last_notehead_by_string[note.string] then
        local prev = last_notehead_by_string[note.string]
        -- Standard convention: a tie curves on the side opposite the
        -- stem, so it never crosses it - stem down (note at/above the
        -- middle line) means the tie arcs above; stem up, below. Both
        -- ends of a tie share the same pitch (hence the same y and stem
        -- direction), so either note's y would give the same answer here.
        local stem_down = y <= y_at(middle_line_offset(staff))
        local arc_y
        if stem_down then
          arc_y = math.min(prev.y, y) - TIE_ARC_HEIGHT
        else
          arc_y = math.max(prev.y, y) + TIE_ARC_HEIGHT
        end
        reaper.ImGui_DrawList_AddBezierCubic(
          draw_list, prev.x, prev.y, prev.x, arc_y, actual_x, arc_y, actual_x, y, COLOR_NOTE, 1.5, 0)
      end
      if note.string then
        last_notehead_by_string[note.string] = { x = actual_x, y = y }
        last_staff_by_string[note.string] = staff
      end

      by_staff[staff] = by_staff[staff] or {}
      table.insert(by_staff[staff], y)
    end

    event_staff[i] = {}
    for staff, ys in pairs(by_staff) do
      local min_y, max_y, sum = ys[1], ys[1], 0
      for _, y in ipairs(ys) do
        if y < min_y then min_y = y end
        if y > max_y then max_y = y end
        sum = sum + y
      end
      event_staff[i][staff] = { ys = ys, min_y = min_y, max_y = max_y, avg_y = sum / #ys }
    end
    event_note_staff[i] = note_staff
  end

  -- Rests: gaps in the timeline, positioned via layout_engine.x_for_tick
  -- since (unlike notes) they don't have their own render_model entries -
  -- see notation_model.detect_rests for the (simplified) classification.
  -- Always placed at the treble staff's middle line regardless of which
  -- staff nearby notes are on - a further refinement left for later.
  local leading_tick = measure_ticks and measure_ticks[1]
  local rests = notation_model.detect_rests(render_model, leading_tick)
  local rest_y = y_at(middle_line_offset("treble"))
  for _, rest in ipairs(rests) do
    local x = origin_x + layout_engine.x_for_tick(render_model, rest.tick)
    draw_rest(draw_list, x, rest_y, rest_shape(rest.duration_ticks))
  end

  -- Pass 2: stem direction, finalized once per group (or per lone event)
  -- in temporal order, and written back into every member's event_staff
  -- entry - this is what Pass 3 (below) actually draws from, for both
  -- beamed and un-beamed events alike.
  --
  -- Walking in temporal order and resolving a whole group the moment we
  -- reach its first member matters for tie inheritance specifically: an
  -- earlier version of this decided each event's direction independently
  -- (its own local average) BEFORE knowing whether that event would later
  -- turn out to belong to a beam group whose collective average pulls the
  -- group's real, drawn direction a different way - last_direction_by_
  -- string then ended up holding that event's own pre-grouping guess, not
  -- what it was actually drawn with, so a later tied note could inherit a
  -- direction its own predecessor was never actually drawn in. Since a
  -- group's members are always contiguous in render_model (notation_
  -- model.group_beams only ever extends a run forward), resolving each
  -- group as soon as we reach its first member sees every member's data
  -- and never revisits a group twice.
  local group_geo = {} -- group_geo[group_index][staff] = {beam_y, bars = {{level, x_start, x_end}, ...}}
  local group_resolved = {}
  for i = 1, #render_model do
    local gi = event_to_group[i]
    if not gi or not group_resolved[gi] then
      local member_indices = gi and groups[gi] or { i }
      if gi then group_resolved[gi] = true end

      local staff_ys, staff_x = {}, {}
      for _, ei in ipairs(member_indices) do
        local ex = origin_x + render_model[ei].x
        for staff, data in pairs(event_staff[ei]) do
          staff_ys[staff] = staff_ys[staff] or {}
          for _, y in ipairs(data.ys) do table.insert(staff_ys[staff], y) end
          staff_x[staff] = staff_x[staff] or { min = ex, max = ex }
          if ex < staff_x[staff].min then staff_x[staff].min = ex end
          if ex > staff_x[staff].max then staff_x[staff].max = ex end
        end
      end

      if gi then group_geo[gi] = {} end

      for staff, ys in pairs(staff_ys) do
        -- A beam group spanning a grand-staff transition can have member
        -- events that don't touch this particular staff at all (cross-
        -- staff beam joining isn't implemented - see this file's header,
        -- each staff involved gets its own separate beam instead) - the
        -- bar/segment computation below has to walk only the events that
        -- DO belong to this staff, or it ends up comparing durations and
        -- x-positions across two unrelated staves' notes, producing bars
        -- that don't correspond to anything real.
        local staff_members = {}
        for _, ei in ipairs(member_indices) do
          if event_staff[ei][staff] then table.insert(staff_members, ei) end
        end

        local min_y, max_y, sum = ys[1], ys[1], 0
        for _, y in ipairs(ys) do
          if y < min_y then min_y = y end
          if y > max_y then max_y = y end
          sum = sum + y
        end
        local natural_direction = (sum / #ys <= y_at(middle_line_offset(staff))) and "down" or "up"

        -- Tie inheritance: if any note across this group/event on this
        -- staff continues a tie whose predecessor's direction is already
        -- known (last_direction_by_string, as of its true predecessor in
        -- time - everything before this point has already been resolved),
        -- the whole group/event follows that direction instead of its
        -- own local average.
        local direction, tie_inherited = natural_direction, false
        for _, ei in ipairs(member_indices) do
          if tie_inherited then break end
          local event = render_model[ei]
          local ns = event_note_staff[ei]
          for j = 1, #event.notes do
            local note = event.notes[j]
            if note.string and note.tied_from_prev and ns[j] == staff then
              local inherited = last_direction_by_string[note.string]
              if inherited then
                direction, tie_inherited = inherited, true
                break
              end
            end
          end
        end

        for _, ei in ipairs(member_indices) do
          local event = render_model[ei]
          local ns = event_note_staff[ei]
          for j = 1, #event.notes do
            local note = event.notes[j]
            if note.string and ns[j] == staff then
              last_direction_by_string[note.string] = direction
            end
          end
          -- Guarded: a beam group spanning a grand-staff transition could
          -- have a member event with no notes on this particular staff at
          -- all (group_beams groups purely by beat/duration, not staff),
          -- in which case that member simply has nothing to update here.
          if event_staff[ei][staff] then
            event_staff[ei][staff].direction = direction
            event_staff[ei][staff].tie_inherited = tie_inherited
          end
        end

        if gi then
          local beam_y = direction == "down" and (max_y + stem_length) or (min_y - stem_length)
          -- staff_x's min/max are raw notehead x's; stems (Pass 3) are
          -- drawn offset by +/-radius depending on direction, so the beam
          -- has to match that same offset or it'll overhang past the
          -- first stem and fall short of the last one (or vice versa).
          -- Standard convention: stem-down attaches on the LEFT of the
          -- notehead, stem-up on the RIGHT (verified against standard
          -- notation references - not the other way around, despite how
          -- it might read at first glance).
          local stem_x_offset = direction == "down" and -radius or radius

          -- Bar count: a beam needs one parallel bar per level of
          -- subdivision (1 = eighth, 2 = sixteenth, matching
          -- notation_model.duration_dash_count, the same rule the flags
          -- use) - a uniform run of sixteenths needs a full-length DOUBLE
          -- bar, not the single bar every duration got before. For a
          -- level beyond what BOTH notes on either side of a given gap
          -- need, that bar doesn't span the whole group - only the
          -- (merged, contiguous) stretch of gaps that actually need it,
          -- the standard "partial beam" shape for mixed durations within
          -- one beamed group (e.g. an eighth followed by two sixteenths
          -- gets a full first bar but a second bar only over the
          -- sixteenths). A lone shorter note flanked by longer notes on
          -- both sides (neither adjacent gap alone reaching its own
          -- level) won't get a partial-beam stub for the extra level - a
          -- rare edge case, accepted rather than adding a third tier of
          -- geometry for it.
          local dash_count = {}
          local max_bars = 0
          for _, ei in ipairs(staff_members) do
            local dc = notation_model.duration_dash_count(render_model[ei].duration_ticks)
            dash_count[ei] = dc
            if dc > max_bars then max_bars = dc end
          end

          local bars = {}
          for level = 1, max_bars do
            local run_start_ei = nil
            for k = 1, #staff_members - 1 do
              local ei, ei2 = staff_members[k], staff_members[k + 1]
              local qualifies = math.min(dash_count[ei], dash_count[ei2]) >= level
              if qualifies and not run_start_ei then
                run_start_ei = ei
              elseif not qualifies and run_start_ei then
                table.insert(bars, {
                  level = level,
                  x_start = origin_x + render_model[run_start_ei].x + stem_x_offset,
                  x_end = origin_x + render_model[ei].x + stem_x_offset,
                })
                run_start_ei = nil
              end
            end
            if run_start_ei then
              local last_ei = staff_members[#staff_members]
              table.insert(bars, {
                level = level,
                x_start = origin_x + render_model[run_start_ei].x + stem_x_offset,
                x_end = origin_x + render_model[last_ei].x + stem_x_offset,
              })
            end
          end

          -- A group that straddles a grand-staff split can leave only one
          -- note actually on this staff - nothing to beam it to here, so
          -- it needs an individual stem+flag instead (Pass 3's ungrouped
          -- branch), not a beam entry with an empty bar list. Leaving
          -- group_geo[gi][staff] unset (rather than an empty-bars table)
          -- is what makes Pass 3 fall through to that branch for it.
          if #staff_members >= 2 then
            group_geo[gi][staff] = { beam_y = beam_y, bars = bars, direction = direction }
          end
        end
      end
    end
  end

  -- Each bar stacks further from the noteheads than the last (matching
  -- how flags stack multiple hooks toward the notehead in the opposite
  -- sense - here going the other way, since a beam sits at the far end of
  -- the stem, not near the notehead): level 1 (the primary, full-length
  -- bar every beamed note gets) sits at beam_y itself; level 2 (a
  -- sixteenth's second bar) sits BEAM_BAR_GAP further out, and so on.
  for _, staves in pairs(group_geo) do
    for _, geo in pairs(staves) do
      local sign = geo.direction == "down" and 1 or -1
      for _, bar in ipairs(geo.bars) do
        local y = geo.beam_y + (bar.level - 1) * BEAM_BAR_GAP * sign
        reaper.ImGui_DrawList_AddLine(draw_list, bar.x_start, y, bar.x_end, y, COLOR_NOTE, 3.0)
      end
    end
  end

  -- Pass 3: stems - to a shared beam if grouped, otherwise a normal
  -- full-length stem plus a flag if the note's short enough to need one.
  -- Whole notes (or longer) get no stem at all, matching real notation.
  for i = 1, #render_model do
    local event = render_model[i]
    if event.duration_ticks < WHOLE_NOTE_TICKS then
      local x = origin_x + event.x
      local group_index = event_to_group[i]

      for staff, data in pairs(event_staff[i]) do
        local geo = group_index and group_geo[group_index][staff]

        if geo then
          -- geo carries no direction of its own anymore - data.direction
          -- (Pass 2, above) is the single source of truth for every
          -- event, grouped or not, so a beamed event and an individually-
          -- drawn one can never disagree about which way this same field
          -- means "down".
          if data.direction == "down" then
            reaper.ImGui_DrawList_AddLine(draw_list, x - radius, data.min_y, x - radius, geo.beam_y, COLOR_NOTE, 1.0)
          else
            reaper.ImGui_DrawList_AddLine(draw_list, x + radius, data.max_y, x + radius, geo.beam_y, COLOR_NOTE, 1.0)
          end
        else
          -- Direction was already decided in Pass 2 (data.direction),
          -- including tie inheritance - not recomputed from data.avg_y
          -- here, or a tied note sharing an event with a differently-
          -- pitched chord-mate at some point along the tie could get a
          -- direction that disagrees with the rest of its own tie chain.
          -- Stem-down attaches on the LEFT of the notehead, stem-up on
          -- the RIGHT (see the matching comment on stem_x_offset above).
          if data.direction == "down" then
            local tip_y = data.max_y + stem_length
            reaper.ImGui_DrawList_AddLine(draw_list, x - radius, data.min_y, x - radius, tip_y, COLOR_NOTE, 1.0)
            if event.duration_ticks < config.layout.ppq_per_quarter then
              draw_flags(draw_list, x - radius, tip_y, notation_model.duration_dash_count(event.duration_ticks), "down")
            end
          else
            local tip_y = data.min_y - stem_length
            reaper.ImGui_DrawList_AddLine(draw_list, x + radius, data.max_y, x + radius, tip_y, COLOR_NOTE, 1.0)
            if event.duration_ticks < config.layout.ppq_per_quarter then
              draw_flags(draw_list, x + radius, tip_y, notation_model.duration_dash_count(event.duration_ticks), "up")
            end
          end
        end
      end
    end
  end

  local height_above, height_below = M.vertical_extents()
  return content_width, height_above, height_below
end

return M
