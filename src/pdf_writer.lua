-- Minimal, dependency-free PDF file builder - no compression, no embedded
-- fonts (just the standard base-14 fonts, e.g. Helvetica, which every PDF
-- reader already knows how to render without the file carrying glyph
-- data), no advanced features. Just enough vector primitives (lines,
-- circles - approximated as a polygon, PDF has no native circle operator -
-- filled rects, cubic beziers, and text) for pdf_capture.lua to translate
-- this app's existing ImGui draw-list calls into a real, standalone,
-- infinitely-crisp PDF - see pdf_capture.lua's own header for why that's
-- the chosen approach over a screenshot or a separate ASCII renderer.
--
-- PDF's own coordinate system is points (1/72in), origin at the page's
-- BOTTOM-LEFT, Y increasing UPWARD - the opposite of ImGui's top-left/
-- Y-down screen convention this app's drawing code already assumes. This
-- module takes coordinates exactly as given (already-flipped PDF space) -
-- pdf_capture.lua owns that conversion, not this file, so this stays a
-- plain "I know how to emit valid PDF" module with no notation-app
-- knowledge of its own.
--
-- File structure (PDF 1.4, uncompressed): a Catalog object, a Pages tree,
-- one Page + one content-stream object per page, and shared Type1 font
-- objects (registered once, reused by every page that uses them) - see
-- Doc:save for the final assembly (byte-offset xref table + trailer).

local M = {}

local Doc = {}
Doc.__index = Doc

function M.new()
  return setmetatable({
    objects = {},   -- obj id -> body string (without "N 0 obj"/"endobj")
    next_obj = 1,
    pages = {},     -- ordered list of page tables (see new_page)
    font_ids = {},  -- base-14 font name -> obj id, registered once, shared across pages
    current_page = nil,
  }, Doc)
end

function Doc:alloc_obj()
  local id = self.next_obj
  self.next_obj = id + 1
  return id
end

-- Registers (once) a standard base-14 font by name - "Helvetica",
-- "Helvetica-Bold", "Courier", etc. - and returns its object id. No
-- embedding: every PDF reader already ships these, so the object body is
-- just a name reference.
function Doc:get_font(name)
  local id = self.font_ids[name]
  if id then return id end
  id = self:alloc_obj()
  self.objects[id] = string.format("<< /Type /Font /Subtype /Type1 /BaseFont /%s >>", name)
  self.font_ids[name] = id
  return id
end

-- Starts a new page (width/height in points) and makes it the target for
-- every drawing call below until the next new_page. Returns the page
-- table mainly so a caller can track "how many pages so far" if needed;
-- drawing calls don't take it explicitly, they always target
-- self.current_page (matching how pdf_capture.lua is a stateless-per-call
-- shim - it doesn't thread a page handle through the notation app's own
-- draw calls, which have no concept of "pages" at all).
function Doc:new_page(width, height)
  local page = { width = width, height = height, content = {}, fonts_used = {}, obj_id = self:alloc_obj() }
  table.insert(self.pages, page)
  self.current_page = page
  return page
end

local function append(doc, s)
  table.insert(doc.current_page.content, s)
end

local function set_color(doc, r, g, b, op)
  append(doc, string.format("%.3f %.3f %.3f %s", r, g, b, op))
end

function Doc:line(x1, y1, x2, y2, r, g, b, width)
  set_color(self, r, g, b, "RG")
  append(self, string.format("%.2f w", math.max(width, 0.1)))
  append(self, string.format("%.2f %.2f m %.2f %.2f l S", x1, y1, x2, y2))
end

function Doc:bezier(x0, y0, x1, y1, x2, y2, x3, y3, r, g, b, width)
  set_color(self, r, g, b, "RG")
  append(self, string.format("%.2f w", math.max(width, 0.1)))
  append(self, string.format("%.2f %.2f m %.2f %.2f %.2f %.2f %.2f %.2f c S", x0, y0, x1, y1, x2, y2, x3, y3))
end

-- Polygon approximation of a circle (PDF has no native circle/ellipse path
-- operator) - 24 sides is visually indistinguishable from a true circle
-- at the small radii noteheads/dots use, even under print magnification.
local CIRCLE_SEGMENTS = 24
local function circle_path(cx, cy, radius)
  local parts = {}
  for i = 0, CIRCLE_SEGMENTS do
    local ang = (i / CIRCLE_SEGMENTS) * 2 * math.pi
    parts[#parts + 1] = string.format(
      "%.2f %.2f %s", cx + radius * math.cos(ang), cy + radius * math.sin(ang), i == 0 and "m" or "l")
  end
  return table.concat(parts, " ")
