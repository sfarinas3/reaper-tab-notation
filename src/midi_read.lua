-- Take discovery, change detection, and raw note extraction. This module
-- knows nothing about fret assignment or rendering - it just hands back
-- plain note data from whatever MIDI item is selected.
--
-- Shamisen technique tags (Sukui/Hajiki/Uchi/Suri/Oshibachi-Suberi/Keshi -
-- see note_editor.lua's TECHNIQUES) are stored as REAPER's own per-note
-- "notation event" (MIDI_InsertTextSysexEvt with type 15), the same
-- mechanism REAPER's own notation editor uses for fingerings/articulations
-- - confirmed text convention: "NOTE <chan> <pitch> <key> <value> ...".
-- Reusing this (under an app-specific key, M.TECH_KEY, so it can't collide
-- with REAPER's own recognized keys like disp_len) means the tag travels
-- naturally with the take/project like any other REAPER-native note
-- property, with no custom persistence of our own to build or maintain.

local M = {}

M.TECH_KEY = "shamisen_tech"

-- Scans every text/sysex event once (cheaper than a per-note lookup scan)
-- and returns "<startppq>:<chan>:<pitch>" -> technique id. Composite-keyed
-- on all three since chan+pitch alone can repeat at different ticks, and
-- ppq alone can repeat across a chord's notes.
local function read_technique_map(take)
  local map = {}
  local ok, _, _, textsyxevtcnt = reaper.MIDI_CountEvts(take)
  if not ok then return map end

  for i = 0, textsyxevtcnt - 1 do
    local evt_ok, _, _, ppqpos, evt_type, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if evt_ok and evt_type == 15 then
      local chan, pitch, tech = msg:match("^NOTE (%d+) (%d+) " .. M.TECH_KEY .. " (%d+)")
      if chan then
        map[ppqpos .. ":" .. chan .. ":" .. pitch] = tonumber(tech)
      end
    end
  end

  return map
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

-- Cheap per-tick fingerprint for change detection. notesonly=true so this
-- only changes when note data changes (not CC/other MIDI events). Returns
-- nil if take is nil or the call fails.
function M.get_notes_hash(take)
  if not take then return nil end
  local ok, hash = reaper.MIDI_GetHash(take, true, "")
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
-- generic-copy path, from read_technique_map's lookup above.
function M.read_notes(take)
  local notes = {}
  if not take then return notes end

  local ok, note_count = reaper.MIDI_CountEvts(take)
  if not ok then return notes end

  local technique_map = read_technique_map(take)

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
