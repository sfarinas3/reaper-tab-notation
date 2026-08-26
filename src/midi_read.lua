-- Take discovery, change detection, and raw note extraction. This module
-- knows nothing about fret assignment or rendering - it just hands back
-- plain note data from whatever MIDI item is selected.
--
-- Shamisen technique tags (Sukui/Hajiki/Uchi/Suri/Oshibachi-Suberi/Keshi -
-- see note_editor.lua's TECHNIQUES) are stored on the TAKE itself, via
-- REAPER's per-take P_EXT persistent-data mechanism (the same one
-- ui_chrome.lua already uses for instrument/tuning/title - see that
-- file's header), NOT as a REAPER-native MIDI "notation event"
-- (MIDI_InsertTextSysexEvt type 15, this app's original approach). That
-- approach was abandoned after extensive live debugging: inserts appeared
-- to succeed (correct return path, correct message text), but
-- MIDI_CountEvts reported zero text/sysex events back on the very next
-- read, in the same REAPER session, with no error - REAPER's own internal
-- handling of type-15 events was silently discarding them for reasons
-- that stayed opaque after many rounds of instrumented testing. Rather
-- than keep reverse-engineering that undocumented behavior, this switches
-- to a mechanism already proven reliable elsewhere in this exact codebase.
--
-- Packed as "<startppq>:<chan>:<pitch>=<technique_id>;..." - composite-
-- keyed on all three since chan+pitch alone can repeat at different ticks,
-- and ppq alone can repeat across a chord's notes. note_editor.lua's
-- write path (commit_technique) reuses M.read_technique_map/
-- M.serialize_technique_map directly so the two never disagree on format.
local M = {}

M.TECH_EXT_KEY = "P_EXT:reaper-tab-notation-techniques"

-- "<startppq>:<chan>:<pitch>" -> technique id, or {} if take has none saved.
function M.read_technique_map(take)
  local map = {}
  local ok, str = reaper.GetSetMediaItemTakeInfo_String(take, M.TECH_EXT_KEY, "", false)
  if not ok or str == "" then return map end
  for entry in str:gmatch("[^;]+") do
    local key, id = entry:match("^(.-)=(%-?%d+)$")
    if key then map[key] = tonumber(id) end
  end
  return map
end

function M.serialize_technique_map(map)
  local parts = {}
  for key, id in pairs(map) do
    parts[#parts + 1] = key .. "=" .. id
  end
  return table.concat(parts, ";")
end

-- Returns the active MIDI take of the first selected media item, or nil if
-- nothing selected / selection isn't a MIDI item.
function M.get_active_take()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then return nil end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then return nil end
  return take
end

-- Cheap per-tick fingerprint for change detection. notesonly=false so this
-- also picks up REAPER's own native notation events (fingerings etc.) and
-- any CC/other MIDI changes, not just note pitch/timing - a harmless
-- trade since recompute is cheap at this app's scale (see
-- layout_engine.lua's header). Technique tags themselves live in the
-- take's P_EXT data (this file's header) rather than MIDI events, so
-- they're invisible to this hash either way - note_editor.lua signals its
-- own "please recompute" separately (see its end_frame's return value)
-- rather than relying on this. Returns nil if take is nil or the call fails.
function M.get_notes_hash(take)
  if not take then return nil end
  local ok, hash = reaper.MIDI_GetHash(take, false, "")
  if not ok then return nil end
  return hash
end

-- Reads every note in take into a flat list, in the order MIDI_GetNote
-- returns them (start-position order):
--   { {startppq, endppq, pitch, chan, vel, selected, muted, idx, technique}, ... }
-- idx is MIDI_GetNote's own note index within take, carried through
-- fret_heuristic.lua and layout_engine.lua's generic field-copies
-- unchanged (both copy note tables via `for k, v in pairs(note)`) - it's
-- how note_editor.lua's write-back finds its way back to MIDI_SetNote
-- without a separate identity-matching step. Stays valid for as long as
-- this note list is in use: nothing in this pipeline inserts/deletes
-- notes, only note_editor.lua's own edits do, and each of those closes
-- its popup immediately after writing (see note_editor.lua's header) -
-- the next hash change re-reads fresh indices before anything could act
-- on a stale one. technique (nil if untagged) comes from the same
-- generic-copy path, from M.read_technique_map's lookup above.
function M.read_notes(take)
  local notes = {}
  if not take then return notes end

  local ok, note_count = reaper.MIDI_CountEvts(take)
  if not ok then return notes end

  local technique_map = M.read_technique_map(take)

  for i = 0, note_count - 1 do
    local note_ok, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if note_ok then
      notes[#notes + 1] = {
        startppq = startppq,
        endppq = endppq,
        pitch = pitch,
        chan = chan,
        vel = vel,
        selected = selected,
        muted = muted,
        idx = i,
        technique = technique_map[startppq .. ":" .. chan .. ":" .. pitch],
      }
    end
  end

  table.sort(notes, function(a, b) return a.startppq < b.startppq end)

  return notes
end

-- Groups a flat, start-sorted note list into chord-events: notes sharing a
-- start tick become one event, since the fret-assignment DP has to assign
-- a chord's strings jointly (no two notes in the same event may land on the
-- same string). Returns events sorted by tick:
--   { {tick = startppq, notes = {note, ...}}, ... }
function M.group_into_events(notes)
  local events = {}
  local current = nil
  for _, note in ipairs(notes) do
    if not current or note.startppq ~= current.tick then
      current = { tick = note.startppq, notes = {} }
      events[#events + 1] = current
    end
    current.notes[#current.notes + 1] = note
  end
  return events
end

return M
