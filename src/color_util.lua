-- Shared RGBA (0xRRGGBBAA, ReaImGui's packed format) color helpers for the
-- user-configurable background/foreground palette (config.color_bg/
-- color_fg, set via ui_chrome.lua's "Colors" section). M.dim derives a
-- single "secondary ink" shade part-way from foreground toward background,
-- so staff/tab lines, barlines, measure/tempo labels, ties, and let-ring
-- markings keep reading as visually secondary to noteheads/stems/text
-- without needing their own user-facing color option - the same relative
-- hierarchy this app already had with its old hardcoded grays, just
-- derived from whatever two colors are currently chosen.

local M = {}

function M.blend(a, b, t)
  local ar, ag, ab, aa = (a >> 24) & 0xFF, (a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF
  local br, bg, bb, ba = (b >> 24) & 0xFF, (b >> 16) & 0xFF, (b >> 8) & 0xFF, b & 0xFF
  local r = math.floor(ar + (br - ar) * t + 0.5)
  local g = math.floor(ag + (bg - ag) * t + 0.5)
  local bl = math.floor(ab + (bb - ab) * t + 0.5)
  local al = math.floor(aa + (ba - aa) * t + 0.5)
  return (r << 24) | (g << 16) | (bl << 8) | al
end

function M.dim(fg, bg)
  return M.blend(fg, bg, 0.35)
end

return M
