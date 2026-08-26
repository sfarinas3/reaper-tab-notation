-- Tuning/capo/layout defaults. Full string-count configurability and
-- ExtState persistence land in Phase 5 (ui_chrome.lua); this is just the
-- Phase 1/2 default set.
--
-- Convention: tuning[1] is the highest-pitched string (thinnest, drawn on
-- top of the tab staff - standard tab notation numbers strings this way),
-- tuning[#tuning] is the lowest-pitched string (thickest). Adding strings
-- for extended-range instruments appends to the end (a new lowest string)
-- rather than shifting existing string numbers.

local M = {}

-- Standard 8-string (F#-B-E-A-D-G-B-E), high to low: e4, B3, G3, D3, A2, E2,
-- B1, F#1. Set here as the current test default since Phase 2 testing is
-- against real 8-string MIDI; becomes user-selectable in Phase 5. For
-- standard 6-string, use { 64, 59, 55, 50, 45, 40 }.
M.tuning = { 64, 59, 55, 50, 45, 40, 35, 30 }
-- Which of ui_chrome.lua's INSTRUMENTS this is - drives instrument-
-- specific tab rendering (e.g. draw_tab.lua's bunkafu-style duration
-- dashes, shamisen only). Set explicitly by the "Instrument" dropdown,
-- not inferred from string count each frame - so it stays "Shamisen"
-- (keeping that rendering) even after manually retuning away from
-- Honchoshi, the same way config.key_count stays put across other edits.
M.instrument = "Guitar"
M.capo = 0
-- Highest playable fret/position - not guitar-specific despite the name
-- (e.g. shamisen bunkafu positions commonly run to ~18-19). User-editable
-- via ui_chrome.lua's "Max Fret" field, and set automatically by its
-- "Instrument" preset dropdown.
M.max_fret = 24

-- Starting key signature, as a signed circle-of-fifths count (positive =
-- that many sharps, negative = that many flats, 0 = C major/no
-- accidentals - see notation_model.lua's M.KEYS for the full list and
-- spelling logic). 0 exactly reproduces this app's pre-key-signature
-- behavior, so it stays the default.
M.key_count = 0

-- Score header info (title/composer/arranger), drawn by main.lua above the
-- first system like a real printed score's title page - see ui_chrome.
-- lua's "Score Info" section for the editable fields. All default to
-- blank (no header drawn at all) so an untouched take looks exactly like
-- this app did before this feature existed. title is piece-specific (e.g.
-- "Sakura") and only ever comes from the CURRENT take's own saved P_EXT
-- data, never a global fallback - see ui_chrome.lua's load_for_take.
-- composer/arranger are person-specific and DO fall back to a global
-- "last used" ExtState value, the same convenience save_persisted/
-- load_persisted already give instrument/tuning, since one user's own
-- transcriptions usually share the same composer/arranger.
M.title = ""
M.composer = ""
M.arranger = ""

-- Panel colors (0xRRGGBBAA, ReaImGui's packed format), user-editable via
-- ui_chrome.lua's "Colors" section: color_bg is the window background,
-- color_fg is the single "ink" color covering noteheads/stems/text/staff
-- lines/tab lines - just these two for now (see ui_chrome.lua's header for
-- how secondary/dimmed elements like barlines and ties derive from them
-- rather than needing their own settings). Defaults match this app's
-- original hardcoded look (a dark panel, white ink) so existing users see
-- no change until they open the Colors section.
M.color_bg = 0x1E1E1EFF
M.color_fg = 0xFFFFFFFF

-- Japanese-capable font draw_tab.lua's shamisen technique markers (real
-- katakana, e.g. ハ for hajiki) are drawn with - see main.lua, which loads
-- and attaches it once at startup. jp_font_file is tried first, as an
-- exact file path (msgothic.ttc ships with every Windows install since
-- Vista, regardless of display language); jp_font_family is the fallback
-- if that file isn't found (e.g. a non-Windows REAPER install) - a
-- by-name lookup, which turned out not to reliably resolve to a font with
-- Japanese glyphs on its own. Change jp_font_file to another font file's
-- full path (e.g. a Noto Sans JP .ttf) if msgothic.ttc ever isn't
-- available on the target machine.
M.jp_font_file = "C:\\Windows\\Fonts\\msgothic.ttc"
M.jp_font_family = "MS Gothic"

-- Hand-tuned cost weights for the fret-assignment DP (fret_heuristic.lua).
-- No learned model at this scale - these are starting points, expected to
-- be adjusted after eyeballing real test riffs (see plan's Phase 2
-- verification step).
M.weights = {
  open_string_bonus = 1.0,        -- subtracted from cost when fret == 0
  fret_height_penalty = 0.05,     -- cost per fret, mild preference for lower frets
  max_comfortable_stretch = 4,    -- frets a hand can span without penalty
  stretch_penalty = 2.0,          -- cost per fret beyond max_comfortable_stretch, within a chord
  position_change_weight = 1.0,   -- cost per fret of hand-position movement between events
  string_change_weight = 0.3,     -- cost per string of average string-index movement between events
}

-- Shared layout constants (layout_engine.lua, draw_tab.lua, draw_notation.lua).
M.layout = {
  ppq_per_quarter = 960,  -- REAPER's MIDI API tick resolution (MIDI_GetNote positions)
  min_gap = 6,            -- minimum pixels between adjacent events' rendered content
  left_margin = 90,       -- room for the clef (every system) + time signature (first system, and wherever it changes) + a clear gap before the first note
  right_margin = 24,
  line_height = 16,       -- vertical spacing between tab staff lines

  notation_line_spacing = 8, -- px between adjacent notation staff lines (half of this per diatonic step)
  notehead_radius = 3,
  stem_length = 24,
  staff_gap = 26,         -- px gap between the notation staff and the tab staff below it
  -- px gap between one wrapped system's tab staff and the next system's
  -- notation staff. Has to clear more than just the tab lines themselves:
  -- fret numbers/duration dashes/technique glyphs hang below the bottom
  -- tab string (shamisen especially - a fret number plus dashes plus a
  -- katakana technique marker is the tallest thing this app draws below a
  -- staff), and the incoming system's own tempo/measure-number labels sit
  -- above its notation staff (see main.lua's TEMPO_LABEL_ABOVE_GAP). Too
  -- small a gap here means those two collide - the exact overlap this was
  -- raised against.
  system_gap = 64,

  -- Diatonic offset from middle C (0 = middle C itself) where X-notehead
  -- notes (outside the instrument's playable range - usually a mute or
  -- scrape, not a real pitch) get pinned on the notation staff, instead
  -- of wherever their raw MIDI pitch would otherwise land. One global
  -- default for now; a per-note override is a natural Phase 5 UI addition.
  x_notehead_offset = 0,

  -- Which string (config.tuning's 1-based convention) the same notes get
  -- pinned to on the tab staff, shown as "x" text instead of a fret
  -- number. Also one global default for now, also a natural per-note
  -- override for Phase 5.
  x_notehead_string = 1,

  -- Duration-class width table, roughly logarithmic so short-note passages
  -- don't become absurdly wide. width_for_duration() interpolates between
  -- entries in log-tick space; ticks are in ppq_per_quarter units. Also
  -- used by notation_model.detect_rests to classify a timeline gap into
  -- the largest standard rest that fits.
  duration_classes = {
    { ticks = 60,   width = 14 },  -- 64th
    { ticks = 120,  width = 19 },  -- 32nd
    { ticks = 240,  width = 26 },  -- 16th
    { ticks = 480,  width = 35 },  -- 8th
    { ticks = 960,  width = 48 },  -- quarter
    { ticks = 1920, width = 72 },  -- half
    { ticks = 3840, width = 112 }, -- whole
  },
}

return M
