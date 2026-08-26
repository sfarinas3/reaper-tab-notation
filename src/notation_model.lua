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
      local is_beamable = event.duration_ticks < config.layout.ppq_per_quarter
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
-- rest too) - and classifies each into the largest standard duration that
-- fits within it. A greedy, single-symbol classification: an irregular
-- gap that doesn't cleanly match one duration class will under-represent
-- its true length rather than being decomposed into multiple rest
-- symbols (e.g. a dotted rest, or a tied pair) - an accepted
-- simplification at this scope.
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
-- Returns a list of {tick, duration_ticks, whole_measure}.
function M.detect_rests(render_model, leading_tick, measure_ticks)
  local rests = {}
  local classes = config.layout.duration_classes -- ascending by ticks

  local function classify(gap_ticks)
    local best = nil
    for _, c in ipairs(classes) do
      if c.ticks <= gap_ticks then best = c.ticks end
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
        local duration = classify(seg_end - seg_start)
        if duration then
          table.insert(rests, { tick = seg_start, duration_ticks = duration })
        end
      end

      seg_start = seg_end
    end
  end

  if leading_tick and #render_model > 0 then
    local gap = render_model[1].tick - leading_tick
    if gap > 0 then add_gap(leading_tick, gap) end
  end

  for i = 1, #render_model - 1 do
    local notes = render_model[i].notes
    local latest_end = nil
    for j = 1, #notes do
      if not latest_end or notes[j].endppq > latest_end then latest_end = notes[j].endppq end
    end
    local next_tick = render_model[i + 1].tick
    if latest_end and next_tick > latest_end then
      add_gap(latest_end, next_tick - latest_end)
    end
  end

  -- Trailing silence after the LAST event, up through this caller's own
  -- final measure boundary - see this function's header. Mirrors the
  -- pairwise loop above exactly, just using measure_ticks' own last entry
  -- in place of a "next event" that doesn't exist.
  if measure_ticks and #measure_ticks > 0 and #render_model > 0 then
    local last_notes = render_model[#render_model].notes
    local latest_end = nil
    for j = 1, #last_notes do
      if not latest_end or last_notes[j].endppq > latest_end then latest_end = last_notes[j].endppq end
    end
    local trailing_boundary = measure_ticks[#measure_ticks]
    if latest_end and trailing_boundary > latest_end then
      add_gap(latest_end, trailing_boundary - latest_end)
    end
  end

  return rests
end

return M
