--[[
  style.lua — the look of remux (loaded by main.lua, which owns all logic)

  main.lua hands this module plain data ("view models") and gets ASS markup back.
  Nothing in here knows about tracks, ffmpeg or mpv state, so you can restyle the
  menu freely without touching the logic.

  M.menu(vm, sel, first) -> { ass, res_x, res_y, first, box, hits }
      vm = { title, subtitle, badge, items = {...}, issues = {...}, toast, toast_tone }
      sel = index of the highlighted item, first = index of the first visible item
  M.card(c) -> { ass, res_x, res_y }
      c = { title, sub, pct, stats, hint, tone }

  Item kinds (all optional fields besides `kind`):
      section  text, count
      track    label, codec, info, lang, default, forced, delay, name, src, on,
               playing ("1" | "2"), tone, chevron, grabbed (picked up for reordering)
      button   text, detail, tone, chevron                (the Export row)
      action   text, icon ("plus"), detail, chevron
      value    text, value, chevron, cycle                (a setting and its value;
                                                           cycle = ← / → step through values)
      choice   text, detail, checked, chevron             (a plain list entry)
      info     text
      gap
  tone is one of nil | "dim" | "ok" | "warn" | "bad" | "accent".

  Look: follows your shared `menu-*` script-opts (accent_color, bg_color, bg_alpha,
  border_color, border_alpha, text_color, desc_color, font, blur, anchor, margin,
  text_border_color), plus remux.conf: width, anchor, bg_alpha
  (bg_alpha is its own setting, not shared: hex 00-FF, 00 = solid, FF = invisible, default 14,
  which is about 92% opaque; try 30-50 for a more see-through card).
]]

local mp = require "mp"

local M = {}

---------------------------------------------------------------------------
-- Options (set by main.lua via M.configure; this module reads no conf files)
---------------------------------------------------------------------------

local shared = {
    accent_color = "9b5de5", bg_color = "111111",
    border_color = "d4baff", border_alpha = "78",
    text_color = "f2f2f2", desc_color = "9a9a9a",
    text_border_color = "111111",
    font = "", blur = 12, anchor = "top-right", margin = 30,
}

-- bg_alpha is deliberately NOT taken from the shared menu-* opts: those change with your style
-- profiles and can make this card solid. Set it in remux.conf instead
-- (hex 00-FF: 00 solid, FF invisible).
local own = { width = 680, anchor = "", bg_alpha = "14" }

-- Called by main.lua once its options are read. `menu_opts` is the shared menu
-- look (menu.conf / menu-* script-opts); `remux_opts` is its remux table.
function M.configure(menu_opts, remux_opts)
    for key, value in pairs(menu_opts or {}) do
        if shared[key] ~= nil then shared[key] = value end
    end
    own.width = remux_opts.width or own.width
    own.anchor = remux_opts.anchor or ""
    own.bg_alpha = remux_opts.bg_alpha or own.bg_alpha
    if own.anchor ~= "" then shared.anchor = own.anchor end
    shared.bg_alpha = own.bg_alpha
end

local L = shared
local TONE = { ok = "4ADE80", warn = "F5A524", bad = "F87171" }

---------------------------------------------------------------------------
-- Metrics (the canvas is always 720 high, like your other menus)
---------------------------------------------------------------------------

local OUTLINE = 0.7     -- text outline width (keeps text readable over bright video)
local PAD = 18          -- card padding
local INNER = 8         -- extra inset of row content inside the padding
local R_CARD, R_PILL = 14, 9
local H = { section = 30, track = 40, button = 54, action = 38, value = 38, choice = 38, info = 26, gap = 14 }

local function row_h(it) return H[it.kind] or H.action end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function rgb2ass(rgb)
    rgb = tostring(rgb or "ffffff"):gsub("^#", "")
    return (rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)):upper()
end

local function tone_color(tone)
    if tone == "accent" then return L.accent_color end
    if tone == "dim" then return L.desc_color end
    return TONE[tone] or L.text_color
end

local function n(v) return math.floor(v + 0.5) end

local CHAR_PAT = "[\1-\127\194-\244][\128-\191]*"
local function cut(s, max)
    max = math.floor(max)
    if max < 1 then return "" end
    local total = 0
    for _ in s:gmatch(CHAR_PAT) do total = total + 1 end
    if total <= max then return s end
    local out, i = {}, 0
    for ch in s:gmatch(CHAR_PAT) do
        i = i + 1
        if i > max - 1 then break end
        out[i] = ch
    end
    return table.concat(out) .. "…"
