-- Pitch -> staff position, independent of any drawing code. Handles
-- guitar's notation convention (written pitch sounds an octave lower than
-- what's on the page) and picks a diatonic spelling for vertical
-- placement - even a Phase 4a notehead-only render needs to know which
-- line/space a pitch sits on, which is a letter-name (diatonic) question,
-- not just a chromatic one.
--
-- Spelling is key-signature-aware (added alongside the key-signature UI):
-- given a signed sharps/flats count (positive = sharps, negative = flats,
-- 0 = C major/no accidentals - the circle-of-fifths position, which is all
-- that matters for spelling/key-signature purposes since a major key and
-- its relative minor share one signature), each of the 7 diatonic letters
-- is altered exactly as the key signature says, and the 5 remaining
-- chromatic pitch classes are spelled as an extra sharp on the letter
-- below (sharp keys, and C) or an extra flat on the letter above (flat
-- keys) - the standard direction-agnostic convention real key signatures
-- already imply (sharp keys keep extending with sharps, flat keys with
-- flats). key_count = 0 everywhere below reproduces the exact fixed
-- sharps-only spelling this module used before key signatures existed, so
-- the default behavior is unchanged.

local config = require('config')

local M = {}

-- Guitar sounds an octave below what's written (the implicit "8" under a
-- treble clef) - also the split point for grand staff, on WRITTEN pitch
-- per the plan (not raw MIDI pitch).
M.MIDDLE_C_WRITTEN = 60

local LETTER_ORDER = { "C", "D", "E", "F", "G", "A", "B" }
local LETTER_STEP = { C = 0, D = 1, E = 2, F = 3, G = 4, A = 5, B = 6 }
local NATURAL_PC = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }

-- The order each additional sharp/flat is added to a key signature,
-- standard and independent of clef - also the order key-signature glyphs
-- are conventionally drawn in.
M.SHARP_ORDER = { "F", "C", "G", "D", "A", "E", "B" }
M.FLAT_ORDER = { "B", "E", "A", "D", "G", "C", "F" }

