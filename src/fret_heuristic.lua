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

  -- Every note in the chord conflicted on every string it could reach (rare,
  -- only possible with a small string count or a dense chord) - fall back
  -- to "everything unreachable" so the event still produces one state
  -- instead of stalling the DP with zero candidates.
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

-- Extra cost for changing strings across a WIDE pitch leap (config.
-- weights.wide_leap_semitones/wide_leap_string_change_penalty - see their
-- own comments in config.lua for the full reasoning). Scoped to single-
-- note states only (a chord isn't a "leap" in this sense), and only
-- fires when a same-string alternative actually exists within max_fret -
-- if the previous note's string can't reach this pitch at all, the DP
-- never had that option, so there's nothing to penalize choosing instead.
local function wide_leap_cost(prev_state, state)
  if #prev_state ~= 1 or #state ~= 1 then return 0 end
  local prev, cur = prev_state[1], state[1]
  if not prev or not cur then return 0 end
  if prev.string == cur.string then return 0 end

  local w = config.weights
  local cur_pitch = assignment_pitch(cur)
  local interval = math.abs(cur_pitch - assignment_pitch(prev))
  if interval < w.wide_leap_semitones then return 0 end

  local same_string_fret = cur_pitch - (config.tuning[prev.string] + config.capo)
  if same_string_fret < 0 or same_string_fret > config.max_fret then return 0 end

  return w.wide_leap_string_change_penalty
end

-- Cost of moving from prev_state's hand position/strings to state's.
local function transition_cost(prev_state, state)
  local w = config.weights
  local cost = 0

  local prev_pos, pos = hand_position(prev_state), hand_position(state)
  if prev_pos and pos then
    cost = cost + math.abs(pos - prev_pos) * w.position_change_weight
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

  for e = 1, n_events do
    costs[e] = {}
    backptr[e] = {}
    local states = states_per_event[e]

    for si = 1, #states do
      local ic = intrinsic_cost(states[si])

      if e == 1 then
        costs[e][si] = ic
      else
        local prev_states = states_per_event[e - 1]
        local best_cost, best_prev = nil, nil
        for pi = 1, #prev_states do
          local c = costs[e - 1][pi] + transition_cost(prev_states[pi], states[si])
          if not best_cost or c < best_cost then
            best_cost = c
            best_prev = pi
          end
        end
        costs[e][si] = best_cost + ic
        backptr[e][si] = best_prev
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
