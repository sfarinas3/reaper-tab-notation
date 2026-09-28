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
local notation_model = require('notation_model') -- safe: notation_model only requires config, no cycle

local M = {}

M.PPQ_PER_QUARTER = config.layout.ppq_per_quarter
local GRACE_NOTE_TICKS = M.PPQ_PER_QUARTER / 32 -- half of a 64th note - config.layout.duration_classes' own shortest real class
local GRACE_NOTE_WIDTH = 10 -- px - a small fixed width, not duration-proportional

-- Fallback only, when the caller doesn't pass opts.measure_start_buffer -
-- see M.compute's own comment on that option for the real, CALCULATED
-- value (draw_tab.lua's M.measure_start_buffer, measured with CalcTextSize
-- against the actual active font/size) that every real caller supplies.
-- This fixed number only covers a caller with no ImGui context at all
-- (there are none today, but M.compute shouldn't hard-require one).
local MEASURE_START_BUFFER_FALLBACK = 36 -- px
local MEASURE_START_TOLERANCE = 5 -- ticks - real MIDI timing imprecision on an intended downbeat

-- Guitar technique ids for a legato (hammer-on/pull-off) tag - source of
-- truth is tab_editor.lua's own GUITAR_TECHNIQUE_LEGATO/_LEGATO_TAP (the
-- "l"/"lt" fret suffixes write these ids into midi_read.lua's technique
-- P_EXT map); duplicated here rather than required, since tab_editor.lua
-- already requires this module and Lua can't require back the other way.
-- Same duplicated-but-commented-in-sync convention note_editor.lua/draw_
-- tab.lua's own TECHNIQUE_SYMBOLS table already uses for the Shamisen ids.
-- GUITAR_TECHNIQUE_LEGATO_TAP ("lt") means legato AND tap together - a
-- note can carry both at once (unlike the rest of the technique ids, which
-- are mutually exclusive) - so the slur check below has to treat it as a
-- legato tag too, not just the plain GUITAR_TECHNIQUE_LEGATO id.
local GUITAR_TECHNIQUE_LEGATO = 101
local GUITAR_TECHNIQUE_LEGATO_TAP = 103
local function is_legato_technique(id)
  return id == GUITAR_TECHNIQUE_LEGATO or id == GUITAR_TECHNIQUE_LEGATO_TAP
