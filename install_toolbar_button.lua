-- One-time setup action: adds a Tab/Notation Viewer button to REAPER's
-- Main toolbar, so main.lua can be launched with a click instead of
-- digging through the Action List every time. Run this ONCE from the
-- Action List after installing (see POST_INSTALL.txt) - safe to re-run,
-- it detects an existing button and does nothing rather than adding a
-- duplicate.
--
-- Why this has to run INSIDE REAPER rather than be done by the Windows
-- installer: registering a script as an action (and getting its real,
-- stable command ID) requires REAPER's own AddRemoveReaScript API, which
-- only exists while REAPER is running - an external installer has no way
-- to call it. This script does the two things that API access unlocks:
--   1. Registers main.lua as an action (AddRemoveReaScript) and resolves
--      its permanent named command ID (ReverseNamedCommandLookup) - the
--      numeric ID AddRemoveReaScript itself returns is only valid for
--      THIS REAPER install/session and isn't safe to write into a config
--      file meant to persist, per REAPER's own SDK docs.
--   2. Appends one item_N/icon_N pair to reaper-menu.ini's
--      "[Main toolbar]" section (REAPER's own toolbar-layout file) and
--      copies the bundled icon into Data/toolbar_icons - the same file
--      REAPER's own "Customize menus/toolbars" dialog writes to, just
--      automated here instead of asked of the user by hand.
--
-- This is an append-only edit: every existing line in reaper-menu.ini
-- (including someone else's hand-built toolbar layout) is preserved
-- byte-for-byte, and a timestamped backup is written alongside it before
-- any change, specifically so a friend running this via the installer
-- has an easy manual undo if anything ever looks wrong. The exact
-- item_N=/icon_N= key format is REAPER's own long-standing convention,
-- not a documented public API - if a future REAPER version changes it,
-- this degrades to "does nothing, shows an error" rather than corrupting
-- the file, since the parse happens entirely in memory before any write.

local info = debug.getinfo(1, 'S')
local script_dir = info.source:match([[^@?(.*[\/])[^\/]-$]])

local MAIN_LUA_PATH = script_dir .. "main.lua"
local ICON_SOURCE_PATH = script_dir .. "assets" .. package.config:sub(1, 1) .. "toolbar_icon.png"
local TOOLBAR_LABEL = "Tab / Notation Viewer"
local ICON_FILENAME = "reaper_tab_notation.png"
local TOOLBAR_SECTION = "[Main toolbar]"

local function fail(message)
  reaper.MB(message, "Install Toolbar Button", 0)
end

-- Registers main.lua as a REAPER action (idempotent - re-adding an
-- already-registered script just returns its existing command) and
-- resolves the permanent named command ID (see header for why the raw
-- numeric ID isn't safe to persist).
local function get_command_ref()
  local num_id = reaper.AddRemoveReaScript(true, 0, MAIN_LUA_PATH, true)
  if not num_id or num_id == 0 then
    return nil, "Couldn't register main.lua as a REAPER action - is it at:\n" .. MAIN_LUA_PATH .. "?"
  end
  local named = reaper.ReverseNamedCommandLookup(num_id)
  if not named or named == "" then
    return nil, "Registered the action but couldn't resolve its command ID."
  end
  return "_" .. named
end

-- Copies the bundled icon into REAPER's Data/toolbar_icons folder (the
-- same place its own icon themes live) - plain binary read/write, since
-- ReaScript has no built-in file-copy call.
local function install_icon(resource_path)
  local dest_dir = resource_path .. "/Data/toolbar_icons"
  reaper.RecursiveCreateDirectory(dest_dir, 0)
  local dest_path = dest_dir .. "/" .. ICON_FILENAME

  local src = io.open(ICON_SOURCE_PATH, "rb")
  if not src then
    return false, "Icon file not found at:\n" .. ICON_SOURCE_PATH
  end
  local data = src:read("*a")
  src:close()

  local dest = io.open(dest_path, "wb")
  if not dest then
    return false, "Couldn't write icon to:\n" .. dest_path
  end
  dest:write(data)
  dest:close()
  return true
end

-- Finds TOOLBAR_SECTION's line range within `lines` (an array of every
-- line in reaper-menu.ini) - returns (section_start, section_end,
-- next_item_index, already_present), where section_end is the line
-- AFTER the section's last line (i.e. the next "[...]" header, or
-- #lines + 1 for end-of-file), and already_present is true if
-- command_ref already appears in an item_N= line in this section.
local function scan_section(lines, command_ref)
  local section_start = nil
  for i, line in ipairs(lines) do
    if line == TOOLBAR_SECTION then
      section_start = i
      break
    end
  end
  if not section_start then
    return nil
  end

  local max_index = -1
  local already_present = false
  local section_end = #lines + 1
  for i = section_start + 1, #lines do
    local line = lines[i]
    if line:match("^%[") then
      section_end = i
      break
    end
    local n = line:match("^item_(%d+)=")
    if n then
      max_index = math.max(max_index, tonumber(n))
      -- item_N=<command_ref> <label> - match the command ref as the
      -- first whitespace-delimited token so a label collision (unlikely)
      -- never produces a false "already installed".
      local existing_ref = line:match("^item_%d+=(%S+)")
      if existing_ref == command_ref then
        already_present = true
      end
    end
  end

  return section_start, section_end, max_index + 1, already_present
end

local function install_toolbar_entry(resource_path, command_ref)
  local ini_path = resource_path .. "/reaper-menu.ini"

  local existing = ""
  local f = io.open(ini_path, "rb")
  if f then
    existing = f:read("*a")
    f:close()
  end

  local lines = {}
  if existing ~= "" then
    for line in (existing .. "\n"):gmatch("(.-)\r?\n") do
      table.insert(lines, line)
    end
    -- The gmatch above yields one trailing empty line from the appended
    -- "\n" - drop it so line count/backup content matches the source
    -- file exactly.
    if lines[#lines] == "" then table.remove(lines) end
  end

  local section_start, section_end, next_index, already_present = scan_section(lines, command_ref)

  if section_start and already_present then
    return true, false -- ok, no change needed
  end

  -- Back up before any write - only the very first write this session
  -- needs one, but this function only ever runs once per invocation.
  if existing ~= "" then
    local backup_path = ini_path .. ".bak-" .. os.date("%Y%m%d-%H%M%S")
    local b = io.open(backup_path, "wb")
    if b then
      b:write(existing)
      b:close()
    end
  end

  -- index is 0 for a brand-new section (next_index is nil in that case,
  -- since scan_section returned bare nil - see its own header), or the
  -- next free slot in an existing one.
  local index = section_start and next_index or 0
  local icon_line = "icon_" .. index .. "=" .. ICON_FILENAME
  local item_line = "item_" .. index .. "=" .. command_ref .. " " .. TOOLBAR_LABEL

  local out = {}
  if section_start then
    for i = 1, section_end - 1 do table.insert(out, lines[i]) end
    table.insert(out, icon_line)
    table.insert(out, item_line)
    for i = section_end, #lines do table.insert(out, lines[i]) end
  else
    for i = 1, #lines do table.insert(out, lines[i]) end
    if #lines > 0 then table.insert(out, "") end
    table.insert(out, TOOLBAR_SECTION)
    table.insert(out, icon_line)
    table.insert(out, item_line)
  end

  local w = io.open(ini_path, "wb")
  if not w then
    return false, nil, "Couldn't write to:\n" .. ini_path
  end
  w:write(table.concat(out, "\n") .. "\n")
  w:close()

  return true, true
end

local function main()
  local command_ref, err = get_command_ref()
  if not command_ref then
    fail(err)
    return
  end

  local resource_path = reaper.GetResourcePath()

  local icon_ok, icon_err = install_icon(resource_path)
  if not icon_ok then
    fail(icon_err)
    return
  end

  local ok, changed, ini_err = install_toolbar_entry(resource_path, command_ref)
  if not ok then
    fail(ini_err)
    return
  end

  if changed then
    reaper.MB(
      "Added '" .. TOOLBAR_LABEL .. "' to the Main toolbar.\n\nRestart REAPER to see it " ..
      "(reaper-menu.ini is only read at startup). A backup of your previous toolbar layout was saved " ..
      "alongside reaper-menu.ini.",
      "Install Toolbar Button", 0)
  else
    reaper.MB("'" .. TOOLBAR_LABEL .. "' is already on the Main toolbar.", "Install Toolbar Button", 0)
  end
end

main()
