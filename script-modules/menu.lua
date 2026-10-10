------------------------------------------------------------
-- Menu: drawing + behaviour for list menus in mpv scripts.
--
--   local Menu = require("menu")
--   local menu = Menu:new({ items = { "Plain", { text = "Styled", desc = "note", checked = true } } })
--   menu.on_select = function(self, index, item) ... end      -- Enter / click / number key
--   menu.on_cancel = function(self) ... end                   -- Esc / right click / click outside / timeout
--   menu.on_move   = function(self, index, item) ... end      -- cursor moved (keys, wheel, hover, filter): live preview
--   menu:open{ timeout = 15, filter = false }                 -- binds keys, draws; open's table is merged into the menu
--   menu:close()
--
-- Items: "string" or a table { text, desc, font, bold, italic, color, checked, disabled }.
--   { header = "Title" } is a non-selectable heading, { separator = true } a thin line.
--   `selected` is the cursor row, `active` (optional) the row drawn as "current".
-- Drawing only (no key handling): :draw() :erase() :render() :move(d) :up() :down() :set_position(x, y)
-- An instance can be a prototype: `local child = menu:new{ items = ... }` inherits look, keys and methods.
--
-- STYLE. Every option in SCHEMA below is resolved, lowest to highest priority, from:
--   1. built-in defaults
--   2. the named theme (Menu.themes[theme]; "default" is the purple look). Add your own: Menu.themes.mine = {...}
--   3. the shared style for every script, script-opts:      menu-<option>=value       (or script-opts/menu.conf)
--   4. values given in code (Menu:new{...} or fields on the instance)
--   5. the per-script override, script-opts:  <script>-menu_<option>=value   (script = script name, or `name` field)
-- e.g. in mpv.conf:   script-opts-append=menu-accent_color=9b5de5
--                     script-opts-append=autosubsync-menu_accent_color=ff6b71
-- Colours are RGB hex ("ffffff"); alphas are ASS alpha hex ("00" solid ... "ff" invisible). The look follows
-- script-opts live, so applying a profile restyles an open menu on its next redraw.

local mp = require("mp")
local assdraw = require("mp.assdraw")
local options = require("mp.options")

local Menu = {}
Menu.__index = Menu

---------------------------------------------------------------------------
-- Style schema + themes
---------------------------------------------------------------------------

local function opt(default, kind) return { default = default, type = kind } end

local SCHEMA = {
    theme = opt("", "string"),                -- named theme (see above)
    anchor = opt("top-right", "string"),      -- top-left top-right bottom-left bottom-right top bottom left right center
    pos_x = opt(nil, "number"),               -- explicit card position (canvas units); beats the anchor per axis
    pos_y = opt(nil, "number"),
    margin = opt(30, "number"),               -- distance from the window edge when anchored
    canvas_height = opt(720, "number"),       -- drawing units; the width follows the window's aspect ratio
    rect_width = opt(460, "number"),          -- card width
    rect_height = opt(48, "number"),          -- row pitch
    pill_height = opt(40, "number"),          -- highlight height inside a row
    padding = opt(15, "number"),              -- card edge -> rows
    text_inset = opt(15, "number"),           -- row edge -> text
    radius = opt(12, "number"),               -- card corner radius
    pill_radius = opt(8, "number"),
    max_rows = opt(9, "number"),              -- more rows scroll (fewer if the window is short)

    bg_color = opt("111111", "string"),
    bg_alpha = opt("90", "string"),
    border_color = opt("666666", "string"),
    border_alpha = opt("60", "string"),
    accent_color = opt("ffffff", "string"),
    blur = opt(10, "number"),                 -- soft card edges
    shadow = opt(0, "number"),
    pill_border_alpha = opt("40", "string"),  -- cursor pill: accent outline ...
    pill_fill_alpha = opt("88", "string"),    -- ... over a bg_color fill
    active_bg_color = opt("000000", "string"),-- "current" row background
    active_bg_alpha = opt("AA", "string"),

    text_color = opt("ffffff", "string"),     -- item colour when it has none of its own
    text_border_color = opt("111111", "string"),
    text_border = opt(1.5, "number"),
    font = opt(nil, "string"),                -- unset = the OSD font
    font_size = opt(19, "number"),
    font_size_selected = opt(21, "number"),
    bold = opt(false, "boolean"),
    italic = opt(false, "boolean"),
    desc_color = opt("AAAAAA", "string"),     -- descriptions and headers
    desc_font = opt(nil, "string"),
    desc_size = opt(14, "number"),
    disabled_alpha = opt("80", "string"),
    separator_color = opt("ffffff", "string"),
    separator_alpha = opt("D0", "string"),

    scrollbar = opt(true, "boolean"),
    scrollbar_width = opt(3, "number"),
    hover = opt(true, "boolean"),             -- the mouse moves the cursor
    number_keys = opt(true, "boolean"),       -- 1-9 pick the nth visible row
}