-- The 15 standard major keys, ordered around the circle of fifths, each
-- with its relative minor (a minor third below the tonic - shares the
-- exact same key signature, so it's just a label, not a separate entry).
-- count > 0 = that many sharps, count < 0 = that many flats.
M.KEYS = {
  { name = "C", relative_minor = "A", count = 0 },
  { name = "G", relative_minor = "E", count = 1 },
  { name = "D", relative_minor = "B", count = 2 },
  { name = "A", relative_minor = "F#", count = 3 },
  { name = "E", relative_minor = "C#", count = 4 },
  { name = "B", relative_minor = "G#", count = 5 },
  { name = "F#", relative_minor = "D#", count = 6 },
  { name = "C#", relative_minor = "A#", count = 7 },
  { name = "F", relative_minor = "D", count = -1 },
  { name = "Bb", relative_minor = "G", count = -2 },
  { name = "Eb", relative_minor = "C", count = -3 },
  { name = "Ab", relative_minor = "F", count = -4 },
  { name = "Db", relative_minor = "Bb", count = -5 },
  { name = "Gb", relative_minor = "Eb", count = -6 },
  { name = "Cb", relative_minor = "Ab", count = -7 },
}

-- letter -> accidental (-1/0/1) this key signature applies to it.
function M.key_accidentals(count)
  local acc = {}
  if count > 0 then
    for i = 1, count do acc[M.SHARP_ORDER[i]] = 1 end
  elseif count < 0 then
    for i = 1, -count do acc[M.FLAT_ORDER[i]] = -1 end
  end
  return acc
end

-- Ordered list of {letter, accidental} this key signature alters, in the
-- standard drawing order (SHARP_ORDER/FLAT_ORDER) - what draw_notation.lua
-- draws at the start of every system, right after the clef.
function M.key_signature_letters(count)
  local out = {}
  if count > 0 then
    for i = 1, count do out[i] = { letter = M.SHARP_ORDER[i], accidental = 1 } end
  elseif count < 0 then
    for i = 1, -count do out[i] = { letter = M.FLAT_ORDER[i], accidental = -1 } end
  end
  return out
end

-- pitch_class (0-11) -> {letter, accidental}, for one key. See this file's
-- header for the spelling rule. Memoized per count (only 15 possible
-- values) since it's rebuilt from scratch each call otherwise.
local spelling_cache = {}
local function build_spelling_table(count)
  local key_acc = M.key_accidentals(count)
  local pc_table = {}

  for _, letter in ipairs(LETTER_ORDER) do
    local extra = key_acc[letter] or 0
    local pc = (NATURAL_PC[letter] + extra) % 12
    pc_table[pc] = { letter = letter, accidental = extra }
  end

  -- A chromatic pitch class that exactly matches an ALTERED letter's own
  -- unaltered natural pitch is that letter canceled back to natural (e.g.
  -- F-natural in G major, which keeps G major's own F# everywhere else) -
  -- the standard spelling. Has to run before the neighbor-based fallback
  -- below, or a case like that would come out as "E#" instead - technically
  -- an enharmonically valid spelling, but never how it's actually written.
  for letter, _ in pairs(key_acc) do
    local natural_pc = NATURAL_PC[letter] % 12
    if not pc_table[natural_pc] then
      pc_table[natural_pc] = { letter = letter, accidental = 0 }
    end
  end

  -- Whatever's still missing: no two remaining chromatic pcs are ever
  -- adjacent to each other for any major-scale letter set (a property of
  -- any 7-of-12 "maximally even" scale) - only the 7 primary diatonic
  -- slots above ever sit next to a missing one, so every pc_table[pc-1]/
  -- [pc+1] looked up below is already filled in, regardless of how many
  -- slots the natural-cancellation pass just claimed. Order doesn't matter.
  local prefer_sharp = count >= 0
  for pc = 0, 11 do
    if not pc_table[pc] then
      if prefer_sharp then
        local base = pc_table[(pc - 1) % 12]
        pc_table[pc] = { letter = base.letter, accidental = base.accidental + 1 }
      else
        local base = pc_table[(pc + 1) % 12]
        pc_table[pc] = { letter = base.letter, accidental = base.accidental - 1 }
      end
    end
  end

  return pc_table
end

local function spelling_table(count)
  local cached = spelling_cache[count]
  if cached then return cached end
  cached = build_spelling_table(count)
  spelling_cache[count] = cached
  return cached
end

-- Sounding MIDI pitch -> written pitch (what actually gets placed on the
-- staff).
function M.written_pitch(midi_pitch)
  return midi_pitch + 12
end

-- Translates between this app's INTERNAL string index (config.tuning's own
-- array position - always 1 = highest-pitched/thinnest string, #tuning =
-- lowest-pitched/thickest, regardless of instrument; see config.lua's
-- header) and the string NUMBER a user actually types/sees. Guitar's own
-- numbering already matches the internal index exactly (string 1 = high
-- e), so this is the identity for Guitar. Shamisen numbers the OPPOSITE
-- way - the lowest string is 1, the highest is the highest number (e.g. 3
-- on a 3-string shamisen) - so for Shamisen this reverses the range.
--
-- Self-inverse (reversing a 1..n range twice returns the original), so the
-- exact same formula converts in EITHER direction - internal-to-display
-- when formatting a label/text field, or display-to-internal when parsing
-- one back. Every user-facing string-number label or typed field should
-- go through this rather than showing/parsing the internal index directly,
-- so a numbering fix only ever needs to happen here - see ui_chrome.lua's
-- tuning fields/instrument summary, note_editor.lua's string-pin popup,
-- and tab_editor.lua's String field/Tab Code/Move-to-String popup for the
-- call sites that rely on this.
function M.display_string_number(cfg, string_idx)
  if cfg.instrument == "Shamisen" then
    return #cfg.tuning - string_idx + 1
  end
  return string_idx
end

-- Shamisen tsubo (fret/position) numbering is NOT consecutive integers -
-- traditional shamisen tab gives each 12-semitone octave 10 running
-- integer labels plus 2 "iro" (half-tone) positions marked with a
-- sharp/flat-style symbol instead of a number: "#"/"b" in the octave
-- containing the open string, "1#"/"1b" the next octave up, "2#"/"2b" the
-- one after that, and so on - the integer count keeps climbing by 10 each
-- octave (...9, 10, 11...19, 20...) around the two skipped/symbol slots.
-- User-specified mapping, semitone -> label:
--   0,1,2,3,#,4,5,6,7,8,9,b,10,11,12,13,1#,14,15,16,17,18,19,1b,20,...
-- Guitar frets are already plain consecutive integers, so display_fret_
-- label/parse_fret_label are the identity (tostring/tonumber) for Guitar -
-- this pair only actually does something for Shamisen. Every user-facing
-- fret label/typed field should go through these instead of tostring(fret)
-- or tonumber(text) directly, so this numbering only ever needs to happen
-- here - see draw_tab.lua's label_for and tab_editor.lua's parse_fret_
-- input/format_fret_with_technique for the call sites that rely on this.
local function shamisen_fret_to_label(fret)
  local oct = math.floor(fret / 12)
  local pos = fret % 12
  local prefix = oct == 0 and "" or tostring(oct)
  if pos == 4 then return prefix .. "#" end
  if pos == 11 then return prefix .. "b" end
  local step = pos <= 3 and pos or (pos - 1)
  return tostring(oct * 10 + step)
end

-- Inverse of shamisen_fret_to_label - parses a typed/rendered Shamisen
-- fret label back into a semitone fret number, or nil if it isn't a valid
-- label (same nil-on-invalid contract as tonumber). Accepts "#"/"b" case-
-- insensitively (matches strip_technique_suffix's own case-insensitivity
-- in tab_editor.lua) with an optional leading octave-count prefix.
local function shamisen_label_to_fret(label)
  local trimmed = (label or ""):match("^%s*(.-)%s*$")
  if trimmed == "" then return nil end

  local prefix, symbol = trimmed:match("^(%d*)([#bB])$")
  if symbol then
    local oct = tonumber(prefix) or 0
    local pos = (symbol:lower() == "#") and 4 or 11
    return oct * 12 + pos
  end

  local n = tonumber(trimmed)
  if not n then return nil end
  n = math.floor(n + 0.5)
  if n < 0 then return nil end
  local oct = math.floor(n / 10)
  local step = n % 10
  local pos = step <= 3 and step or (step + 1)
  return oct * 12 + pos
end

function M.display_fret_label(cfg, fret)
  if cfg.instrument == "Shamisen" then
    return shamisen_fret_to_label(fret)
  end
  return tostring(fret)
end

function M.parse_fret_label(cfg, label)
  if cfg.instrument == "Shamisen" then
    return shamisen_label_to_fret(label)
  end
  local n = tonumber(label)
  if not n then return nil end
  return math.floor(n + 0.5)
end

local SIMPLE_NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

-- Plain sharps-only "C4"/"F#3"/"B1" note name for a raw MIDI pitch -
-- standard scientific pitch notation (middle C = C4, MIDI 60). NOT
-- key-signature-aware (contrast M.diatonic_position, which spells
-- according to the current key for staff placement/accidentals - a
-- heavier-weight call that also needs a written, not sounding, pitch);
-- this is deliberately the simpler, always-available spelling, shared by
-- ui_chrome.lua's tuning-field display and the optional "show note names"
-- cheat-sheet overlay (draw_tab.lua/draw_notation.lua) so every place in
-- the app that just wants "what note is this" agrees on the same string
-- for the same pitch.
function M.pitch_to_name(pitch)
  local pitch_class = pitch % 12
  local octave = math.floor(pitch / 12) - 1
  return SIMPLE_NOTE_NAMES[pitch_class + 1] .. octave
end

-- Single integer diatonic position: increases by exactly 1 per natural
-- letter name regardless of octave/accidental, so any two positions are
-- directly comparable as staff-steps. Second return value: the accidental
-- needed relative to the letter's own natural pitch (0 = none, +-1 =
-- sharp/flat, occasionally +-2 for a double-sharp/flat in an extreme key -
-- see the header). Third return value: the letter itself, so callers can
-- compare against the key signature's own default for that letter (rather
-- than always "natural") to decide whether a symbol needs to be shown.
function M.diatonic_position(written_pitch, key_count)
  local pitch_class = written_pitch % 12
  local spelling = spelling_table(key_count or 0)[pitch_class]
  local letter, accidental = spelling.letter, spelling.accidental
  local octave = math.floor((written_pitch - (NATURAL_PC[letter] + accidental)) / 12) - 1
  return octave * 7 + LETTER_STEP[letter], accidental, letter