end

local function esc(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\239\187\191")
    s = s:gsub("{", "\\{")
    return (s:gsub("\n", "\\N"))
end

local function canvas()
    local w, h = mp.get_osd_size()
    if not w or not h or w <= 0 or h <= 0 then return 1280, 720 end
    return math.floor(720 * w / h + 0.5), 720
end

local function place(cw, ch, w, h)
    local a, m = L.anchor, L.margin
    local x = a:find("left") and m or a:find("right") and (cw - w - m) or math.floor((cw - w) / 2)
    local y = a:find("top") and m or a:find("bottom") and (ch - h - m) or math.floor((ch - h) / 2)
    return x, y
end

---------------------------------------------------------------------------
-- ASS building blocks (own implementation, no mp.assdraw needed)
---------------------------------------------------------------------------

local function new() return { lines = {} } end

local function push(a, s) a.lines[#a.lines + 1] = s end

local function rrect_path(x, y, w, h, r)
    x, y, w, h = n(x), n(y), n(w), n(h)
    r = math.min(r, math.floor(w / 2), math.floor(h / 2))
    local k = r * 0.5523
    local x2, y2 = x + w, y + h
    return string.format(
        "m %d %d l %d %d b %.1f %d %d %.1f %d %d l %d %d b %d %.1f %.1f %d %d %d l %d %d b %.1f %d %d %.1f %d %d l %d %d b %d %.1f %.1f %d %d %d",
        x + r, y, x2 - r, y,
        x2 - r + k, y, x2, y + r - k, x2, y + r,
        x2, y2 - r,
        x2, y2 - r + k, x2 - r + k, y2, x2 - r, y2,
        x + r, y2,
        x + r - k, y2, x, y2 - r + k, x, y2 - r,
        x, y + r,
        x, y + r - k, x + r - k, y, x + r, y)
end

local function rrect_path_rev(x, y, w, h, r)
    x, y, w, h = n(x), n(y), n(w), n(h)
    r = math.max(0, math.min(r, math.floor(w / 2), math.floor(h / 2)))
    local k = r * 0.5523
    local x2, y2 = x + w, y + h
    return string.format(
        "m %d %d b %.1f %d %d %.1f %d %d l %d %d b %d %.1f %.1f %d %d %d l %d %d b %.1f %d %d %.1f %d %d l %d %d b %d %.1f %.1f %d %d %d l %d %d",
        x + r, y,
        x + r - k, y, x, y + r - k, x, y + r,
        x, y2 - r,
        x, y2 - r + k, x + r - k, y2, x + r, y2,
        x2 - r, y2,
        x2 - r + k, y2, x2, y2 - r + k, x2, y2 - r,
        x2, y + r,
        x2, y + r - k, x2 - r + k, y, x2 - r, y,
        x + r, y)
end

-- a 1-wide frame: outer outline clockwise + inner outline counter-clockwise
local function ring_path(x, y, w, h, r, t)
    return rrect_path(x, y, w, h, r) .. " " .. rrect_path_rev(x + t, y + t, w - 2 * t, h - 2 * t, r - t)
end

-- a filled/stroked vector shape. o: fill (rgb), fa (alpha hex), stroke (rgb), sa, sw, blur
local function shape(a, path, o)
    local iclip = o.iclip and string.format("\\iclip(%d,%d,%d,%d)", o.iclip[1], o.iclip[2], o.iclip[3], o.iclip[4]) or ""
    push(a, string.format("{\\an7\\pos(0,0)\\shad0\\blur%s\\bord%s\\1c&H%s&\\3c&H%s&\\1a&H%s&\\3a&H%s&%s\\p1}%s{\\p0}",
        o.blur or 0, o.sw or 0, rgb2ass(o.fill or "000000"), rgb2ass(o.stroke or o.fill or "000000"),
        o.fa or "00", o.sa or "00", iclip, path))
end

local function rect(a, x, y, w, h, r, o) shape(a, rrect_path(x, y, w, h, r or 0), o) end

-- text. o: size, color, bold, italic, an (default 4 = left/middle), alpha, clip, spacing, raw
local function text(a, x, y, s, o)
    local clip = o.clip and string.format("\\clip(%d,%d,%d,%d)", o.clip[1], o.clip[2], o.clip[3], o.clip[4]) or ""
    push(a, string.format("{\\an%d\\pos(%d,%d)%s\\fs%d\\b%d\\i%d\\fsp%s\\shad0\\bord%s\\3c&H%s&\\1c&H%s&\\1a&H%s&\\3a&H%s&\\blur0%s}%s",
        o.an or 4, n(x), n(y), L.font ~= "" and ("\\fn" .. L.font) or "", n(o.size or 17), o.bold and 1 or 0,
        o.italic and 1 or 0, o.spacing or 0, OUTLINE, rgb2ass(L.text_border_color),
        rgb2ass(o.color or L.text_color), o.alpha or "00", o.alpha or "00", clip, o.raw and s or esc(s)))
end

local function check_path(x, y, s)
    local f = s / 16
    local function p(px, py) return string.format("%.1f %.1f", x + px * f, y + py * f) end
    return string.format("m %s l %s l %s l %s l %s l %s", p(1.8, 9.4), p(3.4, 7.8), p(6.4, 10.8), p(12.6, 4.4), p(14.2, 6.0), p(6.4, 14.0))
end

local function chevron_path(x, y)
    local function p(px, py) return string.format("%.1f %.1f", x + px, y + py) end
    return string.format("m %s l %s l %s l %s l %s l %s", p(0, 0), p(1.8, 0), p(6.2, 5), p(1.8, 10), p(0, 10), p(4.4, 5))
end

local function chevron_left_path(x, y)
    local function p(px, py) return string.format("%.1f %.1f", x + px, y + py) end
    return string.format("m %s l %s l %s l %s l %s l %s", p(6.2, 0), p(4.4, 0), p(0, 5), p(4.4, 10), p(6.2, 10), p(1.8, 5))
end

local function arrow_path(x, y, up)
    if up then return string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f", x + 4.5, y, x + 9, y + 6, x, y + 6) end
    return string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f", x, y, x + 9, y, x + 4.5, y + 6)
end

local function plus_path(x, y, s)
    local t, m = 2, s / 2
    local function p(px, py) return string.format("%.1f %.1f", x + px, y + py) end
    return string.format("m %s l %s l %s l %s l %s l %s l %s l %s l %s l %s l %s l %s",
        p(m - t / 2, 0), p(m + t / 2, 0), p(m + t / 2, m - t / 2), p(s, m - t / 2), p(s, m + t / 2), p(m + t / 2, m + t / 2),
        p(m + t / 2, s), p(m - t / 2, s), p(m - t / 2, m + t / 2), p(0, m + t / 2), p(0, m - t / 2), p(m - t / 2, m - t / 2))
end

local function triangle_path(x, y, w, h)
    return string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f", x, y, x + w, y + h / 2, x, y + h)
end

---------------------------------------------------------------------------
-- Card chrome
---------------------------------------------------------------------------

local function card_bg(a, x, y, w, h)
    -- Drawn the plain way on purpose: a solid fill with only its own alpha, and the border as a
    -- separate thin ring. (No blur, no drop shadow, no stroke on the fill: those rendered as solid
    -- black underneath the card in mpv and made it look opaque however low bg_alpha was set.)
    rect(a, x, y, w, h, R_CARD, { fill = L.bg_color, fa = L.bg_alpha })
    shape(a, ring_path(x, y, w, h, R_CARD, 1), { fill = L.border_color, fa = L.border_alpha })
end

local function divider(a, x, y, w)
    rect(a, x, y, w, 1, 0, { fill = L.border_color, fa = "C8" })
end

---------------------------------------------------------------------------
-- Row renderers
---------------------------------------------------------------------------

local function draw_pill(a, rx, ry, rw, rh, strong, grabbed)
    if grabbed then
        rect(a, rx + 2, ry + 2, rw - 4, rh - 4, R_PILL,
            { fill = L.accent_color, fa = "48", stroke = "FFFFFF", sa = "28", sw = 1.6 })
        return
    end
    rect(a, rx + 2, ry + 2, rw - 4, rh - 4, R_PILL,
        { fill = L.accent_color, fa = strong and "78" or "98", stroke = L.accent_color, sa = "30", sw = 1 })
end

local function draw_stepper(a, rx, rw, mid, alpha)
    local x = rx + rw - INNER - 34
    shape(a, chevron_left_path(x, mid - 5), { fill = L.desc_color, fa = alpha or "20" })
    shape(a, chevron_path(x + 18, mid - 5), { fill = L.desc_color, fa = alpha or "20" })
end

local function draw_chevron(a, rx, rw, mid, alpha)
    shape(a, chevron_path(rx + rw - INNER - 8, mid - 5), { fill = L.desc_color, fa = alpha or "20" })
end

local function draw_track(a, it, rx, ry, rw, selected)
    local mid = ry + H.track / 2
    local ix = rx + INNER + 4
    local alpha = it.on and "00" or "A0"
    local base = it.tone and tone_color(it.tone) or L.text_color

    if it.playing then
        shape(a, triangle_path(ix, mid - 5, 8, 10), { fill = TONE.ok, fa = it.playing == "2" and "70" or "00" })
    end
    -- checkbox
    local bx, bs = ix + 18, 16
    if it.on then
        local box = it.tone == "bad" and TONE.bad or it.tone == "warn" and TONE.warn or L.accent_color
        rect(a, bx, mid - bs / 2, bs, bs, 4, { fill = box })
        shape(a, check_path(bx, mid - bs / 2, bs), { fill = "FFFFFF" })
    else
        rect(a, bx + 1, mid - bs / 2 + 1, bs - 2, bs - 2, 3, { fill = "000000", fa = "FF", stroke = L.desc_color, sa = "40", sw = 1.4 })
    end

    local cx = ix + 46
    local right = rx + rw - INNER - 22
    text(a, cx, mid, it.label, { size = 17, bold = true, color = base, alpha = alpha })
    text(a, cx + 36, mid, cut(it.codec or "", 9), { size = 16, color = base, alpha = alpha, clip = { cx + 36, ry, cx + 36 + 86, ry + H.track } })
    if it.info and it.info ~= "" then
        text(a, cx + 128, mid, cut(it.info, 12), { size = 14, color = L.desc_color, alpha = alpha,
            clip = { cx + 128, ry, cx + 128 + 92, ry + H.track } })
    end
    text(a, cx + 226, mid, it.lang ~= "" and it.lang or "-", { size = 14, color = it.lang ~= "" and L.text_color or L.desc_color, alpha = alpha })

    -- D / F tags
    local tx = cx + 266
    for _, tag in ipairs({ { it.default, "D" }, { it.forced, "F" } }) do
        if tag[1] then
            rect(a, tx, mid - 9, 19, 18, 5, { fill = L.accent_color, fa = it.on and "98" or "C8", stroke = L.accent_color, sa = "40", sw = 1 })
            text(a, tx + 9.5, mid, tag[2], { size = 12, bold = true, an = 5, alpha = alpha })
            tx = tx + 23
        end
    end
    if it.delay and it.delay ~= "" then
        text(a, cx + 316, mid, it.delay, { size = 13, color = L.accent_color, alpha = alpha })
    end

    local nx = cx + 372
    local label = it.name or ""
    local room = math.max(0, right - nx)
    if label ~= "" then
        text(a, nx, mid, label, { size = 14, color = L.text_color, alpha = alpha, clip = { nx, ry, right, ry + H.track } })
    elseif it.src then
        text(a, nx, mid, it.src, { size = 13, italic = true, color = L.desc_color, alpha = alpha, clip = { nx, ry, right, ry + H.track } })
    end
    if it.grabbed then
        local ax = rx + rw - INNER - 20
        shape(a, arrow_path(ax, mid - 11, true), { fill = "FFFFFF" })
        shape(a, arrow_path(ax, mid + 5, false), { fill = "FFFFFF" })
    elseif it.chevron then
        draw_chevron(a, rx, rw, mid, alpha)
    end
end

local function draw_button(a, it, rx, ry, rw, selected)
    local bad = it.tone == "bad"
    local fill = bad and "5B1F24" or L.accent_color
    rect(a, rx + 2, ry + 3, rw - 4, H.button - 8, 12, {
        fill = fill, fa = bad and "30" or (selected and "00" or "40"),
        stroke = selected and "FFFFFF" or (bad and TONE.bad or L.border_color), sa = selected and "20" or "60", sw = selected and 1.6 or 1 })
    local mid = ry + H.button / 2 - 1
    local ix = rx + INNER + 8
    text(a, ix, mid, it.text, { size = 19, bold = true, color = bad and TONE.bad or "FFFFFF" })
    local detail_x = rx + rw - INNER - (it.chevron and 28 or 12)
    if it.detail and it.detail ~= "" then
        text(a, detail_x, mid, cut(it.detail, 34), { size = 13, an = 6, color = bad and "F3B4B4" or "E9DDFB", alpha = "10",
            clip = { ix + 150, ry, detail_x, ry + H.button } })
    end
    if it.chevron then shape(a, chevron_path(rx + rw - INNER - 10, mid - 5), { fill = "FFFFFF", fa = "30" }) end
end

local function draw_line_item(a, it, rx, ry, rw, selected)
    local h = row_h(it)
    local mid = ry + h / 2
    local ix = rx + INNER + 8
    local base = tone_color(it.tone)
    local right = rx + rw - INNER - (it.cycle and 46 or it.chevron and 24 or 8)
    local tx = ix
    if it.icon == "plus" then
        shape(a, plus_path(ix, mid - 6, 12), { fill = L.accent_color })
        tx = ix + 24
    end
    text(a, tx, mid, it.text, { size = selected and 18 or 17, color = base, bold = selected,
        clip = { tx, ry, right, ry + h } })
    local val = it.value or it.detail
    if val and val ~= "" then
        local size = it.kind == "choice" and 13 or 15
        local rr = right
        if it.checked then rr = right - 26 end
        text(a, rr, mid, cut(val, 44), { size = size, an = 6, color = L.desc_color, italic = false, clip = { tx + 120, ry, rr, ry + h } })
    end
    if it.checked then
        local cr = rx + rw - INNER - (it.chevron and 40 or 24)
        shape(a, check_path(cr, mid - 8, 16), { fill = L.accent_color })
    end
    if it.cycle then draw_stepper(a, rx, rw, mid) elseif it.chevron then draw_chevron(a, rx, rw, mid) end
end

local function draw_section(a, it, rx, ry, rw)
    local mid = ry + H.section / 2 + 3
    local label = (it.text or ""):upper()
    text(a, rx + INNER + 8, mid, label, { size = 12, bold = true, color = L.desc_color, spacing = 1.6, alpha = "10" })
    if it.count then
        text(a, rx + INNER + 8 + (#label * 9) + 14, mid, tostring(it.count), { size = 12, color = L.desc_color, alpha = "50" })
    end
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

function M.menu(vm, sel, first)
    local cw, ch = canvas()
    local W = math.min(own.width, cw - 2 * L.margin)
    local items = vm.items

    -- footer lines: the toast first, then problems
    local foot = {}
    if vm.toast and vm.toast ~= "" then foot[#foot + 1] = { text = vm.toast, tone = vm.toast_tone, bold = true } end
    for _, is in ipairs(vm.issues or {}) do
        if is.level ~= "info" and #foot < 3 then
            foot[#foot + 1] = { text = is.text, tone = is.level == "block" and "bad" or "warn", dot = true }
        end
    end
    local head_h = vm.subtitle and 58 or 44
    local foot_h = #foot > 0 and (#foot * 24 + 16) or 0
    local avail = ch - 2 * L.margin - 2 * PAD - head_h - foot_h

    local function last_of(f)
        local h, l = 0, f - 1
        for i = f, #items do
            local hh = row_h(items[i])
            if h + hh > avail then break end
            h = h + hh; l = i
        end
        return l
    end
    first = math.max(1, math.min(first or 1, math.max(1, #items)))
    if sel < first then
        first = sel
        if items[first - 1] and items[first - 1].kind == "section" then first = first - 1 end
    end
    while first < sel and sel > last_of(first) do first = first + 1 end
    while first > 1 do -- show as much as fits when scrolled to the end
        local h = 0
        for i = first - 1, #items do h = h + row_h(items[i]) end
        if h > avail then break end
        first = first - 1
    end
    local last = last_of(first)
    local rows_h = 0
    for i = first, last do rows_h = rows_h + row_h(items[i]) end

    local Hc = 2 * PAD + head_h + rows_h + foot_h
    local x, y = place(cw, ch, W, Hc)
    local rx, rw = x + PAD, W - 2 * PAD
    local a = new()
    card_bg(a, x, y, W, Hc)

    -- header
    local hy = y + PAD
    text(a, rx + INNER + 8, hy + (vm.subtitle and 14 or 20), vm.title, { size = 21, bold = true, color = "FFFFFF" })
    if vm.subtitle then
        text(a, rx + INNER + 8, hy + 38, cut(vm.subtitle, 70), { size = 13, color = L.desc_color,
            clip = { rx + INNER + 8, hy, rx + rw - INNER - 90, hy + head_h } })
    end
    if vm.badge then
        local bw = 14 + #vm.badge * 9
        rect(a, rx + rw - INNER - bw, hy + 6, bw, 24, 8, { fill = L.accent_color, fa = "70", stroke = L.accent_color, sa = "20", sw = 1 })
        text(a, rx + rw - INNER - bw / 2, hy + 18, vm.badge, { size = 13, bold = true, an = 5, spacing = 1 })
    end
    divider(a, rx + INNER + 8, hy + head_h - 6, rw - 2 * INNER - 16)

    -- rows
    local hits = {}
    local cy = y + PAD + head_h
    for i = first, last do
        local it = items[i]
        local hh = row_h(it)
        local selected = (i == sel)
        local kind = it.kind
        if kind == "section" then
            draw_section(a, it, rx, cy, rw)
        elseif kind == "info" then
            text(a, rx + INNER + 8, cy + hh / 2, it.text or "", { size = 13, italic = true, color = L.desc_color,
                clip = { rx, cy, rx + rw, cy + hh } })
        elseif kind == "gap" then
            divider(a, rx + INNER + 8, cy + hh / 2, rw - 2 * INNER - 16)
        else
            if (selected or it.grabbed) and kind ~= "button" then draw_pill(a, rx, cy, rw, hh, kind == "track", it.grabbed) end
            if kind == "track" then draw_track(a, it, rx, cy, rw, selected)
            elseif kind == "button" then draw_button(a, it, rx, cy, rw, selected)
            else draw_line_item(a, it, rx, cy, rw, selected) end
            hits[#hits + 1] = { y1 = cy, y2 = cy + hh, idx = i }
        end
        cy = cy + hh
    end

    -- scrollbar
    if first > 1 or last < #items then
        local ty0, th0 = y + PAD + head_h + 4, rows_h - 8
        rect(a, x + W - 9, ty0, 3, th0, 1, { fill = L.border_color, fa = "C8" })
        local span = last - first + 1
        local th = math.max(20, th0 * span / #items)
        local tyy = ty0 + (th0 - th) * (first - 1) / math.max(1, #items - span)
        rect(a, x + W - 9, tyy, 3, th, 1, { fill = L.accent_color })
    end

    -- footer
    if #foot > 0 then
        local fy = cy + 4
        divider(a, rx + INNER + 8, fy, rw - 2 * INNER - 16)
        for i, f in ipairs(foot) do
            local ly = fy + 18 + (i - 1) * 24
            local col = tone_color(f.tone)
            local tx = rx + INNER + 8
            if f.dot then
                rect(a, tx, ly - 4, 8, 8, 4, { fill = col })
                tx = tx + 18
            end
            text(a, tx, ly, f.text, { size = 14, bold = f.bold, color = col, clip = { tx, ly - 12, rx + rw - INNER, ly + 12 } })
        end
    end

    return {
        ass = table.concat(a.lines, "\n"), res_x = cw, res_y = ch, first = first,
        box = { x = x, y = y, w = W, h = Hc }, hits = hits,
    }
end

---------------------------------------------------------------------------
-- Progress card
---------------------------------------------------------------------------

function M.card(c)
    local cw, ch = canvas()
    local W, Hc = math.min(480, cw - 2 * L.margin), 120
    local x, y = place(cw, ch, W, Hc)
    local ix, iw = x + PAD + INNER + 4, W - 2 * (PAD + INNER + 4)
    local col = tone_color(c.tone or "accent")
    local a = new()
    card_bg(a, x, y, W, Hc)
    text(a, ix, y + 26, c.title, { size = 13, bold = true, color = col, spacing = 1.5 })
    if c.hint then text(a, ix + iw, y + 26, c.hint, { size = 13, an = 6, color = L.desc_color }) end
    text(a, ix, y + 52, cut(c.sub or "", 40), { size = 18, bold = true, color = "FFFFFF", clip = { ix, y, ix + iw, y + Hc } })
    if c.pct then
        rect(a, ix, y + 74, iw, 6, 3, { fill = "FFFFFF", fa = "D8" })
        if iw * c.pct >= 6 then rect(a, ix, y + 74, iw * c.pct, 6, 3, { fill = col }) end
    end
    if c.stats then
        text(a, ix, y + 98, c.stats, { size = 14, color = L.desc_color, clip = { ix, y, ix + iw, y + Hc } })
    end
    return { ass = table.concat(a.lines, "\n"), res_x = cw, res_y = ch }
end

return M