Menu.themes = {
    default = { bg_color = "111111", bg_alpha = "90", border_color = "d4baff", border_alpha = "60",
                accent_color = "9b5de5", blur = 15, shadow = 0 },
}

local function convert(text, kind)
    if kind == "number" then return tonumber(text) end
    if kind == "boolean" then
        text = text:lower()
        return text == "yes" or text == "true" or text == "1" or text == "on"
    end
    return text
end

-- Options set in script-opts / script-opts/<identifier>.conf, as { option = value } (unset ones are absent).
-- Shared style: identifier "menu", option names as is. Per script: identifier = script name, names prefixed "menu_".
local layer_cache = {}

local function get_layer(identifier, prefixed)
    local sig = mp.get_property("options/script-opts") or ""
    local cache_key = identifier .. (prefixed and "#own" or "#shared")
    local cached = layer_cache[cache_key]
    if cached and cached.sig == sig then return cached.values end

    local prefix = prefixed and "menu_" or ""
    local raw = {}
    for key in pairs(SCHEMA) do raw[prefix .. key] = "" end -- string defaults: "" means "not set"
    options.read_options(raw, identifier)

    local values = {}
    for key, def in pairs(SCHEMA) do
        local text = raw[prefix .. key]
        if text ~= nil and text ~= "" then values[key] = convert(tostring(text), def.type) end
    end
    layer_cache[cache_key] = { sig = sig, values = values }
    return values
end

local function resolve(self)
    local shared = get_layer("menu", false)
    local own = get_layer(self.name or mp.get_script_name(), true)
    local theme = Menu.themes[own.theme or self.theme or shared.theme or "default"] or Menu.themes.default

    local style = {}
    for key, def in pairs(SCHEMA) do
        local v = own[key]
        if v == nil then v = self[key] end
        if v == nil then v = shared[key] end
        if v == nil then v = theme[key] end
        if v == nil then v = def.default end
        style[key] = v
    end
    return style
end

-- The resolved look of this menu.
function Menu:style()
    return resolve(self)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function hex6(code, fallback)
    code = tostring(code or ""):gsub("^[#!]", "")
    return code:match("^%x%x%x%x%x%x$") and code or fallback
end

-- RGB hex -> ASS colour "&HBBGGRR&"
local function ass_color(code, fallback)
    code = hex6(code, fallback or "FFFFFF")
    return "&H" .. code:sub(5, 6) .. code:sub(3, 4) .. code:sub(1, 2) .. "&"
end

local function ass_alpha(alpha, fallback)
    alpha = tostring(alpha or ""):gsub("[&Hh#]", "")
    return "&H" .. (alpha:match("^%x%x$") and alpha or fallback) .. "&"
end

local function escape(text)
    text = tostring(text)
    local escaped = mp.command_native({ "escape-ass", text })
    return type(escaped) == "string" and escaped or text
end

local function kind_of(item)
    if type(item) == "table" then
        if item.separator then return "separator" end
        if item.header then return "header" end
        if item.disabled then return "disabled" end
    end
    return "item"
end

local function selectable(item)
    return item ~= nil and item ~= false and kind_of(item) == "item"
end

local VALID_ANCHORS = {
    ["top-left"] = true, ["top-right"] = true, ["bottom-left"] = true, ["bottom-right"] = true,
    top = true, bottom = true, left = true, right = true, center = true,
}

