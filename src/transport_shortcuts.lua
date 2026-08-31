-- Global REAPER transport keyboard shortcuts, reproduced here because a
-- floating ReaImGui window owns keyboard focus itself - REAPER's own
-- global shortcuts (bound in reaper-kb.ini) never fire while this panel
-- has focus, the same reason every other floating ReaImGui transport/
-- utility script re-implements them rather than relying on REAPER's main
-- window to see the keypress. Space/Home/End are bound to REAPER's own
-- STOCK factory-default actions for Play/Stop and Go to start/end of
-- project. Record has no reliable stock single-key default, so Ctrl+R was
-- used instead - deliberately requiring a modifier so it can never
-- collide with typing a lone "r" into one of this panel's own text
-- fields (Title, Tab Code, tuning names, etc.).
--
-- Gated on NOT currently typing into one of this panel's own text fields
-- (reaper.ImGui_IsAnyItemActive is true while any of them has an active
-- text cursor - exactly when Space needs to type a literal space rather
-- than toggle playback, and when Home/End need to move the text cursor
-- rather than jump the project position) and on this panel's own window
-- tree actually having focus (so a stray keypress while some OTHER REAPER
-- window, or another floating script, is focused doesn't fire these).

local M = {}

local ACTION_PLAY_STOP = 40044   -- Transport: Play/stop
local ACTION_GO_TO_START = 40042 -- Transport: Go to start of project
local ACTION_GO_TO_END = 40043   -- Transport: Go to end of project
local ACTION_RECORD = 1013       -- Transport: Record

-- Call once per frame - checks its own guards, so callers don't need to
-- wrap this in their own IsAnyItemActive/IsWindowFocused check.
function M.handle(ctx)
  if reaper.ImGui_IsAnyItemActive(ctx) then return end
  if not reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then return end

  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space(), false) then
    reaper.Main_OnCommand(ACTION_PLAY_STOP, 0)
  end
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Home(), false) then
    reaper.Main_OnCommand(ACTION_GO_TO_START, 0)
  end
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_End(), false) then
    reaper.Main_OnCommand(ACTION_GO_TO_END, 0)
  end

  local ctrl_down = (reaper.ImGui_GetKeyMods(ctx) & reaper.ImGui_Mod_Ctrl()) ~= 0
  if ctrl_down and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_R(), false) then
    reaper.Main_OnCommand(ACTION_RECORD, 0)
  end
end

return M
