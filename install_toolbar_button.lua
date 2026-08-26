-- One-time setup action: adds an "rTAB" button to REAPER's Main toolbar,
-- so main.lua can be launched with a click instead of digging through
-- the Action List every time. Run this ONCE from the Action List after
-- installing (see POST_INSTALL.txt) - safe to re-run: it detects an
-- existing button and either leaves it alone (already up to date) or
-- brings it in line with TOOLBAR_LABEL below (e.g. after this script
-- itself gets updated), rather than adding a duplicate.
--
-- Text, not an icon: REAPER draws every toolbar button in the same
-- theme-fixed icon slot size regardless of the source image's own
-- resolution, so a custom icon here would always render tiny - the only
-- way to get a bigger, more legible button is to have REAPER show the
-- item's text label instead, which it does automatically for any
-- toolbar item with no icon_N= line. That's the whole reason this
-- doesn't install an icon file the way an earlier version did.
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
--   2. Writes one item_N= line into reaper-menu.ini's "[Main toolbar]"
--      section (REAPER's own toolbar-layout file) - the same file
--      REAPER's own "Customize menus/toolbars" dialog writes to, just
--      automated here instead of asked of the user by hand.
--
-- Every existing line in reaper-menu.ini (including someone else's
-- hand-built toolbar layout) is preserved byte-for-byte apart from the
-- one line this script owns, and a timestamped backup is written
-- alongside it before any change, specifically so a friend running this
-- via the installer has an easy manual undo if anything ever looks
-- wrong. The exact item_N= key format is REAPER's own long-standing
-- convention, not a documented public API - if a future REAPER version
-- changes it, this degrades to "does nothing, shows an error" rather
-- than corrupting the file, since the parse happens entirely in memory
-- before any write.

local info = debug.getinfo(1, 'S')
local script_dir = info.source:match([[^@?(.*[\/])[^\/]-$]])

local MAIN_LUA_PATH = script_dir .. "main.lua"
local TOOLBAR_LABEL = "rTAB"
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

-- Finds TOOLBAR_SECTION within `lines` (an array of every line in
-- reaper-menu.ini) and scans its item_N=/icon_N= lines. Returns a table:
--   found        - true if the section exists at all
--   section_end  - line index AFTER the section's last line (the next
--                  "[...]" header, or #lines + 1 for end-of-file) - nil
--                  if the section doesn't exist
--   next_index   - lowest unused N in the section (0 if the section
--                  doesn't exist yet)
--   existing     - nil, or { item_line = <index in `lines`>,
--                  icon_line = <index in `lines`, or nil> } if
--                  command_ref already appears as some item_N here
local function scan_section(lines, command_ref)
  local section_start = nil
  for i, line in ipairs(lines) do
    if line == TOOLBAR_SECTION then
      section_start = i
      break
    end
  end
  if not section_start then
    return { found = false, next_index = 0 }
  end

  local max_index = -1
  local existing = nil
  local icon_line_by_index = {}
  local section_end = #lines + 1

  for i = section_start + 1, #lines do
    local line = lines[i]
    if line:match("^%[") then
      section_end = i
      break
    end
    local item_n = line:match("^item_(%d+)=")
    if item_n then
      local n = tonumber(item_n)
      max_index = math.max(max_index, n)
      -- item_N=<command_ref> <label> - match the command ref as the
      -- first whitespace-delimited token so a label collision (unlikely)
      -- never produces a false "already installed".
      if line:match("^item_%d+=(%S+)") == command_ref then
        existing = { index = n, item_line = i }
      end
    end
    local icon_n = line:match("^icon_(%d+)=")
    if icon_n then
      icon_line_by_index[tonumber(icon_n)] = i
    end
  end

  if existing then
    existing.icon_line = icon_line_by_index[existing.index]
  end

  return { found = true, section_end = section_end, next_index = max_index + 1, existing = existing }
end

-- Returns (ok, changed, err). changed is false when the button already
-- matches TOOLBAR_LABEL with no icon (nothing to do); true when a line
-- was added (brand new button) or rewritten (an existing button - e.g.
-- one installed by an older version of this script that also set an
-- icon_N= line, which gets dropped here - see header for why).
local function install_toolbar_entry(resource_path, command_ref)
  local ini_path = resource_path .. "/reaper-menu.ini"

  local existing_content = ""
  local f = io.open(ini_path, "rb")
  if f then
    existing_content = f:read("*a")
    f:close()
  end

  local lines = {}
  if existing_content ~= "" then
    for line in (existing_content .. "\n"):gmatch("(.-)\r?\n") do
      table.insert(lines, line)
    end
    -- The gmatch above yields one trailing empty line from the appended
    -- "\n" - drop it so line count/backup content matches the source
    -- file exactly.
    if lines[#lines] == "" then table.remove(lines) end
  end

  local scan = scan_section(lines, command_ref)
  local out

  if scan.existing then
    local desired_line = "item_" .. scan.existing.index .. "=" .. command_ref .. " " .. TOOLBAR_LABEL
    if lines[scan.existing.item_line] == desired_line and not scan.existing.icon_line then
      return true, false -- already up to date
    end
    out = {}
    for i = 1, #lines do
      if i == scan.existing.icon_line then
        -- drop it - text-only now (see header)
      elseif i == scan.existing.item_line then
        table.insert(out, desired_line)
      else
        table.insert(out, lines[i])
      end
    end
  else
    local desired_line = "item_" .. scan.next_index .. "=" .. command_ref .. " " .. TOOLBAR_LABEL
    out = {}
    if scan.found then
      for i = 1, scan.section_end - 1 do table.insert(out, lines[i]) end
      table.insert(out, desired_line)
      for i = scan.section_end, #lines do table.insert(out, lines[i]) end
    else
      for i = 1, #lines do table.insert(out, lines[i]) end
      if #lines > 0 then table.insert(out, "") end
      table.insert(out, TOOLBAR_SECTION)
      table.insert(out, desired_line)
    end
  end

  -- Back up before any write - only reached when something is actually
  -- about to change.
  if existing_content ~= "" then
    local backup_path = ini_path .. ".bak-" .. os.date("%Y%m%d-%H%M%S")
    local b = io.open(backup_path, "wb")
    if b then
      b:write(existing_content)
      b:close()
    end
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