end

-- Diatonic steps from middle C within which a note prefers to stay on
-- prev_staff rather than switching (~3 ledger lines - a ledger line is
-- every 2 steps).
local HYSTERESIS_RANGE = 6

-- "treble" for every note when string_count <= 6 (single-clef guitar);
-- extended-range instruments split at middle C on written pitch by
-- default. prev_staff (optional - the previous note's staff, from the
-- same drawing pass) lets a note within HYSTERESIS_RANGE of the split
-- stay on prev_staff instead of switching, so a phrase hovering near the
-- boundary doesn't flicker between staves note-to-note. key_count affects
-- this only indirectly, via diatonic_position's spelling - the split
-- itself still compares raw written pitch against middle C.
function M.staff_for_note(written_pitch, string_count, prev_staff, key_count)
  if string_count <= 6 then return "treble" end

  if prev_staff then
    local mc = M.diatonic_position(M.MIDDLE_C_WRITTEN, key_count)
    local diatonic_offset = M.diatonic_position(written_pitch, key_count) - mc
    -- Strictly less than, not <=: a note sitting at exactly
    -- HYSTERESIS_RANGE steps out was getting pulled onto the previous
    -- staff at the boundary itself (e.g. a B a sixth above middle C,
    -- offset exactly 6, inheriting bass from an immediately preceding
    -- low note) instead of landing on its own natural staff - which
    -- could split an otherwise-uniform beamed group across both staves
    -- (3 notes correctly beamed on one staff, the 4th stranded alone on
    -- the other, since cross-staff beam joining isn't implemented).
    if math.abs(diatonic_offset) < HYSTERESIS_RANGE then
      return prev_staff
    end
  end

  if written_pitch >= M.MIDDLE_C_WRITTEN then return "treble" else return "bass" end
end

-- Decides ONE staff for an entire beamed group at once, from the group's
-- own collective average written pitch, instead of letting each member's
-- individual hysteresis potentially land on different staves - cross-
-- staff beam joining isn't implemented (see draw_notation.lua's header),
-- so a mixed-staff group would otherwise render as a majority beam plus
-- one or more notes stranded alone on the other staff, which is what
-- this replaces. Reuses staff_for_note's own hysteresis/default rule
-- against the group's average rather than duplicating it - the average is
-- rounded to the nearest integer first, since diatonic_position expects a
-- real pitch class, not a fractional one. written_pitches: every member
-- note's written pitch (X-notehead/unreachable notes excluded by the
-- caller, same as normal per-note staff_for_note usage); an empty list
-- (a group with no real pitches at all) defaults to treble, same as
-- staff_for_note's own always-treble fallback for <=6 strings.
function M.staff_for_group(written_pitches, string_count, prev_staff, key_count)
  if string_count <= 6 or #written_pitches == 0 then return "treble" end

  local sum = 0
  for _, wp in ipairs(written_pitches) do sum = sum + wp end
  local avg_written_pitch = math.floor(sum / #written_pitches + 0.5)

  return M.staff_for_note(avg_written_pitch, string_count, prev_staff, key_count)
end

-- Diatonic offsets (from middle C) where ledger lines are needed for a
-- note at diatonic_offset, given whether this is a single treble staff or
-- a grand staff. This is a pure function of the offset - not of which
-- staff the note was assigned to for stemming purposes - since ledger
-- lines only depend on distance from the nearest real staff line.
--
-- Ledger lines only ever fall on "line" positions (even offsets): middle
-- C (offset 0) is itself a line position, since the staff's line/space
-- alternation is continuous through the gap between a grand staff's two
-- halves (treble's bottom line E4=+2 is a line, D4=+1 a space, C4=0 a
-- line again, following straight through).
function M.ledger_line_offsets(diatonic_offset, is_grand)
  local lines = {}

  if diatonic_offset > 10 then
    for o = 12, diatonic_offset, 2 do table.insert(lines, o) end
    return lines
  end

  if is_grand then
    if diatonic_offset < -10 then
      for o = -12, diatonic_offset, -2 do table.insert(lines, o) end
    elseif diatonic_offset == 0 then
      table.insert(lines, 0)
    end
  elseif diatonic_offset < 2 then
    for o = 0, diatonic_offset, -2 do table.insert(lines, o) end
  end

  return lines
end

-- diatonic_pos -> pixel y. One continuous formula shared across both
-- staves of a grand staff (rather than a separate formula per clef) so
-- middle C's ledger line naturally falls exactly between them with no
-- special-casing - middle_c_y is the pixel y that represents middle C,
-- and half_step is the pixel distance for one diatonic step (half the
-- distance between two staff lines, since lines and spaces alternate).
-- mc: middle C's own diatonic_position under the current key (callers
-- already compute this once per draw pass via M.diatonic_position(
-- M.MIDDLE_C_WRITTEN, key_count) - passed in rather than read from a
-- module constant since it's now key-dependent, not fixed).
function M.y_for_diatonic(diatonic_pos, middle_c_y, half_step, mc)
  return middle_c_y - (diatonic_pos - mc) * half_step
end

-- Finds the 0-based measure index containing QN position qn, using only
-- TimeMap_GetMeasureInfo - confirmed 0-based (its own index parameter and
-- what it accepts are the same convention). Deliberately avoids
-- TimeMap_QNToMeasures for this: its own indexing convention relative to
-- GetMeasureInfo's isn't independently confirmed, and mixing two APIs
-- that might not agree is exactly the kind of thing that produces a
-- consistent, compounding offset (one mismatch in this lookup, another
-- wherever the result gets +1'd for display) rather than a one-off bug -
-- which is what an earlier version of this code did. Walks from a rough
-- guess (assumes ~4 QN/measure, corrected regardless of actual time
-- signature by the walk itself) rather than a bisection, since a
-- no-frills linear correction from a decent guess is simpler and this
-- only runs once per note-hash change, not per frame.
local function find_measure_index(qn)
  local guess = math.max(0, math.floor(qn / 4))
  for _ = 1, 10000 do -- defensive cap against a runaway loop
    local _, qn_start, qn_end = reaper.TimeMap_GetMeasureInfo(0, guess)
    if not qn_start then
      return math.max(guess - 1, 0)
    end
    if qn < qn_start then
      if guess == 0 then return 0 end -- e.g. an item placed before project time 0
      guess = guess - 1
    elseif qn >= qn_end then
      guess = guess + 1
    else
      return guess
    end
  end
  return guess
end

-- Tick positions (take-relative PPQ) where barlines belong, reconciled
-- against REAPER's actual project measure grid - walks
-- TimeMap_GetMeasureInfo measure-by-measure starting from wherever the
-- take actually begins (via find_measure_index), rather than assuming
-- tick 0 is a downbeat. An item that starts mid-measure gets correctly
-- offset barlines; mid-piece time-signature and tempo changes are honored
-- too, as a side effect of asking each measure for its own info instead
-- of assuming one fixed value for the whole take.
--
-- Returns two parallel arrays:
-- - boundaries: ticks, as before.
-- - info: per-measure records -
--     { reaper_measure, beat_ticks, tempo, timesig_num, timesig_denom }
--   - reaper_measure: REAPER's own 1-based absolute project measure
--     number for the measure starting at that boundary (matching what
--     its ruler/UI displays), so callers can label measures against
--     REAPER's numbering without a second, uncached lookup per frame.
--   - beat_ticks: this measure's beat length in ticks (from its own time
--     signature), for M.beat_ticks_lookup - beam grouping and tie
--     inference are meter-aware, not pinned to whatever meter was active
--     at the take's start.
--   - tempo: this measure's tempo (BPM, rounded to the nearest integer -
--     floating-point tempo values otherwise register as "changed" on
--     essentially every measure from rounding noise alone).
--   - timesig_num/timesig_denom: this measure's time signature, for
--     drawing it and for detecting meter changes (both, like tempo, by a
--     caller just comparing consecutive entries).
function M.measure_boundaries(take, events)
  local last_tick = 0
  for i = 1, #events do
    local notes = events[i].notes
    for j = 1, #notes do
      if notes[j].endppq and notes[j].endppq > last_tick then
        last_tick = notes[j].endppq
      end
    end
  end

  if not take then return { 0, last_tick }, {} end

  local take_start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, 0)
  local take_start_qn = reaper.TimeMap_timeToQN_abs(0, take_start_time)
  local measure = find_measure_index(take_start_qn)

  local boundaries, info = {}, {}
  local prev_qn = nil
  local MAX_MEASURES = 2000 -- defensive cap against a runaway loop

  for _ = 1, MAX_MEASURES do
    local _, qn_start, _, timesig_num, timesig_denom, tempo = reaper.TimeMap_GetMeasureInfo(0, measure)
    -- qn_start not increasing means we've walked past the end of whatever
    -- REAPER considers valid measures - stop rather than trust a specific
    -- retval convention for "out of range" that isn't documented clearly.
    if not qn_start or (prev_qn and qn_start <= prev_qn) then break end
    prev_qn = qn_start

    local proj_time = reaper.TimeMap_QNToTime_abs(0, qn_start)
    local tick = reaper.MIDI_GetPPQPosFromProjTime(take, proj_time)
    local num = (timesig_num and timesig_num > 0) and timesig_num or 4
    local denom = (timesig_denom and timesig_denom > 0) and timesig_denom or 4

    table.insert(boundaries, tick)
    table.insert(info, {
      reaper_measure = measure + 1,
      beat_ticks = config.layout.ppq_per_quarter * 4 / denom,
      tempo = (tempo and tempo > 0) and math.floor(tempo + 0.5) or 120,
      timesig_num = num,
      timesig_denom = denom,
    })

    if tick > last_tick then break end
    measure = measure + 1
  end

  return boundaries, info
