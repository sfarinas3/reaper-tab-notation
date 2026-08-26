-- Shared tick-to-pixel spacing backbone. Computed once, consumed by every
-- staff drawer (draw_tab.lua, draw_notation.lua) - never duplicated, or
-- the staves would visibly drift apart horizontally.
--
-- Domain is PPQ (REAPER's native MIDI ticks), not seconds, so layout stays
-- tempo-independent.
--
-- Single accumulating pass: each event consumes
-- max(duration-class width, measured content width + min_gap) of horizontal
-- space before the next event starts. This folds the plan's "ideal
-- position by duration" and "minimum-gap collision correction" into one
-- step instead of two separate passes - in a strictly left-to-right
-- sequential layout (no overlapping/backward placement), a single forward
-- accumulator already guarantees both properties with less code, since
-- there's nothing for a later collision-correction sweep to still need to
-- cascade.
--
-- (A linear, time-proportional spacing mode was tried and reverted - it
-- gave the playhead perfectly constant-speed motion between notes, but
-- the tradeoff wasn't worth it: whole/half notes stretched very wide
-- relative to short notes. Duration-class spacing means the playhead's
-- speed visibly changes at each note boundary, but it still arrives at
-- the correct x at the correct time throughout.)
--
-- M.compute() always lays out one unbroken line, regardless of any
-- available width - M.wrap_into_systems() is the separate post-processing
-- step (Phase 5) that re-chunks that single line into multiple systems
-- fitting a given width, breaking only at measure boundaries. Keeping
-- these as two steps (rather than threading a width constraint into
-- compute() itself) means compute()'s per-event spacing math never has to
-- know about wrapping at all, and wrapping can re-bin-pack purely from
-- already-computed x positions - cheap enough to redo every frame against
-- the current panel width with no separate cache-invalidation logic for
-- resize.
--
-- Each event's duration_ticks (used for spacing, beam grouping, and
-- flag/dash counts everywhere downstream) is capped at the gap to the
-- NEXT event's own onset, not just each note's raw MIDI length. A guitar
-- note routinely rings past where the next note starts (an open chord
-- left ringing under a moving line, fingerstyle, pedal tones -
-- draw_notation.lua/draw_tab.lua's "let ring" dashed line shows that
-- extra sustain separately, from each note's own uncapped endppq); left
-- uncapped here, that longer raw sustain would get the note classified,
-- beamed, and spaced as a longer rhythmic value than it's actually
-- written as (a sixteenth ringing over the next sixteenth showing up as
-- an eighth). Standard rhythm-transcription practice is that a note's
-- written value reflects time-until-next-onset, not its own release; this
-- cap is a no-op for the ordinary non-overlapping case.
--
-- Barline-crossing (opts.measure_ticks): standard engraving practice is
-- that a note is NEVER drawn crossing a barline as a single symbol -
-- crossing one always requires splitting into tied notes, one ending
-- exactly at the barline and the next starting exactly there, same as how
-- a duration crossing a beat boundary already requires a tie (the
-- pre-existing same-string tie inference below, for two genuinely
-- separate MIDI events). This does the equivalent split for a SINGLE
-- event's notated span, whenever it alone would otherwise cross one or
-- more barlines with nothing else re-attacking in between (a long held
-- note/chord) - without it, such a note either gets misclassified as
-- whatever duration class its raw span happens to fall into (e.g. a note
-- starting on beat 2 showing as a whole note, which isn't a valid reading
-- - a whole note by definition starts on beat 1) or simply has no visual
-- representation at all past the barline it crosses. Emits one render-
-- model entry per measure segment the span touches, each tied to the
-- next (note.tied_to_next) in addition to the existing tied_from_prev on
-- every segment after the first - both flags matter downstream:
-- tied_to_next tells the "let ring" feature above not to also draw its
-- own dashed line between two segments of the SAME split note (the tie
-- curve already shows the continuation); tied_from_prev is what the
-- existing tie-drawing/tie-direction-inheritance logic already consumes.
-- Sub-measure splitting (a duration that doesn't cross a barline but
-- still obscures the beat structure within one measure) is a separate,
-- narrower engraving nicety this doesn't attempt - see this file's
-- existing tie-inference comment for why exact beat-perfect splitting
-- everywhere is out of scope.
--
-- Grace notes: an event whose notated duration (post gap-cap, i.e. the
-- actual time until the next onset - not necessarily its raw MIDI length)
-- is shorter than GRACE_NOTE_TICKS is far too brief to be a real rhythmic
-- value - almost always an ornamental hammer-on/pull-off/slide captured as
-- a near-simultaneous MIDI note immediately ahead of the note it
-- decorates, not an intentional 128th-or-shorter note. Flagged is_grace on
-- the render-model entry and given a small fixed width (GRACE_NOTE_WIDTH)
-- instead of the normal duration-class width, so it renders "crushed"
-- immediately before its main note rather than claiming its own
-- proportional slice of the beat - draw_notation.lua draws it as a small
-- slashed-stem notehead with no augmentation dot or hollow-notehead
-- treatment, and notation_model.group_beams treats it as transparent to
-- beam grouping (neither beamed itself nor breaking a real beam group
-- around it). The gap-cap already makes this check equivalent to "is this
-- event's time-to-next-onset itself tiny" for the common case (a grace
-- note immediately followed by its main note); a genuinely short LAST
-- note of a phrase with nothing after it to cap against is judged on its
-- own raw duration, the same rule.