end

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
-- splits it into two tied pieces.
--
-- Crossing a beat boundary alone is NOT enough, though - a real, once-live
-- bug: for any note whose own duration is a whole number of beats (a
-- quarter, a half, a dotted half, a whole note...), EVERY back-to-back
-- same-pitch repetition necessarily starts on a fresh beat, since the
-- previous one's own length already lands exactly on one. A run of three
-- separately-attacked dotted-half notes at the same pitch (each a
-- complete, legally-notatable 3-beat value on its own, needing no tie at
-- all) was getting flagged as two ties on that basis alone. The real
-- distinguishing question is whether PREV already stands as one complete,
-- nameable note value by itself (has_clean_duration, checked against
-- prev's own raw duration, plain or dotted, with a small tolerance for
-- imprecise real MIDI timing) - if it does, there's no rhythmic need to
-- tie it to anything else, regardless of where the join falls. A tie is
-- only inferred when the join ALSO crosses a beat boundary AND prev's own
-- length is NOT already clean - i.e. prev is a leftover/irregular
-- fragment that can't stand as its own symbol, the actual reason a tie
-- would ever be needed. Two independently-valid-duration notes sharing a
-- pitch within the same beat essentially never need a tie for that
-- reason either, so both conditions still have to hold. Trade-off: this
-- can miss a genuine intentional tie between two notes that both fall
-- within one beat (uncommon, but it does happen) - accepted since false
-- positives on repeated notes (fast or, as above, beat-or-longer) are the
-- more common and more disruptive case.
-- Also checked: each factor in TUPLET_SCALE_FACTORS, a tuplet-scaled
-- candidate (e.g. an eighth-triplet's raw ~320-tick duration against an
-- eighth's 480-tick base, factor 2/3) - same reasoning as the dotted
-- (x1.5) candidate above: a tuplet note is already a complete,
-- independently-nameable value the moment it's detected as one
-- (notation_model.detect_tuplets), so it shouldn't be tied just for
-- crossing a beat boundary either. Kept as a plain tick-value check here
-- rather than threading detect_tuplets' own membership info into this
-- function, so has_clean_duration stays a pure function of one duration
-- with no pass-ordering dependency - and it's strictly more robust, since
-- it still recognizes a tuplet note's completeness even in a case
-- detect_tuplets itself declined to tag (e.g. adjacent to a rest).
-- Factors are derived from notation_model.TUPLET_SHAPES (ratio_den/count),
-- deduplicated - the two triplet shapes and the sextuplet all share 2/3 -
-- so this list never silently drifts out of sync with which shapes are
-- actually detected.
local TUPLET_SCALE_FACTORS = {}
do
  local seen = {}
  for _, shape in ipairs(notation_model.TUPLET_SHAPES) do
    local factor = shape.ratio_den / shape.count
    if not seen[factor] then
      seen[factor] = true
      TUPLET_SCALE_FACTORS[#TUPLET_SCALE_FACTORS + 1] = factor
    end
  end
end

local TIE_DURATION_TOLERANCE = 10 -- ticks - forgives minor recording/quantization imprecision
local function has_clean_duration(duration_ticks)
  local quarter = M.PPQ_PER_QUARTER
  for _, base in ipairs({ quarter / 8, quarter / 4, quarter / 2, quarter, quarter * 2, quarter * 4 }) do
    if math.abs(duration_ticks - base) <= TIE_DURATION_TOLERANCE
        or math.abs(duration_ticks - base * 1.5) <= TIE_DURATION_TOLERANCE then
      return true
    end
    for _, factor in ipairs(TUPLET_SCALE_FACTORS) do
      if math.abs(duration_ticks - base * factor) <= TIE_DURATION_TOLERANCE then
        return true
      end
    end
  end
  return false
end

-- Returns a render model: list of
--   { tick, x, duration_ticks, notated_ticks, is_grace, tuplet,
--     notes = {..., tied_from_prev, tied_to_next} }
-- duration_ticks is the true gap-capped elapsed-time span (barline-split
-- math, "let ring" sustain, etc. all key off this). notated_ticks is what
-- the note should be CLASSIFIED as for rendering purposes (spacing, flags,
-- dots, beamability) - equal to duration_ticks except for a detected
-- tuplet member, where it's the plain-equivalent value the tuplet note
-- actually reads as (see opts.tuplet_lookup below). Every classification
-- call site elsewhere in the app should read notated_ticks, not
-- duration_ticks. tuplet is nil, or {id, index, count, ratio_num,
-- ratio_den, nominal_ticks} from notation_model.detect_tuplets, for
-- bracket/numeral rendering. Only x differs in meaning per staff; y is
-- each drawer's own concern.
function M.compute(events, opts)
  opts = opts or {}
  local measure_width = opts.measure_width
  local beat_ticks_lookup = opts.beat_ticks_lookup or function() return M.PPQ_PER_QUARTER end
  local tuplet_lookup = opts.tuplet_lookup
  local measure_ticks = opts.measure_ticks
  local min_gap = config.layout.min_gap
  local x = config.layout.left_margin
  -- Space reserved right after a barline, before that measure's own first
  -- event - standing, not conditional on config.show_note_names, so
  -- toggling that checkbox never shifts the layout. Exists specifically so
  -- draw_tab.lua's "Show Note Names" cheat sheet, which draws a chord's
  -- names to the LEFT of its fret numbers rather than below (see that
  -- file's header), has somewhere to put them when the chord lands right
  -- on beat 1 - the one spot a leftward label would otherwise have nothing
  -- but a barline immediately behind it. draw_tab.lua's M.measure_start_
  -- buffer calculates this from real measured text, not a guess - see
  -- that function's own header for exactly what it accounts for.
  local measure_start_buffer = opts.measure_start_buffer or MEASURE_START_BUFFER_FALLBACK

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
  -- extra_spacing_ticks (optional, default 0): added to the SPACING
  -- calculation only, never to notated_ticks itself, so it never affects
  -- this entry's own notehead/flag/dot classification - just reserves
  -- extra trailing width for silence that follows before the next real
  -- event (see this event's own trailing_rest_ticks, above).
  local function emit(tick, duration_ticks, notes, extra_spacing_ticks)
    local is_grace = duration_ticks < GRACE_NOTE_TICKS
    local tuplet = tuplet_lookup and tuplet_lookup(tick)
    local notated_ticks = (tuplet and tuplet.nominal_ticks) or duration_ticks
    local entry = { tick = tick, x = x, duration_ticks = duration_ticks, notated_ticks = notated_ticks,
      notes = notes, is_grace = is_grace, tuplet = tuplet }
    result[#result + 1] = entry
    local content_width = measure_width and measure_width(entry) or 0
    local spacing_ticks = notated_ticks + (extra_spacing_ticks or 0)
    local base_width = is_grace and GRACE_NOTE_WIDTH or width_for_duration(spacing_ticks)
    local step_width = math.max(base_width, content_width + min_gap)
    x = x + step_width
    return entry
  end

  for e = 1, #events do
    local event = events[e]

    -- Measure-start buffer (see measure_start_buffer's own comment above) -
    -- added once, right before this event's own x is used for anything,
    -- whenever this event's tick sits on (or within real-MIDI-timing
    -- tolerance of) a measure boundary, i.e. this is that measure's own
    -- first event. pending_measure_boundary_x remembers x as it was BEFORE
    -- the buffer, so the render-model entry this event turns into (below)
    -- can carry the barline's own true x separately from its own (now
    -- pushed-right) x - see that entry's own measure_boundary_x field and
    -- M.wrap_into_systems' matching comment for why they have to differ:
    -- without this, the barline's OWN x is computed (in wrap_into_systems)
    -- by interpolating measure_ticks against this same render model, which
    -- lands EXACTLY on this event's own x whenever a note starts right on
    -- the downbeat (the boundary tick and the note's tick are identical) -
    -- so the buffer above, which only pushes the NOTE right, was silently
    -- carrying the barline right along with it and never actually opening
    -- any gap between them, a real bug an earlier version of this buffer
    -- had (visually, the note's own leftward name still landed right on
    -- the barline no matter how large the buffer was).
    local pending_measure_boundary_x = nil
    if measure_ticks then
      for i = 1, #measure_ticks do
        if math.abs(measure_ticks[i] - event.tick) <= MEASURE_START_TOLERANCE then
          pending_measure_boundary_x = x
          x = x + measure_start_buffer
          break
        end
      end
    end

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
    --
    -- full_gap_ticks (the UNCAPPED gap) is kept separately - trailing_rest_
    -- ticks below is how much of that gap this note's own written value
    -- does NOT cover, i.e. how much silence (notation_model.detect_rests'
    -- own job to fill with rest symbols) follows before the next real
    -- event. That silence has no entry of its own in this render model -
    -- rests are synthesized entirely separately, purely by interpolating
    -- onto the x-positions notes establish here - so without accounting
    -- for it, a short note followed by a long rest reserved only its own
    -- short duration's worth of width, and the rest (plus, at a measure
    -- end, the barline itself) had to be interpolated into that same
    -- cramped gap: a once-reported real bug where a half rest ended up
    -- visually crushed against both the preceding note and the barline.
    -- See emit's own extra_spacing_ticks param for where this is spent.
    local full_gap_ticks = events[e + 1] and (events[e + 1].tick - event.tick) or duration_ticks
    if events[e + 1] then
      local gap = full_gap_ticks
      if gap > 0 and gap < duration_ticks then
        duration_ticks = gap
      end
    end
    local trailing_rest_ticks = math.max(0, full_gap_ticks - duration_ticks)

    local notes = {}
    for i = 1, #event.notes do
      local note = event.notes[i]
      local copy = {}
      for k, v in pairs(note) do copy[k] = v end

      local tied = false
      local legato = false
      if note.string then
        local prev = prev_by_string[note.string]
        if prev and prev.pitch == note.pitch and prev.endppq == note.startppq then
          local beat_ticks = beat_ticks_lookup(note.startppq)
          local crosses_beat = math.floor(prev.startppq / beat_ticks) ~= math.floor(note.startppq / beat_ticks)
          local prev_duration = prev.endppq - prev.startppq
          tied = crosses_beat and not has_clean_duration(prev_duration)
        end
        -- Legato (hammer-on/pull-off) slur: BOTH this note and the
        -- immediately preceding same-string note (no gap between them)
        -- must carry the legato tag - a lone "l"-tagged note with an
        -- untagged neighbor draws nothing, matching "a legato only shows
        -- across at least 2 tagged notes." Exact endppq==startppq
        -- equality, no tolerance, same precision as the tie check above.
        if prev and prev.endppq == note.startppq
            and is_legato_technique(prev.technique) and is_legato_technique(note.technique) then
          legato = true
        end
      end
      copy.tied_from_prev = tied
      copy.legato_from_prev = legato

      notes[i] = copy
    end

    for i = 1, #event.notes do
      local note = event.notes[i]
      if note.string then
        prev_by_string[note.string] = note
      end
    end

    -- Split across any barlines this notated span crosses (see this
    -- file's header), then further decompose each of those barline-bounded
    -- segments into tied-together legal note values wherever a segment's
    -- own duration doesn't correspond to a single plain/dotted value
    -- (notation_model.decompose_duration - the same beat-aware largest-
    -- fits-first algorithm notation_model.detect_rests already uses for
    -- rests, applied here so e.g. a 2.5-beat note renders as a half tied to
    -- an eighth instead of a half note that silently truncates the last
    -- eighth away with no visual trace of it). Skipped for a detected
    -- tuplet member: its raw duration_ticks is already a complete,
    -- correctly-classified value via notated_ticks' nominal-ticks
    -- substitution (see emit above and has_clean_duration's own TUPLET_
    -- SCALE_FACTORS reasoning) - running the plain/dotted classifier
    -- against a tuplet-scaled raw tick count would misclassify it.
    -- decompose_duration can return no pieces at all for a span below the
    -- smallest recognized class (a grace note, or a barline-split fragment
    -- too short to classify) - falls back to the original undecomposed
    -- span in that case. The ordinary (non-crossing, cleanly-classifiable)
    -- case is still just one piece covering the whole duration, identical
    -- to before.
    local pieces = {}
    do
      local crossings = crossings_within(event.tick, event.tick + duration_ticks)
      local seg_start = event.tick
      for c = 1, #crossings + 1 do
        local seg_end = crossings[c] or (event.tick + duration_ticks)
        local seg_len = seg_end - seg_start

        local sub_pieces = nil
        if not (tuplet_lookup and tuplet_lookup(seg_start)) then
          local mi = measure_ticks and notation_model.measure_index_for(measure_ticks, seg_start)
          local measure_start = mi and measure_ticks[mi]
          sub_pieces = notation_model.decompose_duration(seg_start, seg_len, measure_start, beat_ticks_lookup)
        end
        if not sub_pieces or #sub_pieces == 0 then
          sub_pieces = { { tick = seg_start, duration_ticks = seg_len } }
        end
        for _, p in ipairs(sub_pieces) do
          pieces[#pieces + 1] = p
        end

        seg_start = seg_end
      end
    end

    local seg_notes = notes
    for c = 1, #pieces do
      local piece = pieces[c]
      local is_last = c == #pieces

      if not is_last then
        for i = 1, #seg_notes do seg_notes[i].tied_to_next = true end
      end

      local entry = emit(piece.tick, piece.duration_ticks, seg_notes, is_last and trailing_rest_ticks or nil)
      if c == 1 and pending_measure_boundary_x then
        entry.measure_boundary_x = pending_measure_boundary_x
      end

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
  local rate = width_for_duration(last.notated_ticks) / math.max(last.duration_ticks, 1)
  return last.x + (tick - last.tick) * rate
end

-- Pixel x for a tick, interpolated between two parallel ascending arrays
-- (ticks, xs) rather than render_model's own note positions - for a
-- system with NO notes at all (an empty-render_model stretch, e.g. a long
-- silent passage that landed in its own system), M.x_for_tick has nothing
-- to interpolate from and collapses every tick to the same fallback x, so
-- notation_model.detect_rests' whole-measure rests for that system would
-- all stack on top of one another instead of getting their own distinct
-- position. A system's own `ticks`/`barline_x` (this function's intended
-- inputs - see M.wrap_into_systems' return shape) already carry a correct
-- position for every measure boundary regardless of whether that system
-- has any notes, since they're computed from the FULL, unsliced
-- render_model before wrapping. Assumes tick falls within
-- [ticks[1], ticks[#ticks]] - true by construction for any rest tick
-- detect_rests can produce from a given system's own measure_ticks, so no
-- extrapolation-beyond-the-ends case is needed here.
function M.x_for_tick_from_boundaries(ticks, xs, tick)
  local n = #ticks
  if n == 0 then return config.layout.left_margin end
  if n == 1 or tick <= ticks[1] then return xs[1] end

  for i = 1, n - 1 do
    if tick >= ticks[i] and tick <= ticks[i + 1] then
      if ticks[i + 1] == ticks[i] then return xs[i] end
      local t = (tick - ticks[i]) / (ticks[i + 1] - ticks[i])
      return xs[i] + t * (xs[i + 1] - xs[i])
    end
  end

  return xs[n]
end

-- x for an arbitrary tick within one wrap_into_systems system - the usual
-- forward M.x_for_tick against that system's own events, falling back to
-- M.x_for_tick_from_boundaries for a system with zero rendered events (an
-- all-rest system, which has no events array to interpolate against but
-- still has its own ticks/barline_x pair). Shared by every caller that
-- needs a screen x for a tick that isn't necessarily a real note's own
-- onset (tab_editor.lua's click-locating, grid_overlay.lua's gridlines).
function M.x_for_tick_in_system(system, tick)
  if #system.events > 0 then
    return M.x_for_tick(system.events, tick)
  end
  return M.x_for_tick_from_boundaries(system.ticks, system.barline_x, tick)
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
  if #render_model == 0 then
    -- A genuinely empty take (no notes at all) still has real measure_ticks
    -- - notation_model.measure_boundaries walks REAPER's own project
    -- measure grid regardless of whether there are any notes, so an empty
    -- take still gets at least one real measure's worth of boundaries.
    -- Returning nothing here used to mean an empty take had no system at
    -- all to render - blocking tab_editor.lua's Edit Mode from having
    -- anywhere to click to create the very FIRST note. Space each measure
    -- at a fixed default width (the widest duration-class entry - a whole
    -- note's width) since there's no real note content here to size
    -- against, same shape contract as every other system (draw_tab.lua/
    -- draw_notation.lua/tab_editor.lua already have to tolerate a
    -- zero-event system for an ordinary silent passage mid-piece, via
    -- M.x_for_tick_from_boundaries above - this is that same case, just
    -- spanning the whole take instead of one stretch of it).
    if measure_ticks and #measure_ticks >= 2 then
      local default_measure_width = config.layout.duration_classes[#config.layout.duration_classes].width
      local x = config.layout.left_margin
      local ticks, barline_x = {}, {}
      for i = 1, #measure_ticks do
        table.insert(ticks, measure_ticks[i])
        table.insert(barline_x, x)
        if i < #measure_ticks then x = x + default_measure_width end
      end
      return {
        {
          events = {}, ticks = ticks, barline_x = barline_x,
          item_measure_start = 1,
          tick_lo = measure_ticks[1], tick_hi = measure_ticks[#measure_ticks],
        },
      }
    end
    return {}
  end

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

  -- tick -> measure_boundary_x override (see M.compute's own pending_
  -- measure_boundary_x comment for why this has to differ from the plain
  -- tick-interpolated position): whenever a note starts right on a
  -- downbeat, its own tick exactly equals that measure's boundary tick, so
  -- M.x_for_tick would otherwise place the barline at that SAME (buffer-
  -- pushed) x, closing the gap the buffer was supposed to open. At most
  -- one entry per tick in practice (only a measure's own first event ever
  -- sets this).
  local measure_boundary_x_override = {}
  for i = 1, #render_model do
    if render_model[i].measure_boundary_x then
      measure_boundary_x_override[render_model[i].tick] = render_model[i].measure_boundary_x
    end
  end

  local boundary_x = {}
  for i = 1, #measure_ticks do
    boundary_x[i] = measure_boundary_x_override[measure_ticks[i]] or M.x_for_tick(render_model, measure_ticks[i])
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