end

-- Returns a function(tick) -> beat_ticks active at that position, from
-- measure_boundaries' parallel boundaries/info arrays. Must be called
-- with monotonically increasing ticks (both consumers - layout_engine.
-- compute's tie inference and group_beams' beat bucketing - walk events
-- in tick order already), since it advances a single internal pointer
-- rather than searching from scratch each call.
function M.beat_ticks_lookup(measure_ticks, measure_info)
  local ptr = 1
  local n = #measure_ticks
  return function(tick)
    while ptr < n and tick >= measure_ticks[ptr + 1] do
      ptr = ptr + 1
    end
    local info = measure_info[ptr]
    return info and info.beat_ticks or config.layout.ppq_per_quarter
  end
end

-- Number of subdivision marks a note of this duration needs: 0 for a
-- quarter note or longer, then +1 for each halving below that (1 for an
-- eighth, 2 for a sixteenth, 3 for a thirty-second, capped at 4 for
-- anything shorter - matching config.layout.duration_classes' own
-- shortest class, a 64th). Shared by draw_notation.lua's stem flags and
-- draw_tab.lua's bunkafu-style duration dashes (shamisen only) - one
-- shared rule so the two staves never disagree about how many marks a
-- given duration gets.
function M.duration_dash_count(duration_ticks)
  local quarter = config.layout.ppq_per_quarter
  if duration_ticks >= quarter then return 0 end
  if duration_ticks >= quarter / 2 then return 1 end
  if duration_ticks >= quarter / 4 then return 2 end
  if duration_ticks >= quarter / 8 then return 3 end
  return 4
end