local config = require('config')

local M = {}

M.PPQ_PER_QUARTER = config.layout.ppq_per_quarter
local GRACE_NOTE_TICKS = M.PPQ_PER_QUARTER / 32 -- half of a 64th note - config.layout.duration_classes' own shortest real class
local GRACE_NOTE_WIDTH = 10 -- px - a small fixed width, not duration-proportional

-- Interpolates a pixel width for duration_ticks from config.layout's
-- duration-class table, in log-tick space so the curve is smooth rather
-- than jumping at class boundaries. Clamps at the table's extremes.
local function width_for_duration(duration_ticks)
  local classes = config.layout.duration_classes

  if duration_ticks <= classes[1].ticks then
    return classes[1].width
  end

  local last = classes[#classes]
  if duration_ticks >= last.ticks then
    return last.width
  end

  for i = 1, #classes - 1 do
    local a, b = classes[i], classes[i + 1]
    if duration_ticks >= a.ticks and duration_ticks <= b.ticks then
      local log_a, log_b, log_d = math.log(a.ticks), math.log(b.ticks), math.log(duration_ticks)
      local t = (log_d - log_a) / (log_b - log_a)
      return a.width + t * (b.width - a.width)
    end
  end

  return last.width -- unreachable given the clamps above; defensive fallback
end

-- events: list of {tick, notes = {...with .string/.fret from fret_heuristic}}
-- opts.measure_width: optional function(render_model_event) -> pixels,
--   letting a drawer report how much room its own content actually needs
--   (e.g. a two-digit fret number) beyond the duration-class default.
-- opts.beat_ticks_lookup: function(tick) -> beat_ticks, from
--   notation_model.beat_ticks_lookup - required for tie inference to be
--   meter-aware (see below); falls back to treating every quarter note as
--   one beat if omitted.
--
-- Tie inference: standard MIDI has no explicit tie marker at all, so a
-- genuine tie and a fast, separately-attacked repeat of the same pitch
-- with zero gap between them are literally indistinguishable from the
-- note data alone - both look like "same pitch, prev.endppq ==
-- this.startppq". Naively treating every such pair as a tie produces
-- false positives on fast repeated-note passages (tremolo picking, gallop
-- rhythms), which is exactly what a genuine tie almost never needs: a
-- tie exists specifically because a sustained duration can't be written
-- as one symbol when it crosses a beat boundary - that's *why* notation
-- splits it into two tied pieces. Two independently-valid-duration notes
-- sharing a pitch within the same beat essentially never need a tie for
-- that reason, so the heuristic here only infers one when the join point
-- actually crosses a beat boundary. Trade-off: this can miss a genuine
-- intentional tie between two notes that both fall within one beat
-- (uncommon, but it does happen) - accepted since false positives on
-- repeated fast notes are the more common and more disruptive case.
--
-- Returns a render model: list of
--   { tick, x, duration_ticks, is_grace, notes = {..., tied_from_prev, tied_to_next} }
-- Only x differs in meaning per staff; y is each drawer's own concern.
function M.compute(events, opts)
  opts = opts or {}
  local measure_width = opts.measure_width
  local beat_ticks_lookup = opts.beat_ticks_lookup or function() return M.PPQ_PER_QUARTER end
  local measure_ticks = opts.measure_ticks
  local min_gap = config.layout.min_gap
  local x = config.layout.left_margin

  local result = {}
  local prev_by_string = {} -- string index -> last note seen on that string, for tie detection

  -- Barline ticks strictly between tick_start and tick_end, in order - the
  -- boundaries a notated span running from tick_start through tick_end
  -- would cross. Excludes tick_start itself even if it happens to land
  -- exactly on a barline (starting AT a barline isn't "crossing" it).
  local function crossings_within(tick_start, tick_end)
    local out = {}
    if not measure_ticks then return out end
    for i = 1, #measure_ticks do
      local b = measure_ticks[i]
      if b > tick_start and b < tick_end then
        out[#out + 1] = b
      end
    end
    return out
  end

  -- Appends one render-model entry (advancing x by its own duration-class
  -- width, or GRACE_NOTE_WIDTH for a grace note - see this file's header)
  -- and returns it, so the caller can chain barline-split segments.
  local function emit(tick, duration_ticks, notes)
    local is_grace = duration_ticks < GRACE_NOTE_TICKS
    local entry = { tick = tick, x = x, duration_ticks = duration_ticks, notes = notes, is_grace = is_grace }
    result[#result + 1] = entry
    local content_width = measure_width and measure_width(entry) or 0
    local base_width = is_grace and GRACE_NOTE_WIDTH or width_for_duration(duration_ticks)
    local step_width = math.max(base_width, content_width + min_gap)
    x = x + step_width
    return entry
  end

  for e = 1, #events do
    local event = events[e]

    local duration_ticks = nil
    for i = 1, #event.notes do
      local d = event.notes[i].endppq - event.notes[i].startppq
      if not duration_ticks or d < duration_ticks then duration_ticks = d end
    end
    duration_ticks = duration_ticks or M.PPQ_PER_QUARTER

    -- Cap the NOTATED duration at the gap to the next event's own onset.
    -- A note whose actual MIDI sustain rings past where the next note
    -- starts (draw_notation.lua/draw_tab.lua's "let ring" dashed line
    -- shows that extra sustain separately) shouldn't be classified,
    -- beamed, or spaced as a longer rhythmic value just because it was
    -- physically held longer - standard rhythm-transcription practice is
    -- that a note's written value reflects the time until the next onset,
    -- not its own release. A no-op for the ordinary (non-overlapping)
    -- case, where the raw duration is already <= this gap.
    if events[e + 1] then
      local gap = events[e + 1].tick - event.tick
      if gap > 0 and gap < duration_ticks then
        duration_ticks = gap
      end
    end

    local notes = {}
    for i = 1, #event.notes do
      local note = event.notes[i]
      local copy = {}
      for k, v in pairs(note) do copy[k] = v end

      local tied = false
      if note.string then
        local prev = prev_by_string[note.string]
        if prev and prev.pitch == note.pitch and prev.endppq == note.startppq then
          local beat_ticks = beat_ticks_lookup(note.startppq)
          local crosses_beat = math.floor(prev.startppq / beat_ticks) ~= math.floor(note.startppq / beat_ticks)
          tied = crosses_beat
        end
      end
      copy.tied_from_prev = tied

      notes[i] = copy
    end

    for i = 1, #event.notes do
      local note = event.notes[i]
      if note.string then
        prev_by_string[note.string] = note
      end
    end

    -- Split across any barlines this notated span crosses (see this
    -- file's header) - the ordinary, non-crossing case is just one
    -- segment covering the whole duration, identical to before.
    local crossings = crossings_within(event.tick, event.tick + duration_ticks)
    local seg_start = event.tick
    local seg_notes = notes
    for c = 1, #crossings + 1 do
      local seg_end = crossings[c] or (event.tick + duration_ticks)
      local is_last = c > #crossings

      if not is_last then
        for i = 1, #seg_notes do seg_notes[i].tied_to_next = true end
      end

      emit(seg_start, seg_end - seg_start, seg_notes)

      if not is_last then
        local next_notes = {}
        for i = 1, #seg_notes do
          local copy = {}
          for k, v in pairs(seg_notes[i]) do copy[k] = v end
          copy.tied_from_prev = true
          copy.tied_to_next = false
          next_notes[i] = copy
        end
        seg_notes = next_notes
        seg_start = seg_end
      end
    end
  end

  return result
end

-- Pixel x for an arbitrary tick, not just one that happens to coincide
-- with an event - needed for barlines, which usually fall between notes
-- rather than on one. Linearly interpolates between the two events
-- bracketing tick; extrapolates using the nearest step's local rate
-- before the first event or after the last one.
function M.x_for_tick(render_model, tick)
  local n = #render_model
  if n == 0 then return config.layout.left_margin end

  if tick <= render_model[1].tick then
    return render_model[1].x
  end

  for i = 1, n - 1 do
    local a, b = render_model[i], render_model[i + 1]
    if tick >= a.tick and tick <= b.tick then
      if b.tick == a.tick then return a.x end
      local t = (tick - a.tick) / (b.tick - a.tick)
      return a.x + t * (b.x - a.x)
    end
  end

  -- Beyond the last event: extrapolate using the rate implied by its own
  -- duration-class width (the same width step.compute used to place it).
  local last = render_model[n]
  local rate = width_for_duration(last.duration_ticks) / math.max(last.duration_ticks, 1)
  return last.x + (tick - last.tick) * rate
end

-- Re-chunks render_model (M.compute()'s single-line output) into
-- multiple systems (wrapped lines), each fitting within max_width,
-- breaking only at measure boundaries per measure_ticks
-- (notation_model.measure_boundaries's output) - a measure that alone
-- exceeds max_width is still placed as a lone system rather than split,
-- since breaking mid-measure isn't an option.
--
-- Returns a list of systems, each:
--   { events = {...}, ticks = {...}, barline_x = {...}, tick_lo, tick_hi }
-- - events: this system's slice of render_model, with .x now relative to
--   the system's own start (not the original single-line layout) -
--   otherwise identical in shape, so draw_tab.lua/draw_notation.lua need
--   no changes to consume one system at a time.
-- - ticks: the absolute (unchanged) measure-boundary ticks belonging to
--   this system, for the same measure-crossing bookkeeping
--   draw_notation.lua already does (accidental suppression, leading rests).
-- - barline_x: those same boundaries' already-computed LOCAL pixel
--   positions, ready to draw directly - includes this system's own
--   closing barline (shared with the next system's opening one).
-- - tick_lo/tick_hi: this system's tick range, so a caller (e.g. the
--   playhead) can tell which system a given tick falls into.
function M.wrap_into_systems(render_model, measure_ticks, max_width)
  if #render_model == 0 then return {} end

  if not measure_ticks or #measure_ticks < 2 then
    return {
      {
        events = render_model,
        ticks = measure_ticks or {},
        barline_x = {},
        item_measure_start = 1,
        tick_lo = render_model[1].tick,
        tick_hi = math.huge,
      },
    }
  end

  local boundary_x = {}
  for i = 1, #measure_ticks do
    boundary_x[i] = M.x_for_tick(render_model, measure_ticks[i])
  end

  local n_measures = #measure_ticks - 1

  -- Bin-pack measures into systems greedily. system_start_boundary[s] is
  -- the boundary index (into measure_ticks) where system s (1-indexed)
  -- begins; the last entry is a sentinel one past the final measure.
  local system_start_boundary = { 1 }
  local system_start_x = { boundary_x[1] }

  for m = 1, n_measures do
    local cur_start_boundary = system_start_boundary[#system_start_boundary]
    local width_if_included = boundary_x[m + 1] - system_start_x[#system_start_x]
    if width_if_included > max_width and m > cur_start_boundary then
      table.insert(system_start_boundary, m)
      table.insert(system_start_x, boundary_x[m])
    end
  end
  table.insert(system_start_boundary, n_measures + 1)

  -- system_start_x itself stays as the true (unshifted) barline x - the
  -- bin-packing width checks above need that. Final positions instead
  -- subtract render_offset (system_start_x shifted left by left_margin):
  -- system 1's first boundary sits at exactly left_margin (M.compute's
  -- own starting x), so subtracting system_start_x directly would put
  -- its first note at local x == 0, silently erasing the margin every
  -- system is supposed to keep before its first note - which is what
  -- was happening before this offset existed.
  local n_systems = #system_start_boundary - 1
  local render_offset = {}
  for s = 1, n_systems do
    render_offset[s] = system_start_x[s] - config.layout.left_margin
  end

  local systems = {}
  for s = 1, n_systems do
    local lo, hi = system_start_boundary[s], system_start_boundary[s + 1]
    local ticks, barline_x = {}, {}
    for b = lo, hi do
      table.insert(ticks, measure_ticks[b])
      table.insert(barline_x, boundary_x[b] - render_offset[s])
    end
    systems[s] = {
      events = {}, ticks = ticks, barline_x = barline_x,
      item_measure_start = lo, -- item-relative number (1-based) of this system's first measure
      tick_lo = measure_ticks[lo], tick_hi = measure_ticks[hi],
    }
  end

  local sys_ptr = 1
  for i = 1, #render_model do
    local event = render_model[i]
    while sys_ptr < n_systems and event.tick >= systems[sys_ptr].tick_hi do
      sys_ptr = sys_ptr + 1
    end

    local copy = {}
    for k, v in pairs(event) do copy[k] = v end
    copy.x = event.x - render_offset[sys_ptr]
    table.insert(systems[sys_ptr].events, copy)
  end

  return systems
end

return M
