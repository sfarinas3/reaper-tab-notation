-- reaper-tab-notation
-- Entry point loaded by REAPER's Action list.
-- Phase 5 (line-wrapping): notation staff (draw_notation.lua/
-- notation_model.lua) stacked above the tab staff, sharing
-- layout_engine.lua's x-map. Noteheads (X-shaped for notes outside the
-- instrument's range, usually a mute/scrape - mirrored on the tab staff
-- as "x" text at a configurable string) + stems + time-signature-aware
-- beam grouping + flags for un-beamed short notes + ledger lines +
-- accidentals (measure-scoped suppression) + ties + rests + a real brace
-- glyph and staff-split hysteresis for the grand staff, plus barlines
-- (read from the REAPER project's meter) spanning both staves, plus a
-- playhead line that tracks REAPER's transport during playback, plus a
-- measure-number label (item-relative and REAPER's own absolute number)
-- above each measure and a tempo marking at the start and wherever it
-- changes, plus a clef (every system) and time signature (start and
-- meter changes) on the notation staff, and a "TAB" label on the tab
-- staff. Beam grouping and tie inference are meter-aware throughout
-- (notation_model.beat_ticks_lookup), not pinned to whatever meter was
-- active at the take's start. A single held note/chord that crosses one or
-- more barlines is automatically split into tied segments at each
-- boundary (layout_engine.compute, given cached_measure_ticks) - standard
-- engraving practice, since a note is never drawn straddling a barline as
-- one symbol. measure_boundaries already walked
-- TimeMap_GetMeasureInfo per measure for barlines, so per-measure meter
-- and tempo come from that same walk. The whole thing wraps into multiple systems
-- (layout_engine.wrap_into_systems) when content is wider than the
-- panel, breaking only at measure boundaries, sized from the window's
-- own frame (not GetContentRegionAvail, which shrinks whenever a
-- scrollbar shows and caused a resize<->scrollbar feedback loop) - the
-- view auto-scrolls vertically during playback to keep the active system
-- in view. No tuplet brackets or cross-staff beam joining (both punted -
-- see draw_notation.lua's header). A collapsible "Instrument Settings"
-- panel (ui_chrome.lua) lets the user set the instrument (a one-click
-- preset - currently Guitar/Shamisen - that swaps string count, tuning,
-- and max fret together), string count, tuning (presets or per-string
-- note names), capo, max fret, and key signature. Persisted two ways: an
-- ExtState "last used globally" fallback, and - since a guitar take and a
-- shamisen take (or just two differently-tuned guitar takes) shouldn't
-- have to share one setting - each take's OWN settings, saved directly on
-- it (ui_chrome.save_for_take/load_for_take) and restored whenever the
-- active take itself changes (tracked here via last_take, separately from
-- the note-hash check, which only covers edits to whichever take is
-- already active). Either kind of change forces a recompute even though
-- none of it touches MIDI note data itself (see ui_chrome.lua's header).
-- The key signature drives both the key-signature glyphs drawn after the
-- clef and key-aware note spelling/accidentals (notation_model.lua,
-- draw_notation.lua). Every string-count/tuning-scoped module is already
-- generic enough that a 3-string instrument (shamisen) needs no
-- special-casing - it automatically falls under the existing
-- string_count > 6 grand-staff trigger being false, giving treble-clef-
-- only notation for free. Zoom/track picker and poll-interval tuning are
-- still open Phase 5 items.
--
-- Phase 6: clicking a note on the tab staff (note_editor.lua) opens a
-- popup to correct its pitch or pin/unpin its string - the bounded write
-- path back into the take for when the fret-assignment heuristic picks a
-- musically-wrong string, since MIDI has no native string field and
-- REAPER's own piano roll has no way to set one. Duration changes,
-- insert/delete, and dragging remain REAPER-piano-roll-only.
--
-- Score header (title/composer/arranger, ui_chrome.lua's "Score Info"
-- section): drawn once above the very first system, like a real printed
-- score's title page - title centered and enlarged, composer/arranger
-- stacked top-right. All blank by default (no reserved space at all) so an
-- untouched take looks unchanged. title is piece-specific and per-take
-- only; composer/arranger also fall back to a global "last used" value,
-- same convenience instrument/tuning already have (see config.lua/
-- ui_chrome.lua headers).
--
-- The header/per-system drawing this file does each frame (score_render.
-- lua) is shared verbatim with pdf_export.lua's "Export to PDF" pass
-- (ui_chrome.lua's Print/Export section) - see those two files' own
-- headers for how a real vector PDF gets produced by temporarily
-- redirecting the exact same ImGui draw calls into a PDF file instead of
-- the screen, rather than a second renderer that could drift out of sync.

local SCRIPT_TITLE = "Guitar Tab/Notation Viewer"

if not reaper.ImGui_CreateContext then
  reaper.MB(
    "Missing dependency: ReaImGui.\n\nInstall it via Extensions > ReaPack > Browse packages, search for 'ReaImGui'.",
    "reaper-tab-notation", 0)
  return
end

local info = debug.getinfo(1, 'S')
local script_path = info.source:match([[^@?(.*[\/])[^\/]-$]])
package.path = script_path .. '?.lua;' .. script_path .. 'src/?.lua;' .. package.path

local config = require('config')
local midi_read = require('midi_read')
local fret_heuristic = require('fret_heuristic')
local layout_engine = require('layout_engine')
local notation_model = require('notation_model')
local draw_tab = require('draw_tab')
local draw_notation = require('draw_notation')
local score_render = require('score_render')
local ui_chrome = require('ui_chrome')
local note_editor = require('note_editor')
local color_util = require('color_util')
local pdf_export = require('pdf_export')

ui_chrome.load_persisted(config)

-- COLOR_PLAYHEAD is a fixed accent (the transport cursor) - not part of the
-- user-configurable background/foreground palette (config.color_bg/
-- color_fg, ui_chrome.lua's "Colors" section). Barline/label colors are
-- computed fresh each frame from that palette instead (see main(), below),
-- since they can change at runtime. Barline/header/label layout constants
-- now live in score_render.lua, shared with pdf_export.lua's print pass.
local COLOR_PLAYHEAD = 0xFF6020FF
local MIN_SYSTEM_WIDTH = 150 -- floor for a transiently tiny/collapsing window, so wrapping never degenerates
local WINDOW_CHROME_RESERVE = 40 -- fixed estimate for window padding + a possible vertical scrollbar
local BOTTOM_MARGIN = 10 -- px reserved below the last system, so the bottom tab string's fret-number text doesn't clip against the window's bottom edge

local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)

-- Needed for draw_tab.lua's shamisen technique markers (real katakana
-- glyphs, e.g. ハ for hajiki) - ReaImGui's default font has no Japanese
-- glyphs, so those would otherwise render as blank/missing. Loaded from an
-- actual font FILE (config.jp_font_file - msgothic.ttc, bundled with every
-- Windows install since Vista regardless of display language, not gated
-- behind a Japanese language pack) rather than matched by family name:
-- CreateFont's family-name lookup turned out not to resolve reliably
-- (nothing rendered, not even a tofu box - the by-name attempt this
-- replaced), whereas a direct file path is unambiguous. Falls back to the
-- old by-name approach (config.jp_font_family) if that exact file isn't
-- present, e.g. on a non-Windows REAPER install. Created/attached once
-- here rather than per-frame since the font itself never changes;
-- draw_tab.lua pushes/pops it only around the specific text it needs it
-- for, leaving every other font in this script as-is.
local function create_jp_font()
  local f = io.open(config.jp_font_file, 'rb')
  if f then
    f:close()
    -- index 0: the file's first face. msgothic.ttc bundles MS Gothic/MS
    -- PGothic/MS UI Gothic as separate faces at different indices (the
    -- exact order isn't guaranteed across Windows versions) - all three
    -- cover the same katakana glyphs this needs, just with different
    -- width metrics, so whichever one index 0 resolves to is fine here.
    return reaper.ImGui_CreateFontFromFile(config.jp_font_file, 0)
  end
  return reaper.ImGui_CreateFont(config.jp_font_family)
end

local jp_font = create_jp_font()
reaper.ImGui_Attach(ctx, jp_font)
draw_tab.set_jp_font(jp_font)

local last_hash = nil
local last_take = nil
local cached_render_model = nil
local cached_measure_ticks = nil
local cached_measure_info = nil
-- assigned_events (pre-layout: notes+string/fret, no x positions yet) -
-- cached alongside cached_render_model rather than only kept as main()'s
-- local, so pdf_export.lua can re-run layout_engine.compute() a second
-- time under print-only spacing constants (see pdf_export.lua's
-- HORIZONTAL_COMPRESSION) without re-reading MIDI or re-running the fret
-- heuristic - only the live view's own cached_render_model is built from
-- this at normal on-screen spacing.
local cached_assigned_events = nil
-- Set from the PREVIOUS frame's note_editor.end_frame return value (a
-- technique commit happened) - note_editor.lua's popup interaction runs
-- after this frame's own recompute check (it needs this frame's systems
-- for hit-testing), so its "please recompute" signal can only take effect
-- next frame. At 60fps that's imperceptible - see note_editor.lua's
-- header for why a technique change needs this at all (it lives in P_EXT,
-- invisible to the note-hash check).
local pending_recompute = false

local function set_toolbar_state(state)
  local _, _, section, cmd = reaper.get_action_context()
  if cmd and cmd ~= -1 then
    reaper.SetToggleCommandState(section, cmd, state or 0)
    reaper.RefreshToolbar2(section, cmd)
  end
end

local function on_exit()
  set_toolbar_state(0)
end

-- Closes over the module-level cached_render_model/cached_measure_ticks/
-- cached_measure_info (reassigned each recompute inside main(), below -
-- Lua upvalues always see the current value, not a snapshot from
-- whenever this closure was created) and ctx, so ui_chrome.lua's Print/
-- Export button can trigger a real export without that UI-only module
-- needing to know anything about the render model or PDF writing itself.
local function do_export(filepath)
  return pdf_export.export(ctx, config, cached_assigned_events, cached_measure_ticks, cached_measure_info, filepath)
end

local function main()
  local take = midi_read.get_active_take()
  local hash = midi_read.get_notes_hash(take)

  -- A different item's take becoming active is a separate event from the
  -- note-hash check below (that's about edits to whatever take is ALREADY
  -- active) - this is "the active take itself changed," which is when a
  -- take's own remembered instrument/tuning (see ui_chrome.lua's
  -- save_for_take/load_for_take) should take over from whatever was
  -- active before.
  local take_settings_changed = false
  if take ~= last_take then
    last_take = take
    take_settings_changed = ui_chrome.load_for_take(take, config)
  end

  -- ui_chrome.draw's return is a second, explicit cache-invalidation
  -- signal alongside the note-hash check below - tuning/capo edits never
  -- touch the MIDI take, so the hash alone would never notice them.
  local settings_changed = ui_chrome.draw(ctx, config, take, do_export)

  if hash ~= last_hash or settings_changed or take_settings_changed or pending_recompute then
    last_hash = hash
    pending_recompute = false
    if take then
      local notes = midi_read.read_notes(take)
      local events = midi_read.group_into_events(notes)
      local assigned_events = fret_heuristic.assign_events(events)
      -- Computed from assigned_events (not cached_render_model, which
      -- doesn't exist yet) since layout_engine.compute's tie inference
      -- needs per-measure meter data up front - measure_boundaries only
      -- needs .notes[].endppq for its own last_tick scan, which
      -- assigned_events already has, identically to what the eventual
      -- render model would carry.
      cached_measure_ticks, cached_measure_info = notation_model.measure_boundaries(take, assigned_events)
      cached_assigned_events = assigned_events
      -- Layout only needs recomputing when the notes actually change (or,
      -- later, on panel resize/zoom) - cached here alongside the heuristic
      -- result rather than recomputed every frame.
      cached_render_model = layout_engine.compute(assigned_events, {
        measure_width = draw_tab.make_measurer(ctx),
        beat_ticks_lookup = notation_model.beat_ticks_lookup(cached_measure_ticks, cached_measure_info),
        measure_ticks = cached_measure_ticks,
      })
    else
      cached_render_model = nil
      cached_measure_ticks = nil
      cached_measure_info = nil
      cached_assigned_events = nil
    end
  end

  if not take then
    reaper.ImGui_TextWrapped(ctx, "Select a MIDI item on a track in REAPER to see its notes here.")
    -- Still gives the popup its BeginPopup/EndPopup pair even on this
    -- early return - if a popup was left open when the take disappeared
    -- (e.g. the user deselected the item mid-edit), skipping this call
    -- would leave ReaImGui's popup stack out of sync for a frame.
    note_editor.begin_frame(ctx)
    pending_recompute = note_editor.end_frame(ctx, take)
    return
  end

  if not cached_render_model or #cached_render_model == 0 then
    reaper.ImGui_TextWrapped(ctx, "Selected item has no notes.")
    note_editor.begin_frame(ctx)
    pending_recompute = note_editor.end_frame(ctx, take)
    return
  end

  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local origin_x, origin_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)

  -- Recomputed every frame (cheap) rather than cached, since the Colors
  -- section can change config.color_fg/color_bg at any time - dim is the
  -- shared "secondary ink" shade barlines/measure/tempo labels use, same
  -- one draw_notation.lua/draw_tab.lua derive for their own staff lines/
  -- ties/let-ring (see color_util.lua).
  local color_dim = color_util.dim(config.color_fg, config.color_bg)
  draw_notation.set_colors(config.color_fg, config.color_bg)
  draw_tab.set_colors(config.color_fg, config.color_bg)

  -- Wrapping is a cheap post-process over the already-cached single-line
  -- layout, redone every frame against the current panel width - this is
  -- what makes resize/zoom "just work" with no separate cache-
  -- invalidation trigger (see layout_engine.lua's header). Width comes
  -- from the window's own frame size, NOT GetContentRegionAvail: that
  -- shrinks whenever a vertical scrollbar is showing, which set up a
  -- feedback loop - fewer systems fit -> shorter content -> scrollbar
  -- disappears -> width grows back -> re-wraps into fewer/wider systems
  -- -> taller again -> scrollbar reappears - visible as the whole score
  -- jittering every frame. Window size doesn't change just because our
  -- own content happens to need a scrollbar, so it breaks the loop.
  -- WINDOW_CHROME_RESERVE is a fixed estimate for padding plus a
  -- possible scrollbar, applied unconditionally so the width used for
  -- wrapping never depends on whether one is actually visible this frame.
  local window_w = reaper.ImGui_GetWindowSize(ctx)
  local max_width = math.max(window_w - WINDOW_CHROME_RESERVE - config.layout.right_margin, MIN_SYSTEM_WIDTH)
  local systems = layout_engine.wrap_into_systems(cached_render_model, cached_measure_ticks, max_width)

  -- Score header (title/composer/arranger) and per-system vertical
  -- geometry - shared with pdf_export.lua's print pass via score_render.
  -- lua, see that file's header. geo.top_reserve has to be known before
  -- the systems loop below (every system's own vertical position is
  -- shifted down to make room); the header text itself is drawn after
  -- (needs max_width, already computed above, for centering/right-
  -- alignment - order makes no visual difference, nothing overlaps).
  local geo = score_render.layout_geometry(ctx, config)
  score_render.draw_header(ctx, draw_list, origin_x, origin_y, config, max_width, config.color_fg, color_dim)

  local play_state = reaper.GetPlayState()
  local is_playing = (play_state & 1) == 1
  local play_tick = is_playing and reaper.MIDI_GetPPQPosFromProjTime(take, reaper.GetPlayPosition()) or nil
  local playhead_system_top_y = nil -- local (unscrolled) y, set if the playhead falls within a system this frame

  local total_width = 0

  -- Fresh each frame (it's a stateful forward-pointer, see
  -- notation_model.beat_ticks_lookup), but shared across every system in
  -- this frame's loop rather than one per system - ticks are still
  -- monotonically increasing across systems in order, so one pointer
  -- walk covers the whole piece correctly and cheaply.
  local beat_ticks_lookup = notation_model.beat_ticks_lookup(cached_measure_ticks, cached_measure_info)

  note_editor.begin_frame(ctx)

  for s = 1, #systems do
    local system = systems[s]
    local sys_top_local_y = geo.top_reserve + (s - 1) * geo.system_pitch

    local notation_width, tab_width, bar_top, bar_bottom = score_render.draw_system(
      ctx, draw_list, origin_x, origin_y, sys_top_local_y, config, geo,
      system, s, #systems, cached_measure_info, beat_ticks_lookup, color_dim)

    -- tab_origin_y recomputed here (not returned by draw_system) just for
    -- note_editor.lua's own hit-testing, which is live-view-only - same
    -- formula draw_system uses internally.
    local middle_c_y = origin_y + sys_top_local_y + geo.notation_above
    local tab_origin_y = middle_c_y + geo.notation_below + config.layout.staff_gap
    note_editor.check_system(origin_x, tab_origin_y, system.events)

    total_width = math.max(total_width, notation_width, tab_width)

    if play_tick and play_tick >= system.tick_lo and play_tick < system.tick_hi then
      local playhead_x = origin_x + layout_engine.x_for_tick(system.events, play_tick)
      reaper.ImGui_DrawList_AddLine(draw_list, playhead_x, bar_top, playhead_x, bar_bottom, COLOR_PLAYHEAD, 2.0)
      playhead_system_top_y = sys_top_local_y
    end
  end

  pending_recompute = note_editor.end_frame(ctx, take)

  local total_height = geo.top_reserve + (#systems * geo.system_pitch - config.layout.system_gap) + BOTTOM_MARGIN

  -- Auto-scroll during playback now follows vertically (which system is
  -- active), not horizontally - wrapping already keeps every system
  -- within max_width, so there's rarely anything to scroll sideways to.
  -- Unlike the single-line version's continuous horizontal pinning, this
  -- only scrolls when the active system isn't already fully in view -
  -- jumping straight to a fixed offset every frame would feel wrong for
  -- something as coarse-grained as "which line," rather than the smooth
  -- note-by-note motion horizontal follow had.
  if playhead_system_top_y then
    local current_scroll_y = reaper.ImGui_GetScrollY(ctx)
    local system_bottom_y = playhead_system_top_y + geo.system_pitch

    if geo.system_pitch > avail_h then
      -- The system itself is taller than the visible area - trying to
      -- fit both its top and bottom on screen is impossible, and the two
      -- branches below would otherwise fight each other every frame
      -- (satisfying "top visible" pushes the bottom out of view and vice
      -- versa), which is exactly what showed up as jitter/vibration
      -- during playback. Just pin the top into view instead.
      if playhead_system_top_y ~= current_scroll_y then
        reaper.ImGui_SetScrollY(ctx, playhead_system_top_y)
      end
    elseif playhead_system_top_y < current_scroll_y then
      reaper.ImGui_SetScrollY(ctx, playhead_system_top_y)
    elseif system_bottom_y > current_scroll_y + avail_h then
      reaper.ImGui_SetScrollY(ctx, system_bottom_y - avail_h)
    end
  end

  -- Reserve the space we just drew into via the draw list so the window's
  -- own layout/scrolling accounts for it (the draw list itself doesn't
  -- advance ImGui's cursor).
  reaper.ImGui_Dummy(ctx, total_width, total_height)
end

local WINDOW_FLAGS = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_HorizontalScrollbar()

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, 700, 420, reaper.ImGui_Cond_FirstUseEver())
  -- config.color_bg (ui_chrome.lua's "Colors" section) overrides the
  -- window background for just this window - pushed/popped every frame
  -- since it can change at runtime, unlike a one-time style setup.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), config.color_bg)
  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_TITLE, true, WINDOW_FLAGS)
  if visible then
    main()
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)
  if open then
    reaper.defer(loop)
  end
end

set_toolbar_state(1)
reaper.atexit(on_exit)
reaper.defer(loop)