local function place(anchor, cw, ch, w, h, margin)
    if not VALID_ANCHORS[anchor] then anchor = "top-right" end
    local x, y
    if anchor:find("left") then x = margin elseif anchor:find("right") then x = cw - w - margin
    else x = math.floor((cw - w) / 2) end
    if anchor:find("top") then y = margin elseif anchor:find("bottom") then y = ch - h - margin
    else y = math.floor((ch - h) / 2) end
    return x, y
end

---------------------------------------------------------------------------
-- Construction + items
---------------------------------------------------------------------------

function Menu:new(o)
    o = o or {}
    if self == Menu then -- a root menu gets its state; children inherit everything from their parent instance
        o.items = o.items or {}
        o.selected = o.selected or 1
    end
    self.__index = self
    return setmetatable(o, self)
end

function Menu:set_position(x, y)
    self.pos_x = x
    self.pos_y = y
end

-- Indices of the items shown right now (everything, or what matches the filter query).
function Menu:visible()
    local query = (self.query or ""):lower()
    local out = {}
    for i, item in ipairs(self.items) do
        if query == "" then
            out[#out + 1] = i
        elseif kind_of(item) == "item" or kind_of(item) == "disabled" then
            local text = type(item) == "table" and ((item.text or "") .. " " .. (item.desc or "")) or tostring(item)
            if text:lower():find(query, 1, true) then out[#out + 1] = i end
        end
    end
    return out
end

-- Visible items the cursor can stop on.
function Menu:selectable_list()
    local out = {}
    for _, i in ipairs(self:visible()) do
        if selectable(self.items[i]) then out[#out + 1] = i end
    end
    return out
end

function Menu:first_selectable()
    return self:selectable_list()[1]
end

-- Make sure the cursor is on a visible, selectable row (0 when there is none).
function Menu:fix_selection()
    local first, ok
    for _, i in ipairs(self:selectable_list()) do
        first = first or i
        if i == self.selected then ok = true end
    end
    if not ok then self.selected = first or 0 end
end

function Menu:set_items(items)
    self.items = items or {}
    self.query = self.filter and "" or nil
    self:fix_selection()
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

-- ASS text for the current state; also records the geometry used for mouse hit-testing.
function Menu:render()
    local R = resolve(self)
    local items = self.items
    local vis = self:visible()
    local filtering = self.filter and true or false
    if #vis == 0 and not filtering then
        self._hit = nil
        return ""
    end

    local ch = R.canvas_height
    local osd_w, osd_h = mp.get_osd_size()
    local cw = self.canvas_width
    if not cw then
        if osd_w and osd_h and osd_w > 0 and osd_h > 0 then
            cw = math.floor(ch * osd_w / osd_h + 0.5)
        else
            cw = math.floor(ch * 16 / 9 + 0.5)
        end
    end
    self._cw, self._ch = cw, ch

    local fit = math.floor((ch - 2 * R.margin - 2 * R.padding) / R.rect_height)
    local cap = math.max(3, math.min(R.max_rows, fit))
    if filtering then cap = math.max(1, cap - 1) end
    local rows = math.min(#vis, cap)

    local sel_pos = 1
    for pos, idx in ipairs(vis) do
        if idx == self.selected then sel_pos = pos break end
    end
    local first = math.max(1, math.min(sel_pos - math.floor(rows / 2), #vis - rows + 1))

    local function height_at(pos)
        local item = items[vis[pos]]
        if type(item) == "table" and item.separator then return math.floor(R.rect_height / 2) end
        return R.rect_height
    end
    local list_h = 0
    for pos = first, first + rows - 1 do list_h = list_h + height_at(pos) end
    if rows == 0 then list_h = R.rect_height end -- "No matches" row
    local filter_h = filtering and R.rect_height or 0

    local card_w = R.rect_width
    local card_h = R.padding * 2 + filter_h + list_h
    local x, y = place(R.anchor, cw, ch, card_w, card_h, R.margin)
    if R.pos_x then x = R.pos_x end
    if R.pos_y then y = R.pos_y end

    local row_w = card_w - R.padding * 2
    local row_x = x + R.padding
    local pill_h = R.pill_height
    local accent = ass_color(R.accent_color)
    local bg = ass_color(R.bg_color)
    local desc_font = R.desc_font or mp.get_property("osd-font") or "sans-serif"
    local font_tag = R.font and ("\\fn" .. R.font) or ""

    local ass = assdraw.ass_new()

    -- Card background
    ass:new_event()
    ass:pos(x, y)
    ass:append(string.format("{\\bord1.5\\3c%s\\3a%s\\1c%s\\1a%s\\shad%g\\blur%g\\4a&HFF&}",
        ass_color(R.border_color), ass_alpha(R.border_alpha, "60"), bg, ass_alpha(R.bg_alpha, "90"), R.shadow, R.blur))
    ass:draw_start()
    ass:round_rect_cw(0, 0, card_w, card_h, R.radius)
    ass:draw_stop()

    local cy = y + R.padding

    -- Filter line
    if filtering then
        local query = self.query or ""
        ass:new_event()
        ass:pos(row_x + R.text_inset, cy + math.floor(pill_h / 2))
        ass:an(4)
        if query == "" then
            ass:append(string.format("{\\q2%s\\b0\\i1\\fs%g\\1c%s\\bord0\\shad0\\blur0}Type to filter",
                font_tag, R.font_size, ass_color(R.desc_color, "AAAAAA")))
        else
            ass:append(string.format("{\\q2%s\\b0\\i0\\fs%g\\1c%s\\bord%g\\3c%s\\shad0\\blur0}%s{\\1c%s}|",
                font_tag, R.font_size, ass_color(R.text_color), R.text_border, ass_color(R.text_border_color, "111111"),
                escape(query), accent))
        end
        cy = cy + filter_h
    end

    local list_y = cy
    local hits = {}

    if rows == 0 then
        ass:new_event()
        ass:pos(row_x + R.text_inset, cy + math.floor(pill_h / 2))
        ass:an(4)
        ass:append(string.format("{\\q2%s\\b0\\i1\\fs%g\\1c%s\\bord0\\shad0\\blur0}No matches",
            font_tag, R.font_size, ass_color(R.desc_color, "AAAAAA")))
    end

    for pos = first, first + rows - 1 do
        local idx = vis[pos]
        local raw = items[idx]
        local item = type(raw) == "table" and raw or { text = raw }
        local kind = kind_of(raw)
        local eh = height_at(pos)
        local mid = cy + math.floor(pill_h / 2)

        if kind == "separator" then
            ass:new_event()
            ass:pos(row_x, cy + math.floor(eh / 2))
            ass:append(string.format("{\\bord0\\1c%s\\1a%s\\shad0\\blur0\\4a&HFF&}",
                ass_color(R.separator_color), ass_alpha(R.separator_alpha, "D0")))
            ass:draw_start()
            ass:rect_cw(0, 0, row_w, 1)
            ass:draw_stop()
        elseif kind == "header" then
            ass:new_event()
            ass:pos(row_x + R.text_inset, mid)
            ass:an(4)
            ass:append(string.format("{\\q2%s\\b1\\i0\\fs%g\\1c%s\\bord0\\shad0\\blur0}%s",
                font_tag, R.desc_size + 1, ass_color(R.desc_color, "AAAAAA"),
                escape(type(item.header) == "string" and item.header or item.text or "")))
        else
            local is_cursor = (kind == "item" and idx == self.selected)
            local is_active = (idx == self.active)

            if is_cursor then
                ass:new_event()
                ass:pos(row_x, cy)
                ass:append(string.format("{\\bord1\\3c%s\\3a%s\\1c%s\\1a%s\\shad0\\blur0\\4a&HFF&}",
                    accent, ass_alpha(R.pill_border_alpha, "40"), bg, ass_alpha(R.pill_fill_alpha, "88")))
                ass:draw_start()
                ass:round_rect_cw(0, 0, row_w, pill_h, R.pill_radius)
                ass:draw_stop()
            elseif is_active then
                ass:new_event()
                ass:pos(row_x, cy)
                ass:append(string.format("{\\bord0\\1c%s\\1a%s\\shad0\\blur0\\4a&HFF&}",
                    ass_color(R.active_bg_color), ass_alpha(R.active_bg_alpha, "AA")))
                ass:draw_start()
                ass:round_rect_cw(0, 0, row_w, pill_h, R.pill_radius)
                ass:draw_stop()
            end

            if is_active then
                ass:new_event()
                ass:pos(row_x, mid - 12)
                ass:append(string.format("{\\bord0\\1c%s\\1a&H00&\\shad0\\blur2\\4a&HFF&}", accent))
                ass:draw_start()
                ass:round_rect_cw(0, 0, 4, 24, 2)
                ass:draw_stop()
            end

            local font = item.font and ("\\fn" .. item.font) or font_tag
            local bold, italic = item.bold, item.italic
            if bold == nil then bold = R.bold end
            if italic == nil then italic = R.italic end
            local dim = kind == "disabled" and string.format("\\1a%s\\3a%s",
                ass_alpha(R.disabled_alpha, "80"), ass_alpha(R.disabled_alpha, "80")) or ""

            ass:new_event()
            ass:pos(row_x + R.text_inset, mid)
            ass:an(4)
            ass:append(string.format("{\\q2%s\\b%d\\i%d\\fs%g\\1c%s\\bord%g\\3c%s%s\\shad0\\blur0}%s",
                font, bold and 1 or 0, italic and 1 or 0, is_cursor and R.font_size_selected or R.font_size,
                ass_color(item.color or R.text_color), R.text_border, ass_color(R.text_border_color, "111111"),
                dim, escape(item.text or "")))
            if item.desc and item.desc ~= "" then
                ass:append(string.format(" {\\fn%s\\b0\\i1\\fs%g\\1c%s\\bord1}  %s",
                    desc_font, R.desc_size, ass_color(R.desc_color, "AAAAAA"), escape(item.desc)))
            end

            if item.checked then
                ass:new_event()
                ass:pos(row_x + row_w - R.text_inset, mid)
                ass:an(6)
                ass:append(string.format("{\\q2\\b0\\i0\\fs%g\\1c%s\\bord0\\shad0\\blur0}\226\156\147", R.font_size, accent))
            end
        end

        hits[#hits + 1] = { y1 = cy, y2 = cy + eh, idx = (kind == "item") and idx or nil }
        cy = cy + eh
    end

    -- Scrollbar
    if R.scrollbar and #vis > rows and rows > 0 then
        local bar_w = R.scrollbar_width
        local bar_x = x + card_w - math.floor(R.padding / 2) - bar_w
        local thumb_h = math.max(18, math.floor(list_h * rows / #vis))
        local thumb_y = list_y + math.floor((list_h - thumb_h) * (first - 1) / math.max(1, #vis - rows))
        ass:new_event()
        ass:pos(bar_x, list_y)
        ass:append(string.format("{\\bord0\\1c%s\\1a&HE0&\\shad0\\blur0\\4a&HFF&}", accent))
        ass:draw_start()
        ass:round_rect_cw(0, 0, bar_w, list_h, bar_w / 2)
        ass:draw_stop()
        ass:new_event()
        ass:pos(bar_x, thumb_y)
        ass:append(string.format("{\\bord0\\1c%s\\1a&H30&\\shad0\\blur0\\4a&HFF&}", accent))
        ass:draw_start()
        ass:round_rect_cw(0, 0, bar_w, thumb_h, bar_w / 2)
        ass:draw_stop()
    end

    self._hit = { x = x, y = y, w = card_w, h = card_h, rows = hits, count = rows,
                  cw = cw, ch = ch, osd_w = osd_w, osd_h = osd_h }
    return ass.text
end

function Menu:draw()
    local text = self:render()
    mp.set_osd_ass(self._cw or 1280, self._ch or 720, text)
end

function Menu:erase()
    mp.set_osd_ass(self._cw or 1280, self._ch or 720, "")
end

---------------------------------------------------------------------------
-- Cursor movement (pure: no redraw, no callbacks)
---------------------------------------------------------------------------

local function index_of(list, value)
    for k, v in ipairs(list) do
        if v == value then return k end
    end
end

-- Move to the next/previous selectable row, wrapping. Returns the new row.
function Menu:move(delta)
    local list = self:selectable_list()
    local n = #list
    if n == 0 then return self.selected end
    local cur = index_of(list, self.selected) or (delta > 0 and 0 or n + 1)
    self.selected = list[(cur - 1 + delta) % n + 1]
    return self.selected
end

-- Move by `delta` selectable rows without wrapping (paging).
function Menu:jump_by(delta)
    local list = self:selectable_list()
    local n = #list
    if n == 0 then return self.selected end
    local cur = index_of(list, self.selected) or (delta > 0 and 0 or n + 1)
    self.selected = list[math.max(1, math.min(n, cur + delta))]
    return self.selected
end

function Menu:jump_to(which)
    local list = self:selectable_list()
    if #list == 0 then return self.selected end
    self.selected = (which == "last") and list[#list] or list[1]
    return self.selected
end

function Menu:up()
    self:move(-1)
    self:draw()
end

function Menu:down()
    self:move(1)
    self:draw()
end

---------------------------------------------------------------------------
-- Interaction: open / close, keys, mouse, filter
---------------------------------------------------------------------------

local DEFAULT_KEYS = {
    up = { "UP", "k", "WHEEL_UP" },
    down = { "DOWN", "j", "WHEEL_DOWN" },
    page_up = { "PGUP" },
    page_down = { "PGDWN" },
    first = { "HOME" },
    last = { "END" },
    confirm = { "ENTER", "KP_ENTER" },
    cancel = { "ESC", "q", "MBTN_RIGHT" },
    click = { "MBTN_LEFT" },
}

-- While filtering, letters are text: no k/j/q.
local FILTER_KEYS = {
    up = { "UP", "WHEEL_UP" },
    down = { "DOWN", "WHEEL_DOWN" },
    page_up = DEFAULT_KEYS.page_up,
    page_down = DEFAULT_KEYS.page_down,
    first = DEFAULT_KEYS.first,
    last = DEFAULT_KEYS.last,
    confirm = DEFAULT_KEYS.confirm,
    cancel = { "ESC", "MBTN_RIGHT" },
    click = DEFAULT_KEYS.click,
}

local ACTIONS = { "up", "down", "page_up", "page_down", "first", "last", "confirm", "cancel", "click" }
local REPEATABLE = { up = true, down = true, page_up = true, page_down = true }

local next_id = 0

function Menu:is_open()
    return self._open == true
end

function Menu:_touch()
    if self._timer then
        self._timer:kill()
        self._timer = nil
    end
    if self._open and self.timeout and self.timeout > 0 then
        self._timer = mp.add_timeout(self.timeout, function()
            if self._open then self:cancel() end
        end)
    end
end

-- After the cursor changed: tell the owner (live preview), redraw, restart the idle timeout.
function Menu:_moved()
    if self.on_move and self.selected and self.selected > 0 then
        self:on_move(self.selected, self.items[self.selected])
    end
    self:draw()
    self:_touch()
end

function Menu:confirm()
    local idx = self.selected
    local item = idx and idx > 0 and self.items[idx]
    if not selectable(item) then return end
    if self.close_on_select ~= false then self:close() end
    if self.on_select then self:on_select(idx, item) end
end

function Menu:cancel()
    local was_open = self._open
    self:close()
    if was_open and self.on_cancel then self:on_cancel() end
end

-- Row under the mouse: (item index or nil, whether the pointer is inside the card)
function Menu:row_at_mouse()
    local hit = self._hit
    local mouse = mp.get_property_native("mouse-pos")
    if not hit or type(mouse) ~= "table" or not mouse.x or not mouse.y then return nil, false end
    local osd_w, osd_h = hit.osd_w or 0, hit.osd_h or 0
    if osd_w <= 0 or osd_h <= 0 then osd_w, osd_h = hit.cw, hit.ch end
    local mx, my = mouse.x * hit.cw / osd_w, mouse.y * hit.ch / osd_h
    if mx < hit.x or mx > hit.x + hit.w or my < hit.y or my > hit.y + hit.h then return nil, false end
    for _, row in ipairs(hit.rows) do
        if my >= row.y1 and my < row.y2 then return row.idx, true end
    end
    return nil, true
end

function Menu:_hover()
    local idx = self:row_at_mouse()
    if idx == self._last_hover then return end
    self._last_hover = idx
    if idx and idx ~= self.selected then
        self.selected = idx
        self:_moved()
    end
end

function Menu:_click()
    local idx, inside = self:row_at_mouse()
    if idx then
        if idx ~= self.selected then
            self.selected = idx
            if self.on_move then self:on_move(idx, self.items[idx]) end
        end
        self:confirm()
    elseif not inside and self.click_outside ~= "ignore" then
        self:cancel()
    end
end

-- Number key n: the nth selectable row currently on screen.
function Menu:_number(n)
    local hit = self._hit
    if not hit then return end
    local count = 0
    for _, row in ipairs(hit.rows) do
        if row.idx then
            count = count + 1
            if count == n then
                if row.idx ~= self.selected then
                    self.selected = row.idx
                    if self.on_move then self:on_move(row.idx, self.items[row.idx]) end
                end
                return self:confirm()
            end
        end
    end
end

function Menu:_type(text)
    self.query = (self.query or "") .. text
    self:fix_selection()
    self:_moved()
end

function Menu:_backspace()
    local query = self.query or ""
    if query == "" then return end
    self.query = query:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
    self:fix_selection()
    self:_moved()
end

function Menu:open(opts)
    opts = opts or {}
    if self._open then self:close() end

    local wanted = opts.selected
    for k, v in pairs(opts) do
        if k ~= "selected" then self[k] = v end
    end
    layer_cache = {}

    self.query = self.filter and "" or nil
    self.selected = wanted or self:first_selectable() or 0
    self:fix_selection()
    self._open = true
    self._last_hover = nil
    self._bound = {}

    next_id = next_id + 1
    local id = next_id
    local function bind(key, name, fn, flags)
        local bound_name = string.format("menu_%d_%s_%s", id, name, key)
        mp.add_forced_key_binding(key, bound_name, fn, flags)
        self._bound[#self._bound + 1] = bound_name
    end

    local function step(fn)
        return function()
            if not self._open then return end
            fn()
            self:_moved()
        end
    end
    local handlers = {
        up = step(function() self:move(-1) end),
        down = step(function() self:move(1) end),
        page_up = step(function() self:jump_by(-(self._hit and self._hit.count or 9)) end),
        page_down = step(function() self:jump_by(self._hit and self._hit.count or 9) end),
        first = step(function() self:jump_to("first") end),
        last = step(function() self:jump_to("last") end),
        confirm = function() if self._open then self:confirm() end end,
        click = function() if self._open then self:_click() end end,
        cancel = function()
            if not self._open then return end
            if self.filter and (self.query or "") ~= "" then -- first Esc clears the filter
                self.query = ""
                self:fix_selection()
                self:_moved()
            else
                self:cancel()
            end
        end,
    }

    local defaults = self.filter and FILTER_KEYS or DEFAULT_KEYS
    for _, action in ipairs(ACTIONS) do
        local keys = (self.keys and self.keys[action]) or defaults[action] or {}
        for _, key in ipairs(keys) do
            local repeatable = REPEATABLE[action] and not key:find("^WHEEL") or false
            bind(key, action, handlers[action], repeatable and { repeatable = true } or nil)
        end
    end

    local R = resolve(self)
    if R.hover then
        bind("MOUSE_MOVE", "hover", function() if self._open then self:_hover() end end)
    end
    if R.number_keys and not self.filter then
        for n = 1, 9 do
            bind(tostring(n), "number", function() if self._open then self:_number(n) end end)
        end
    end
    if self.filter then
        bind("BS", "backspace", function() if self._open then self:_backspace() end end, { repeatable = true })
        bind("any_unicode", "text", function(info)
            if self._open and type(info) == "table" and info.key_text and info.key_text ~= ""
                and (info.event == "press" or info.event == "down" or info.event == "repeat") then
                self:_type(info.key_text)
            end
        end, { repeatable = true, complex = true })
    end

    self._observer = function()
        if self._open then self:draw() end
    end
    mp.observe_property("osd-dimensions", "native", self._observer)

    self:draw()
    self:_touch()
end

function Menu:close()
    if not self._open then return end
    self._open = false
    if self._timer then
        self._timer:kill()
        self._timer = nil
    end
    for _, name in ipairs(self._bound or {}) do mp.remove_key_binding(name) end
    self._bound = nil
    if self._observer then
        mp.unobserve_property(self._observer)
        self._observer = nil
    end
    self:erase()
end

return Menu