-- Whether duration_ticks represents a DOTTED standard value (1.5x a plain
-- note/rest duration - e.g. a dotted half is a half plus half of a half,
-- 3 beats) rather than a plain one. Draw_notation.lua uses this for both
-- noteheads and rests - draw_tab.lua's bunkafu dashes (shamisen) don't
-- have a dotted concept of their own, so this is notation-staff-only.
--
-- Classification is nearest-neighbor among three candidates: the largest
-- plain standard value at or below duration_ticks (floor), that value's
-- own dotted (1.5x) equivalent, and the next plain value up (ceil) - not
-- just "closer to dotted than to floor," since a duration close enough to
-- ceil (e.g. a barely-short half note) should read as that longer plain
-- value, not as a dotted quarter. This mirrors how the rest of this file
-- already accepts nearest-neighbor/greedy classification for imprecise
-- real MIDI timing (see M.detect_rests' own comment) rather than
-- requiring exact tick matches.
function M.is_dotted_duration(duration_ticks)
  -- Independent of config.layout.duration_classes (that table's pixel
  -- widths serve a different purpose, spacing interpolation, and its
  -- 64th/32nd extremes aren't relevant to dot detection).
  local quarter = config.layout.ppq_per_quarter
  local ticks = { quarter / 8, quarter / 4, quarter / 2, quarter, quarter * 2, quarter * 4 }
  local floor_ticks = ticks[1]
  local ceil_ticks = nil
  for _, t in ipairs(ticks) do
    if t <= duration_ticks then
      floor_ticks = t
    elseif not ceil_ticks then
      ceil_ticks = t
    end
  end
  ceil_ticks = ceil_ticks or floor_ticks * 2
  local dotted_ticks = floor_ticks * 1.5

  local d_floor = math.abs(duration_ticks - floor_ticks)
  local d_dotted = math.abs(duration_ticks - dotted_ticks)
  local d_ceil = math.abs(duration_ticks - ceil_ticks)

  return d_dotted < d_floor and d_dotted <= d_ceil
end

-- Groups consecutive beamable events (duration shorter than a quarter
-- note) that fall within the same beat into beam groups. Meter-aware via
-- beat_ticks_lookup (M.beat_ticks_lookup) rather than one fixed beat
-- length, so a mid-piece time-signature change is honored. Only groups of
-- 2+ are returned - a lone beamable note gets a flag instead, which is
-- the drawer's concern, not this module's. Each group is a list of
-- indices into render_model, in order.
--
-- A rest between two otherwise-adjacent beamable events breaks the beam,
-- even within the same nominal beat - a real, once-live bug: rests aren't
-- their own render_model entries (see M.detect_rests - they're detected
-- separately, as gaps in the timeline), so this used to compare pure
-- array-adjacency + beat index with no visibility at all into whether real
-- silence actually separated two notes, drawing one unbroken beam bar
-- straight across a rest inside a beat (e.g. a 16th/16th-rest/16th
-- syncopation) with no visual break to show the rest was ever there.
-- Detected via last_event_end, a running "end of whatever most recently
-- sounded" tracker updated for EVERY event including grace notes (below) -
-- comparing against just the last INCLUDED beamable event would instead
-- have to special-case grace notes' own tiny gap before their main note as
-- a false rest; updating it unconditionally sidesteps that entirely.
--
-- Grace notes (layout_engine.compute's is_grace flag - an ornamental note
-- far too short to be a real rhythmic value, e.g. a hammer-on/pull-off
-- captured as a near-instantaneous MIDI note) are transparent to beam
-- grouping: they never join a beam themselves (a grace note gets its own
-- individual small stem+slash - see draw_notation.lua), but they also must
-- not BREAK an otherwise-continuous run of real beamable notes around
-- them, the same way a rest should. Simply skipping them for grouping
-- purposes - neither extending `current` nor flushing it - achieves that;
-- last_event_end still advances past them (see above) so they don't get
-- mistaken for a rest gap either.
function M.group_beams(render_model, beat_ticks_lookup)
  local groups = {}
  local current, current_beat = nil, nil
  local last_event_end = nil

  local function flush()
    if current and #current >= 2 then
      table.insert(groups, current)
    end
    current, current_beat = nil, nil
  end

  for i = 1, #render_model do
    local event = render_model[i]
    local has_rest_gap = last_event_end and event.tick > last_event_end
    last_event_end = event.tick + event.duration_ticks

    if not event.is_grace then
      local is_beamable = event.notated_ticks < config.layout.ppq_per_quarter
      local beat_index = math.floor(event.tick / beat_ticks_lookup(event.tick))

      if is_beamable and current and beat_index == current_beat and not has_rest_gap then
        table.insert(current, i)
      else
        flush()
        if is_beamable then
          current = { i }
          current_beat = beat_index
        end
      end
    end
  end
  flush()

  return groups
end

local TUPLET_TICK_TOLERANCE = 15 -- ticks - looser than layout_engine's TIE_DURATION_TOLERANCE
-- (10): each shape's onsets carry their own independent recording jitter,
-- so slop compounds across multiple inter-onset gaps instead of just 1.

-- Candidate shapes M.detect_tuplets recognizes. count = actual note onsets
-- per instance (the printed numerator). ratio_den = how many plain notes
-- of the resulting notated value would normally fill the same span (the
-- printed denominator) - nominal_ticks for one member is always
-- span / ratio_den. beats = how many beat_ticks-lengths the whole group
-- spans (1 = within one beat, 2 = a beat-pair) - a 1-beat shape's members
-- are beamable and land together in one beat, so draw_notation.lua's own
-- beam-grouping check finds them all sharing one beam and draws a bare
-- numeral, no bracket; a 2-beat shape's members either aren't beamable at
-- all (quarter-triplet) or get split across two separate per-beat beam
-- groups (nonuplet/11/13-tuplet, since beaming never spans more than one
-- beat), so those draw a bracket instead - see draw_notation.lua's own
-- Pass 2.5 comment. The standalone 1-beat sextuplet below (6:4) is a
-- DIFFERENT, faster shape than a hypothetical 2-beat pair of eighth-
-- triplet beats - Pass 1's span-window check tells them apart on timing
-- alone, since a true 1-beat sextuplet's 6 notes are packed twice as
-- tight. Deliberately excludes quintuplets (5:4) - not requested, left out
-- on purpose, not an oversight.
M.TUPLET_SHAPES = {
  { count = 3, ratio_den = 2, beats = 1 },  -- eighth-triplet
  { count = 3, ratio_den = 2, beats = 2 },  -- quarter-triplet
  { count = 6, ratio_den = 4, beats = 1 },  -- sextuplet (6 in the space of 4, ONE beat)
  { count = 7, ratio_den = 4, beats = 1 },  -- septuplet (7 in the space of 4)
  { count = 9, ratio_den = 8, beats = 2 },  -- nonuplet (9 in the space of 8)
  { count = 11, ratio_den = 8, beats = 2 },
  { count = 13, ratio_den = 8, beats = 2 },
}

-- Detects tuplets (M.TUPLET_SHAPES) from raw MIDI timing - there is no
-- explicit tuplet flag in MIDI, so this is a best-effort heuristic in the
-- same spirit as layout_engine.lua's has_clean_duration tie inference, and
-- reuses the same beat-relative machinery (beat_ticks_lookup) rather than
-- a second one.
--
-- Only the shapes listed in M.TUPLET_SHAPES are recognized. It will NOT
-- catch: swung/unevenly-spaced runs (the even-spacing check below rejects
-- them), a shape that doesn't start on a beat boundary, a shape spanning a
-- rest, nested tuplets, ratios not in M.TUPLET_SHAPES (quintuplets,
-- compound-meter duplets/quadruplets - see that table's own comment for
-- why), or a shape that happens to cross a barline (layout_engine.
-- compute's existing barline-split logic will split one of its notated
-- segments, and the rendering pass doesn't reconcile that - a rare,
-- unhandled edge case, not specially suppressed here). For any 2-beat
-- shape (quarter-triplet, nonuplet, 11/13-tuplet), the beat-
-- alignment check only confirms the group starts on *a* beat, not
-- specifically the first beat of a beat-pair (true beat-pair parity isn't
-- checked). These are accepted trade-offs, not oversights - see this
-- project's own prior framing of full tuplet detection as disproportionate
-- to its scope; this only handles the common, cleanly-quantized cases.
--
-- Each detected group is always displayed on its own - a consecutive run
-- of the same shape (e.g. several eighth-triplet beats in a row) is NOT
-- merged into one shared bracket spanning multiple beats; each instance
-- gets its own numeral/bracket. This deliberately matches standard
-- engraving practice more closely than a merged bracket would: a 1-beat
-- shape's members share one beam already (see M.TUPLET_SHAPES' own
-- comment), so drawing needs nothing more than a bare numeral per group,
-- same as any other beamed passage; a 2-beat shape genuinely needs its own
-- bracket since its members don't share one beam, but that's true of that
-- ONE instance on its own merit, not because it was stitched to a
-- neighbor.
--
-- Returns function(tick) -> {id, index, count, ratio_num, ratio_den,
-- nominal_ticks} or nil. Unlike beat_ticks_lookup, this is a direct table
-- lookup (built once, up front) rather than a range search over a moving
-- pointer, so - unlike beat_ticks_lookup - callers do NOT need to query it
-- with monotonically increasing ticks.
function M.detect_tuplets(events, beat_ticks_lookup)
  local by_tick = {}
  local claimed = {}
  local next_id = 1

  local function event_end(event)
    local e = event.tick
    for i = 1, #event.notes do
      if event.notes[i].endppq and event.notes[i].endppq > e then e = event.notes[i].endppq end
    end
    return e
  end

  -- Pass 1: variable-window shape matching, generalizing what used to be a
  -- fixed-3-events loop into a per-shape count. Greedy left-to-right: the
  -- first shape that matches at a given starting position claims its
  -- events and the scan moves on, same non-overlapping precedent the
  -- original triplet-only version already used. Different shapes rarely
  -- risk colliding at the same start position in practice - each has a
  -- distinct count/span signature, so a partial match of a longer shape
  -- (e.g. the first 3 notes of a real septuplet) fails the shorter shape's
  -- own span-window check by a wide margin, not just outside tolerance.
  for i = 1, #events do
    if not claimed[i] then
      for _, shape in ipairs(M.TUPLET_SHAPES) do
        local n = shape.count
        if i + n - 1 <= #events then
          local blocked = false
          for k = i, i + n - 1 do
            if claimed[k] then blocked = true break end
          end

          if not blocked then
            local e0 = events[i]
            local beat_ticks = beat_ticks_lookup(e0.tick)
            local window = beat_ticks * shape.beats
            local last = events[i + n - 1]
            -- Written duration = time to the next onset (or, for the last
            -- member, its own sustain) - the same "read as" convention
            -- layout_engine.compute's own gap-capping uses, so the two
            -- passes agree on what a note's effective length means.
            local span_end = events[i + n] and events[i + n].tick or event_end(last)
            local span = span_end - e0.tick

            if math.abs(span - window) <= TUPLET_TICK_TOLERANCE
                and math.abs(e0.tick % beat_ticks) <= TUPLET_TICK_TOLERANCE then
              local slice = span / n
              local even, no_rest_gap = true, true
              for k = i, i + n - 1 do
                local expected = e0.tick + (k - i) * slice
                if math.abs(events[k].tick - expected) > TUPLET_TICK_TOLERANCE then even = false end
                if k > i and event_end(events[k - 1]) < events[k].tick - TUPLET_TICK_TOLERANCE then
                  no_rest_gap = false
                end
              end
              if event_end(last) < span_end - TUPLET_TICK_TOLERANCE then no_rest_gap = false end

              if even and no_rest_gap then
                local nominal_ticks = span / shape.ratio_den
                local id = next_id
                next_id = next_id + 1
                for k = i, i + n - 1 do
                  claimed[k] = true
                  by_tick[events[k].tick] = {
                    id = id, index = k - i + 1, count = n,
                    ratio_num = n, ratio_den = shape.ratio_den, nominal_ticks = nominal_ticks,
                  }
                end
                break -- this shape matched at i; stop trying other shapes here
              end
            end
          end
        end
      end
    end
  end

  return function(tick) return by_tick[tick] end
end

-- Barline ticks strictly between start and finish - the same rule
-- layout_engine.compute's own crossings_within uses for notes, applied here
-- to rest gaps so a rest never straddles a barline either.
local function measure_crossings(measure_ticks, start, finish)
  local out = {}
  if not measure_ticks then return out end
  for _, t in ipairs(measure_ticks) do
    if t > start and t < finish then table.insert(out, t) end
  end
  return out
end

-- The measure_ticks index (not the tick itself) of the measure containing
-- tick t - measure_ticks is ascending, so the last boundary <= t. nil if t
-- is before the very first boundary.
local function measure_index_for(measure_ticks, t)
  local idx = nil
  for i = 1, #measure_ticks do
    if measure_ticks[i] <= t then idx = i else break end
  end
  return idx
end

-- Detects gaps in render_model's timeline - a note-event ending before the
-- next one starts, or before the first note if leading_tick is given (e.g.
-- the first barline, so leading silence within the first measure shows a
-- rest too) - and decomposes each into a SEQUENCE of one or more standard-
-- duration rest symbols (see add_gap below) that together account for the
-- gap's full length, not just a single symbol that may fall short. Each
-- step of that sequence picks the largest standard duration (a plain
-- class, or that class's own dotted/1.5x equivalent - see classify below)
-- that fits the remaining, not-yet-covered part of the gap, then repeats
-- on whatever's left - e.g. 2.5 beats of silence becomes a half rest (2
-- beats) followed by an eighth rest (0.5 beats), not a single half rest
-- that silently drops the last eighth. Only stops leaving a genuine
-- remainder when what's left is smaller than the smallest recognized
-- class (a 64th note) - real MIDI timing imprecision, not an actual
-- fraction of a beat going unaccounted for.
--
-- Beat-boundary-aware spelling (beat_ticks_lookup, optional - same
-- function(tick) -> beat_ticks signature M.beat_ticks_lookup/M.group_beams
-- already use): while a rest_start isn't itself sitting on a beat boundary
-- (within REST_BEAT_ALIGN_TOLERANCE, matching this file's other
-- imprecise-real-MIDI-timing tolerances), each step is additionally capped
-- at whatever's left of the CURRENT beat, so a rest is never chosen so
-- large it would swallow a beat boundary it didn't start on - e.g. 2.5
-- beats of silence starting mid-beat-2 becomes an eighth rest (filling out
-- beat 2) followed by a half rest (beats 3-4 exactly), not a half rest
-- that happens to sum to the right total but splits at an arbitrary
-- mid-beat point instead. Once a rest_start IS beat-aligned, the cap lifts
-- entirely - a half or whole rest starting cleanly on a beat is normal,
-- expected notation even though it spans multiple beats itself. Omitting
-- beat_ticks_lookup reproduces the old beat-UNaware greedy behavior
-- exactly (still fully accounts for the gap's length, just without
-- preferring beat-aligned breaks) - every existing caller passes it, so
-- this is only a fallback for tests/future callers that don't have one.
--
-- measure_ticks (optional, same array layout_engine.compute's opts.
-- measure_ticks and M.measure_boundaries both use): when given, a gap is
-- first split at any barline it crosses - a silent stretch spanning two
-- measures produces one rest per measure, not one rest sized to whichever
-- duration class the combined (and generally non-standard) length happens
-- to fit. Any resulting sub-gap that covers a measure ENTIRELY (its own
-- silence, start to end, with no note anywhere in it) gets marked
-- whole_measure = true instead of running through the normal duration
-- classifier - standard notation practice draws a single whole rest
-- centered in an empty bar regardless of its actual time signature (a
-- silent 3/4 or 5/8 bar is still one whole rest, not a dotted-half or
-- oddly-tied rest spelling out the exact beat count) - draw_notation.lua
-- reads this flag to draw the whole-rest glyph and skip augmentation-dot
-- logic, and centers it using the returned tick (already the measure's
-- own midpoint for this case, not its start). Omitting measure_ticks
-- reproduces this function's pre-existing behavior exactly (no splitting,
-- no whole-measure shorthand) - it also disables the trailing-silence
-- check below, which needs measure_ticks' own final boundary to know
-- where to stop.
--
-- Trailing silence: the main loop below only ever looks BETWEEN two
-- consecutive render_model events, so silence after the very LAST event
-- - with nothing following it in this render_model at all - fell through
-- undetected (a real, once-live bug: a measure whose final beats were
-- silent, e.g. notes on beats 1-2 of a 4/4 bar only, rendered with no
-- rest at all for beats 3-4, since there was no "next event" to compare
-- against). Fixed by treating measure_ticks' own final boundary - each
-- caller's own closing barline, whether that's the true end of the whole
-- piece (the last system) or just this system's own closing/next-
-- system's-opening boundary (any earlier system) - as an implicit
-- trailing "next event" position, checked once after the main loop.
--
-- Fully empty render_model: a stretch with NO notes anywhere in it at all
-- (most often a whole system made entirely of empty measures) has no
-- event to anchor the leading/pairwise/trailing checks against, so it
-- rendered with no rests whatsoever - handled as its own early-return case
-- using measure_ticks' full span.
-- Returns a list of {tick, duration_ticks, whole_measure}.
local REST_BEAT_ALIGN_TOLERANCE = 10 -- ticks - matches layout_engine's TIE_DURATION_TOLERANCE scale
function M.detect_rests(render_model, leading_tick, measure_ticks, beat_ticks_lookup)
  local rests = {}
  local classes = config.layout.duration_classes -- ascending by ticks

  -- Largest fitting value among BOTH the plain classes and each one's own
  -- dotted (1.5x) equivalent - e.g. a 1440-tick gap (a dotted quarter's
  -- worth of silence) now classifies as 1440 (draw_notation.lua's
  -- is_dotted_duration then recognizes it and adds the augmentation dot),
  -- not as a plain 960-tick quarter rest that silently drops the extra 480
  -- ticks. The smallest class (index 1, the 64th) has no dotted variant
  -- checked, matching M.is_dotted_duration's own recognized floor (it
  -- starts at the 32nd) - a dotted-64th isn't a value either function
  -- treats as dotted. Each class's own dotted value (1.5x) is always less
  -- than the NEXT class's plain value (2x), so checking plain-then-dotted
  -- per class while walking classes in ascending order still visits every
  -- candidate in true ascending numeric order overall - no separate sort
  -- needed for "best" to end up as the actual largest fit.
  local function classify(gap_ticks)
    local best = nil
    for i, c in ipairs(classes) do
      if c.ticks <= gap_ticks then best = c.ticks end
      if i > 1 then
        local dotted = c.ticks * 1.5
        if dotted <= gap_ticks then best = dotted end
      end
    end
    return best
  end

  local function add_gap(gap_start, gap_ticks)
    local gap_end = gap_start + gap_ticks
    local crossings = measure_crossings(measure_ticks, gap_start, gap_end)

    local seg_start = gap_start
    for c = 1, #crossings + 1 do
      local seg_end = crossings[c] or gap_end

      local mi = measure_ticks and measure_index_for(measure_ticks, seg_start)
      local measure_start = mi and measure_ticks[mi]
      local measure_end = mi and measure_ticks[mi + 1]
      local is_whole_measure = measure_start and measure_end
          and seg_start <= measure_start and seg_end >= measure_end

      if is_whole_measure then
        table.insert(rests, {
          tick = (measure_start + measure_end) / 2,
          duration_ticks = measure_end - measure_start,
          whole_measure = true,
        })
      else
        -- Greedily decompose this segment into consecutive rest symbols
        -- (largest-fits-first, repeated on whatever's left) so the whole
        -- segment is always accounted for - see this function's own
        -- header for why a single classify() call alone isn't enough.
        -- Beat-aware: while rest_start isn't itself on a beat boundary,
        -- each step is also capped at whatever's left of the current beat
        -- (measure_start as the beat grid's own anchor, falling back to
        -- tick 0 if measure_ticks wasn't given), so a rest symbol never
        -- swallows a beat boundary it didn't start on - see this
        -- function's own header for the worked example.
        local rest_start = seg_start
        local remaining = seg_end - seg_start
        local smallest = classes[1].ticks
        while remaining >= smallest do
          local cap = remaining
          if beat_ticks_lookup then
            local beat_ticks = beat_ticks_lookup(rest_start)
            if beat_ticks and beat_ticks > 0 then
              local offset = (rest_start - (measure_start or 0)) % beat_ticks
              if offset > REST_BEAT_ALIGN_TOLERANCE then
                cap = math.min(cap, beat_ticks - offset)
              end
            end
          end
          -- Falls back to the full (uncapped) remaining if the beat-boundary
          -- cap is too tight for even the smallest class to fit - still
          -- makes forward progress rather than stalling, at the cost of
          -- that one symbol not being beat-aligned.
          local duration = classify(cap) or classify(remaining)
          if not duration then break end
          table.insert(rests, { tick = rest_start, duration_ticks = duration })
          rest_start = rest_start + duration
          remaining = remaining - duration
        end
      end

      seg_start = seg_end
    end
  end

  -- A stretch with literally NO notes anywhere in it (most often a whole
  -- system entirely made of empty measures, e.g. a long silent passage
  -- that landed in its own system by the width-based bin-packing in
  -- layout_engine.wrap_into_systems) - the leading/pairwise/trailing
  -- checks below all require at least one render_model event to anchor
  -- against, so this rendered with NO rests at all otherwise, not even
  -- the whole-measure shorthand for its empty bars. measure_ticks' own
  -- full span (start of its first measure through the end of its last)
  -- covers exactly the silence that needs filling here.
  if #render_model == 0 then
    if measure_ticks and #measure_ticks > 1 then
      add_gap(measure_ticks[1], measure_ticks[#measure_ticks] - measure_ticks[1])
    end
    return rests
  end

  if leading_tick and #render_model > 0 then
    local gap = render_model[1].tick - leading_tick
    if gap > 0 then add_gap(leading_tick, gap) end
  end

  -- running_latest_end is the latest endppq among EVERY note seen so far,
  -- across ALL events processed up to this point - not just the current
  -- event's own notes. Events group notes by shared ONSET tick only (see
  -- midi_read.group_into_events), so a long note on one string that isn't
  -- re-attacked doesn't reappear in any later event's own `notes` list -
  -- checking only the current event's notes here would miss it and insert
  -- a rest for a stretch where that string is actually still ringing (a
  -- real, once-live bug: e.g. a sustained whole note on one string with
  -- shorter notes attacking on another string partway through it wrongly
  -- got a rest wherever those shorter notes' own short endppq fell short
  -- of the NEXT attack, even though the long note was still sounding the
  -- entire time). Carrying the running max forward instead means a gap is
  -- only ever reported where NOTHING at all - on any string - is still
  -- sounding, which is what a rest actually means for this app's one
  -- shared tab-staff timeline.
  local running_latest_end = nil
  for i = 1, #render_model do
    local notes = render_model[i].notes
    for j = 1, #notes do
      if not running_latest_end or notes[j].endppq > running_latest_end then
        running_latest_end = notes[j].endppq
      end
    end

    if i < #render_model then
      local next_tick = render_model[i + 1].tick
      if running_latest_end and next_tick > running_latest_end then
        add_gap(running_latest_end, next_tick - running_latest_end)
      end
    end
  end

  -- Trailing silence after the LAST event, up through this caller's own
  -- final measure boundary - see this function's header. Mirrors the loop
  -- above exactly, just using measure_ticks' own last entry in place of a
  -- "next event" that doesn't exist; running_latest_end already reflects
  -- every note through the last event, long-sustained or not.
  if measure_ticks and #measure_ticks > 0 and #render_model > 0 then
    local trailing_boundary = measure_ticks[#measure_ticks]
    if running_latest_end and trailing_boundary > running_latest_end then
      add_gap(running_latest_end, trailing_boundary - running_latest_end)
    end
  end

  return rests
end

return M