end

function Doc:circle_filled(cx, cy, radius, r, g, b)
  set_color(self, r, g, b, "rg")
  append(self, circle_path(cx, cy, radius) .. " f")
end

function Doc:circle_stroke(cx, cy, radius, r, g, b, width)
  set_color(self, r, g, b, "RG")
  append(self, string.format("%.2f w", math.max(width, 0.1)))
  append(self, circle_path(cx, cy, radius) .. " S")
end

-- x1,y1,x2,y2 are two opposite corners (PDF space) in EITHER order -
-- matches ImGui_DrawList_AddRectFilled's own "p_min, p_max" convention,
-- which pdf_capture.lua passes straight through without needing to know
-- which corner is which.
function Doc:rect_filled(x1, y1, x2, y2, r, g, b)
  set_color(self, r, g, b, "rg")
  local x, y = math.min(x1, x2), math.min(y1, y2)
  local w, h = math.abs(x2 - x1), math.abs(y2 - y1)
  append(self, string.format("%.2f %.2f %.2f %.2f re f", x, y, w, h))
end

local function escape_text(s)
  return (s:gsub("[\\%(%)]", "\\%0"))
end

-- x,y is the text BASELINE's start (PDF's own convention) - pdf_capture.
-- lua is responsible for converting from ImGui's top-left-of-text
-- convention before calling this.
function Doc:text(x, y, size, r, g, b, str, font_name)
  font_name = font_name or "Helvetica"
  local font_id = self:get_font(font_name)
  self.current_page.fonts_used[font_name] = font_id
  set_color(self, r, g, b, "rg")
  append(self, string.format("BT /%s %.2f Tf %.2f %.2f Td (%s) Tj ET", font_name, size, x, y, escape_text(str)))
end

-- Assembles every object (pages, content streams, font refs, the Pages
-- tree, the Catalog) into a single valid PDF byte stream with a correct
-- xref table, and writes it to path. Returns true, or false+error message
-- (e.g. an unwritable path) - never throws, so a caller can show the
-- failure in the UI instead of crashing the whole script.
function Doc:save(path)
  local pages_id = self:alloc_obj() -- allocated now so page objects can reference it as /Parent
  local kids = {}

  for _, page in ipairs(self.pages) do
    local stream = table.concat(page.content, "\n")
    local content_id = self:alloc_obj()
    self.objects[content_id] = string.format("<< /Length %d >>\nstream\n%s\nendstream", #stream, stream)

    local font_entries = {}
    for name, id in pairs(page.fonts_used) do
      font_entries[#font_entries + 1] = string.format("/%s %d 0 R", name, id)
    end

    self.objects[page.obj_id] = string.format(
      "<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %.2f %.2f] /Resources << /Font << %s >> >> /Contents %d 0 R >>",
      pages_id, page.width, page.height, table.concat(font_entries, " "), content_id)
    kids[#kids + 1] = page.obj_id .. " 0 R"
  end

  self.objects[pages_id] = string.format("<< /Type /Pages /Kids [%s] /Count %d >>", table.concat(kids, " "), #self.pages)

  local catalog_id = self:alloc_obj()
  self.objects[catalog_id] = string.format("<< /Type /Catalog /Pages %d 0 R >>", pages_id)

  local buf = {}
  local pos = 0
  local offsets = {}
  local function emit(s)
    buf[#buf + 1] = s
    pos = pos + #s
  end

  emit("%PDF-1.4\n")
  for id = 1, self.next_obj - 1 do
    if self.objects[id] then
      offsets[id] = pos
      emit(string.format("%d 0 obj\n%s\nendobj\n", id, self.objects[id]))
    end
  end

  local xref_offset = pos
  local n = self.next_obj - 1
  emit(string.format("xref\n0 %d\n", n + 1))
  emit("0000000000 65535 f \n")
  for id = 1, n do
    emit(string.format("%010d 00000 n \n", offsets[id] or 0))
  end
  emit(string.format("trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n", n + 1, catalog_id, xref_offset))

  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(table.concat(buf))
  f:close()
  return true
end

return M
