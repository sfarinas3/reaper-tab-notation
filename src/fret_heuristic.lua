-- Real fret-assignment heuristic: shortest-path (Viterbi-style) DP over
-- chord-events, minimizing a hand-position/playability cost instead of
-- maximizing a probability. Replaces the Phase 1 greedy picker.
--
-- A "state" for an event is one candidate assignment of {string, fret} to
-- every note in that event (nil-safe via `false` placeholders - see below).
-- Cost is intrinsic (is this chord shape playable on its own) plus
-- transition (how far did the hand have to move from the previous event).
--
-- MIDI channel doubles as a manual override: channel 0 = auto (full
-- candidate set), channel 1..string_count = pin that note to that string.
-- A pin that can't reach the note's pitch falls back to auto rather than
-- silently dropping the note.

local config = require('config')

local M = {}

-- ---------------------------------------------------------------------
-- Candidate generation
-- ---------------------------------------------------------------------

-- Every (string, fret) pair that can produce `pitch` under the current
-- tuning/capo/max_fret.
local function all_candidates_for_pitch(pitch)
  local tuning = config.tuning
  local candidates = {}
  for string_idx = 1, #tuning do
    local fret = pitch - (tuning[string_idx] + config.capo)
    if fret >= 0 and fret <= config.max_fret then
      candidates[#candidates + 1] = { string = string_idx, fret = fret }
    end
  end
  return candidates
end

-- Candidates for one note, honoring a channel-based string pin if present
-- and reachable; falls back to the full candidate set otherwise.
local function candidates_for_note(note)
  local n_strings = #config.tuning
  if note.chan and note.chan >= 1 and note.chan <= n_strings then
    local fret = note.pitch - (config.tuning[note.chan] + config.capo)
    if fret >= 0 and fret <= config.max_fret then
      return { { string = note.chan, fret = fret } }
    end
    -- pin unreachable at this pitch (e.g. tuning changed since it was set) -
    -- fall through to auto so the note doesn't just vanish.
  end
  return all_candidates_for_pitch(note.pitch)
end

-- Shamisen-only hard constraint: within one chord event, EVERY note - open
-- or fretted, mixed or not - has to sit on a contiguous run of strings,
-- with no completely silent string skipped in between (e.g. strings 1 and
-- 3 sounding, string 2 not played at all, is never valid, regardless of
-- whether 1/3 are open or fretted). A real shamisen player can't isolate
-- two non-adjacent strings while leaving the one between them completely
-- untouched, whether that's the fretting hand pinning two strings or the
-- bachi striking two strings in one pass - an open note played higher up
-- next to a fretted one is fine (fret height doesn't matter here), but
-- the strings involved still have to be adjacent.
--
-- Guitar has no such constraint - checked by the only caller,
-- generate_event_states, which skips this filter entirely outside
-- config.instrument == "Shamisen".
local function shamisen_chord_ok(state)
  local used, strings = {}, {}
  for i = 1, #state do
    local assign = state[i]
    if assign then
      used[assign.string] = true
      strings[#strings + 1] = assign.string
    end
  end
  if #strings < 2 then return true end

  local min_s, max_s = strings[1], strings[1]
  for i = 2, #strings do
    if strings[i] < min_s then min_s = strings[i] end
    if strings[i] > max_s then max_s = strings[i] end
  end
  for s = min_s + 1, max_s - 1 do
    if not used[s] then return false end
  end
  return true
end

-- All valid joint states for one chord-event: the cartesian product of each
-- note's candidates, filtered to combinations that don't reuse a string.
-- Each state is an array of length #event.notes; an entry is `false` (not
-- nil, to keep the array hole-free) when that note is unreachable under the
-- current tuning/capo/max_fret.
local function generate_event_states(event)
  local n = #event.notes
  local per_note_candidates = {}
  for i = 1, n do
    per_note_candidates[i] = candidates_for_note(event.notes[i])
  end

  local states = { {} }
  for i = 1, n do
    local candidates = per_note_candidates[i]
    local new_states = {}
    if #candidates == 0 then
      for _, partial in ipairs(states) do
        local copy = {}
        for j = 1, i - 1 do copy[j] = partial[j] end
        copy[i] = false
        new_states[#new_states + 1] = copy
      end
    else
      for _, partial in ipairs(states) do
        for _, cand in ipairs(candidates) do
          local string_used = false
          for j = 1, i - 1 do
            if partial[j] and partial[j].string == cand.string then
              string_used = true
              break
            end
          end
          if not string_used then
            local copy = {}
            for j = 1, i - 1 do copy[j] = partial[j] end
            copy[i] = cand
            new_states[#new_states + 1] = copy
          end
        end
      end
    end
    states = new_states
  end

  if config.instrument == "Shamisen" then
    local filtered = {}
    for _, s in ipairs(states) do
      if shamisen_chord_ok(s) then filtered[#filtered + 1] = s end
    end
    states = filtered
  end

  -- Every note in the chord conflicted on every string it could reach (rare,
  -- only possible with a small string count or a dense chord), OR (Shamisen
  -- only) every surviving combination violated shamisen_chord_ok above -
  -- fall back to "everything unreachable" so the event still produces one
  -- state instead of stalling the DP with zero candidates.
  if #states == 0 then
    local empty = {}
    for i = 1, n do empty[i] = false end
    states = { empty }
  end

  return states
end

-- ---------------------------------------------------------------------
-- Cost functions
-- ---------------------------------------------------------------------

-- Approximate fretting-hand position: average fret among non-open notes in
-- the state (an open string doesn't constrain hand position, so it's
-- excluded the same way a chord mixing open and fretted notes always has
-- been - the fretted notes alone anchor the hand). The one case that
-- changes: if EVERY reachable note in the state is open (an all-open-
-- string palm-muted chug, the djent-chugging-into-a-lead-leap case this
-- was added for), there are no fretted notes to average - rather than
-- returning nil (which used to make transition_cost skip the position
-- term entirely, leaving the DP with no memory of where the hand was
-- right when a wide leap out of a chug is most likely), treat that as
-- position 0: hand resting near the nut, which is where it actually is
-- during open-string chugging. nil is reserved for "nothing in this
-- state is reachable at all" (no position exists to anchor anything).
local function hand_position(state)
  local sum, n = 0, 0
  local any_reachable = false
  for i = 1, #state do
    local assign = state[i]
    if assign then
      any_reachable = true
      if assign.fret > 0 then
        sum = sum + assign.fret
        n = n + 1
      end
    end
  end
  if n > 0 then return sum / n end
  if any_reachable then return 0 end
  return nil
end

local function avg_string(state)
  local sum, n = 0, 0
  for i = 1, #state do
    local assign = state[i]
    if assign then
      sum = sum + assign.string
      n = n + 1
    end
  end
  if n == 0 then return nil end
  return sum / n
end

-- Cost of a chord shape on its own: open-string bonus, mild low-fret
-- preference, and a penalty for stretches wider than a comfortable hand
-- span. Not a full physical-fingering solver - a playability filter.
local function intrinsic_cost(state)
  local w = config.weights
  local cost = 0
  local min_fret, max_fret = nil, nil

  for i = 1, #state do
    local assign = state[i]
    if assign then
      if assign.fret == 0 then
        cost = cost - w.open_string_bonus
      else
        cost = cost + assign.fret * w.fret_height_penalty
      end
      if not min_fret or assign.fret < min_fret then min_fret = assign.fret end
      if not max_fret or assign.fret > max_fret then max_fret = assign.fret end
    end
  end

  if min_fret and max_fret then
    local span = max_fret - min_fret
    if span > w.max_comfortable_stretch then
      cost = cost + (span - w.max_comfortable_stretch) * w.stretch_penalty
    end
  end

  return cost
end

-- The pitch a candidate assignment actually produces - reconstructed from
-- string/fret rather than carried on the state itself (states only ever
-- store {string, fret}, never pitch - see generate_event_states).
local function assignment_pitch(assign)
  return config.tuning[assign.string] + config.capo + assign.fret
end

-- Wide-pitch-leap handling - see config.lua's own comment on the
-- wide_leap_* weights for the three rules this implements and why. Gated
-- on config.wide_leap_enabled (see that field's own header) - falls
-- through to 0 (no leap handling at all) when off, which is what actually
-- restores the original minimum-hand-movement cost structure; the weights
-- themselves stay in config.lua either way, just unused while off.
-- Scoped to single-note states only (a chord isn't a "leap" in this
-- sense) - a chord transition falls through to 0 (unaffected).
local function wide_leap_cost(prev_state, state)
  if not config.wide_leap_enabled then return 0 end
  if #prev_state ~= 1 or #state ~= 1 then return 0 end
  local prev, cur = prev_state[1], state[1]
  if not prev or not cur then return 0 end
  if prev.string == cur.string then return 0 end -- staying put is always free

  local w = config.weights
  local interval = math.abs(assignment_pitch(cur) - assignment_pitch(prev))
  if interval < w.wide_leap_semitones then return 0 end

  -- Forced abandonment: cur's pitch is below prev's string's OPEN pitch,
  -- so no fret could ever reach it there - staying was never an option.
  -- The whole point of this penalty is to discourage a WASTEFUL early
  -- bail-out when the run could have continued - it shouldn't also tax a
  -- change that was mandatory. Traced against a real riff: without this,
  -- a note with no reachable string in common with its neighbors (e.g.
  -- landing well outside every other candidate's range) pays the same
  -- string-change cost as a lazy one, which is steep enough to
  -- retroactively distort the PREVIOUS note's own choice.
  --
  -- Deliberately checks only the LOW side (target_fret < 0), not the
  -- high side (target_fret > max_fret): also waiving it there was tried
  -- and reverted - it let a run that had climbed to max_fret get a free
  -- pass to ANY subsequent pitch (since almost nothing is reachable from
  -- the ceiling), which made parking at the ceiling systematically
  -- cheaper than a sensible low-fret alternative for the exact same note
  -- reachable both ways. A string's open pitch is a fixed floor no
  -- matter what fret came before, which is what makes the low side safe
  -- to forgive; max_fret is just wherever the run happens to have
  -- climbed to, which isn't.
  local target_fret = assignment_pitch(cur) - (config.tuning[prev.string] + config.capo)
  if target_fret < 0 then
    return 0
  end

  -- rule 2 takes priority over rule 1/3 once already up in tapping
  -- territory: the DP optimizes the WHOLE remaining path, not just this
  -- one step, so an unconditional "open is always free" pass lets it
  -- abandon a run early to take a cheaper detour through low frets
  -- overall - even though locally continuing the run looked fine. Only
  -- waive the string-change penalty for an open landing when the
  -- previous note DIDN'T already commit to a high position.
  local already_tapping = prev.fret > w.wide_leap_tap_fret_threshold

  if cur.fret == 0 and not already_tapping then
    return 0 -- rule 1/3: landing a leap on an open string is free
  end

  local penalty = w.wide_leap_string_change_penalty
  if already_tapping then
    penalty = penalty + w.wide_leap_tap_continuation_penalty
  end
  return penalty
end

-- position_change_weight assumes every fret of movement costs the
-- fretting hand roughly the same effort, which holds for an ordinary
-- shift/slide but not for tapping: staying on the SAME string while
-- either endpoint is already above wide_leap_tap_fret_threshold doesn't
-- cost the fretting hand a normal fret-by-fret repositioning (that's
-- what makes rule 2's same-string preference actually pay off instead
-- of fighting the position cost that motivated switching away from the
-- string in the first place) - use tap_position_change_weight instead
-- for that one transition. Gated on `established_run` (see
-- M.assign_events' run_len tracking): the discount is only earned by a
-- candidate that's ALREADY at least two notes deep into holding this
-- string, not a one-off arrival that happens to land on it via a big
-- cross-string leap of its own. Without this gate, a fresh arrival's
-- cheap-looking same-string exit can retroactively make the DP prefer
-- that wrong arrival over the previous note's own genuinely better
-- choice, purely to set up the discount for whatever comes after -
-- traced against a real riff where this exact thing was pulling an
-- otherwise-correct note onto the wrong string. Single-note states
-- only, matching wide_leap_cost's own scope. Also gated on config.
-- wide_leap_enabled, same as wide_leap_cost - off restores the plain
-- position_change_weight unconditionally, regardless of established_run.
local function position_weight_for(prev_state, state, established_run)
  local w = config.weights
  if config.wide_leap_enabled and established_run and #prev_state == 1 and #state == 1 and prev_state[1] and state[1]
      and prev_state[1].string == state[1].string
      and (prev_state[1].fret > w.wide_leap_tap_fret_threshold or state[1].fret > w.wide_leap_tap_fret_threshold) then
    return w.tap_position_change_weight
  end
  return w.position_change_weight
end

-- Cost of moving from prev_state's hand position/strings to state's.
-- established_run: true when prev_state is itself already 2+ consecutive
-- same-string notes deep (see M.assign_events) - passed through to
-- position_weight_for, see its comment for why this gate exists.
local function transition_cost(prev_state, state, established_run)
  local w = config.weights
  local cost = 0

  local prev_pos, pos = hand_position(prev_state), hand_position(state)
  if prev_pos and pos then
    cost = cost + math.abs(pos - prev_pos) * position_weight_for(prev_state, state, established_run)
  end

  local prev_str, str = avg_string(prev_state), avg_string(state)
  if prev_str and str then
    cost = cost + math.abs(str - prev_str) * w.string_change_weight
  end

  cost = cost + wide_leap_cost(prev_state, state)

  return cost
end

-- ---------------------------------------------------------------------
-- DP / Viterbi over events
-- ---------------------------------------------------------------------

-- events: list of {tick=..., notes={...}} from midi_read.group_into_events.
-- Returns a new events list, structurally identical, with each note table
-- copied and annotated with .string/.fret (left nil if unreachable).
function M.assign_events(events)
  local n_events = #events
  if n_events == 0 then return {} end

  local states_per_event = {}
  for e = 1, n_events do
    states_per_event[e] = generate_event_states(events[e])
  end

  local costs = {}
  local backptr = {}
  -- run_len[e][si]: how many consecutive events, ending at e, candidate
  -- si has stayed on the same single string (>=1 always; >=2 means its
  -- OWN predecessor was already on this string too, i.e. a real run, not
  -- a fresh arrival). See position_weight_for's comment for why this
  -- matters - it's what lets that discount tell a genuine in-progress
  -- tap run apart from a one-off landing that only coincidentally shares
  -- a string with whatever comes next.
  local run_len = {}

  for e = 1, n_events do
    costs[e] = {}
    backptr[e] = {}
    run_len[e] = {}
    local states = states_per_event[e]

    for si = 1, #states do
      local ic = intrinsic_cost(states[si])

      if e == 1 then
        costs[e][si] = ic
        run_len[e][si] = 1
      else
        local prev_states = states_per_event[e - 1]
        local best_cost, best_prev = nil, nil
        for pi = 1, #prev_states do
          local established = (run_len[e - 1][pi] or 1) >= 2
          local c = costs[e - 1][pi] + transition_cost(prev_states[pi], states[si], established)
          if not best_cost or c < best_cost then
            best_cost = c
            best_prev = pi
          end
        end
        costs[e][si] = best_cost + ic
        backptr[e][si] = best_prev

        local state, prev_state = states[si], prev_states[best_prev]
        if #state == 1 and #prev_state == 1 and state[1] and prev_state[1]
            and state[1].string == prev_state[1].string then
          run_len[e][si] = (run_len[e - 1][best_prev] or 1) + 1
        else
          run_len[e][si] = 1
        end
      end
    end
  end

  local best_final_cost, best_final_idx = nil, nil
  for si = 1, #states_per_event[n_events] do
    local c = costs[n_events][si]
    if not best_final_cost or c < best_final_cost then
      best_final_cost = c
      best_final_idx = si
    end
  end

  local chosen = {}
  local idx = best_final_idx
  for e = n_events, 1, -1 do
    chosen[e] = idx
    idx = backptr[e][idx]
  end

  local result = {}
  for e = 1, n_events do
    local event = events[e]
    local state = states_per_event[e][chosen[e]]
    local new_notes = {}
    for i = 1, #event.notes do
      local copy = {}
      for k, v in pairs(event.notes[i]) do copy[k] = v end
      local assign = state[i]
      if assign then
        copy.string = assign.string
        copy.fret = assign.fret
      end
      new_notes[i] = copy
    end
    result[e] = { tick = event.tick, notes = new_notes }
  end

  return result
end

-- Unpacks assign_events' output back into a flat, tick-ordered note list -
-- the shape main.lua's display loop (and, later, layout_engine.lua) wants.
function M.flatten(events)
  local flat = {}
  for e = 1, #events do
    local notes = events[e].notes
    for i = 1, #notes do
      flat[#flat + 1] = notes[i]
    end
  end
  return flat
end

return M
