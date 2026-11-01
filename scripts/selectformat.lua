-- Name: mpv-selectformat
-- Author: koonix <me@koonix.org>
-- Upstream: https://github.com/koonix/mpv-selectformat
-- Version: 1.0.7
-- License: MIT

local script_name = "selectformat"

-- ====================
-- = requires
-- ====================

mp.msg = require("mp.msg")
mp.utils = require("mp.utils")
mp.options = require("mp.options")
mp.assdraw = require("mp.assdraw")

-- ====================
-- = declarations
-- ====================

local function main() end
local function formats_save(url, result) end
local function formats_fold(width, height, audio_only) end
local function menu_toggle() end
local function menu_show() end
local function menu_init_vars() end
local function menu_init_sel_pos() end
local function menu_hide() end
local function menu_draw() end
local function menu_get_prefix(pos) end
local function menu_get_indent_marker(pos) end
local function menu_keys_bind() end
local function menu_keys_unbind() end
local function menu_cursor_move(i) end
local function menu_unfold() end
local function menu_fold() end
local function get_unfolded_cursor_fmt_id() end
local function get_cursor_pos() end
local function get_selected_pos() end
local function get_parent_of_selected_pos() end
local function get_format_id_pos(id) end
local function menu_select() end
local function no_formats_available() end
local function build_ytdl_format_str(fmt) end
local function build_format_label(fmt) end
local function get_menu_header() end
local function strfmt_label(...) end
local function format_sort_fn(a, b) end
local function get_param_precedence(param, value) end
local function is_format_useful(fmt) end
local function sanitize_format(fmt) end
local function is_format_audio_only(fmt) end
local function is_param_valid(p) end
local function is_param_empty(p) end
local function update_url() end
local function numshorten(n) end
local function sigcmp(a, operator, b) end
local function is_network_stream(path) end
local function reload_resume() end
local function isempty(v) end
local function isnum(v) end
local function isstr(v) end
local function istable(v) end

-- ====================
-- = options
-- ====================

local opts = {
	prioritize_proto = true,
	exclude_ai_upscaled = true,
	-- Prefer audio at 70 kbps or below for videos up to this resolution.
	-- Uses the shorter dimension, so portrait and landscape videos behave alike.
	-- Set to 0 to disable.
	lower_quality_audio = 720,
	prefix_header = "  ", -- a non-breaking space followed by a space
	prefix_norm = "  ", -- a non-breaking space followed by a space
	prefix_cursor = "● ",
	prefix_norm_sel = "○ ",
	prefix_indent = "  ",
	header_separator = "─",
	-- Compensate when the separator glyph renders wider than the menu font.
	-- 1.0 uses one glyph per header character; lower values shorten the line.
	separator_scale = 0.75,
	menu_pos_x = 7,
	menu_pos_y = 15,
	ass_style = "{\\fnmonospace\\fs10}",
}
mp.options.read_options(opts, script_name)

-- ====================
-- = keys
-- ====================

local keys = {
	{
		{ "UP", "k", "WHEEL_UP" },
		"up",
		function()
			menu_cursor_move(-1)
		end,
		{ repeatable = true },
	},
	{
		{ "DOWN", "j", "WHEEL_DOWN" },
		"down",
		function()
			menu_cursor_move(1)
		end,
		{ repeatable = true },
	},
	{
		{ "PGUP", "ctrl+u" },
		"pgup",
		function()
			menu_cursor_move(-5)
		end,
		{ repeatable = true },
	},
	{
		{ "PGDWN", "ctrl+d" },
		"pgdwn",
		function()
			menu_cursor_move(5)
		end,
		{ repeatable = true },
	},
	{
		{ "HOME", "g" },
		"top",
		function()
			menu_cursor_move("top")
		end,
	},
	{
		{ "END", "G" },
		"bottom",
		function()
			menu_cursor_move("bottom")
		end,
	},
	{
		{ "RIGHT", "l" },
		"unfold",
		function()
			menu_unfold()
		end,
	},
	{
		{ "LEFT", "h" },
		"fold",
		function()
			menu_fold()
		end,
	},
	{
		{ "ESC", "q", "MBTN_RIGHT" },
		"quit",
		function()
			menu_hide()
		end,
	},
	{
		{ "ENTER", "MBTN_LEFT" },
		"select",
		function()
			menu_select()
		end,
	},
}

-- ====================
-- = globals
-- ====================

local data = {}
local url = ""
local is_menu_shown = false
local chosen = {} -- url -> ytdl-format string picked in the menu
-- ====================
-- = functions
-- ====================

function main()
	-- Apply the format picked in the menu to this one file only, before
	-- mpv's ytdl_hook (priority 10) resolves the URL. This leaves the
	-- global `ytdl-format` from mpv.conf untouched.
	mp.add_hook("on_load", 9, function()
		local path = mp.get_property("path")
		local fmt = path and chosen[path]
		if fmt then
			mp.set_property("file-local-options/ytdl-format", fmt)
		end
	end)

	-- Reuse the JSON that ytdl_hook already fetched instead of spawning
	-- a second yt-dlp process.
	mp.observe_property(
		"user-data/mpv/ytdl/json-subprocess-result",
		"native",
		function(_, result)
			if not result then
				return -- property is cleared again on end-file
			end
			if update_url() then
				formats_save(url, result)
			end
		end
	)

	mp.register_event("end-file", menu_hide)
	mp.add_key_binding("y", "menu", menu_toggle)
end

function formats_save(url, result)
	data[url] = nil

	if
		not istable(result)
		or result.status ~= 0
		or isempty(result.stdout)
	then
		return
	end

	local json = mp.utils.parse_json(result.stdout)

	if (not istable(json)) or (not istable(json.formats)) then
		return
	end

	data[url] = { formats = {} }
	data[url].initial_format_id = json.format_id

	for _, fmt in ipairs(json.formats) do
		if is_format_useful(fmt) then
			fmt = sanitize_format(fmt)
			---@diagnostic disable: inject-field
			fmt.label = build_format_label(fmt)
			fmt.ytdl_format = build_ytdl_format_str(fmt)
			---@diagnostic enable: inject-field
			table.insert(data[url].formats, fmt)
		end
	end

	if no_formats_available() then
		return
	end

	table.sort(data[url].formats, format_sort_fn)
	data[url].formats_unfolded = data[url].formats
	formats_fold()
end

function formats_fold(width, height, audio_only)
	data[url].formats = {}
	local inserted_res = {}
	local unfold_res = (width or "null") .. "x" .. (height or "null")
	for _, fmt in ipairs(data[url].formats_unfolded) do
		local res = (fmt.width or "") .. "x" .. (fmt.height or "")

		if res == "x" then
			res = is_format_audio_only(fmt) and "audio-only" or fmt.format_id
		end

		fmt.is_unfolded = false

		local fmt_audio_only = is_format_audio_only(fmt)
		if
			not inserted_res[res]
			or res == unfold_res
			or (audio_only and res == "audio-only")
		then
			inserted_res[res] = true

			if res == unfold_res or (audio_only and res == "audio-only") then
				fmt.is_unfolded = true
			end

			table.insert(data[url].formats, fmt)
		end
	end
end

function menu_toggle()
	mp.options.read_options(opts, script_name)

	if not update_url() then
		mp.osd_message("Formats are only fetched for internet videos.")
		return
	end

	if is_menu_shown then
		menu_hide()
	else
		menu_show()
	end
end

function menu_show()
	if no_formats_available() then
		mp.osd_message("No formats available.")
		return
	end
	is_menu_shown = true
	menu_init_vars()
	menu_draw()
	menu_keys_bind()
end

function menu_init_vars()
	if data[url].cursor_fmt_id == nil or data[url].selected_fmt_id == nil then
		data[url].cursor_fmt_id = data[url].formats[1].format_id
		data[url].selected_fmt_id = "UNSELECTED"
		menu_init_sel_pos()
	end
end

function menu_init_sel_pos()
	local id = data[url].initial_format_id

	if isempty(id) or not isstr(id) then
		return
	end

	id = id:match("^(.*)%+") or id

	for idx, fmt in ipairs(data[url].formats_unfolded) do
		if fmt.format_id == id then
			data[url].selected_fmt_id = fmt.format_id
		end
	end
end

function menu_hide()
	if is_menu_shown then
		is_menu_shown = false
		mp.set_osd_ass(0, 0, "")
		menu_keys_unbind()
	end
end

function menu_draw()
	if not is_menu_shown or no_formats_available() then
		return
	end

	local ass = mp.assdraw.ass_new()
	local header = get_menu_header()

	-- Count UTF-8 characters rather than bytes (the prefix contains a NBSP).
	-- The scale compensates for separator glyphs that render wider than the font.
	local separator_text = opts.prefix_header .. header
	local _, separator_chars = separator_text:gsub("[^\128-\191]", "")
	local separator_len = math.max(
		0,
		math.floor(separator_chars * opts.separator_scale + 0.5)
	)
	local header_separator = string.rep(opts.header_separator, separator_len)

	ass:pos(opts.menu_pos_x, opts.menu_pos_y)
	ass:append(opts.ass_style)
	ass:append(
		opts.prefix_header .. header .. "\\N" .. header_separator .. "\\N"
	)

	for idx, fmt in ipairs(data[url].formats) do
		ass:append(menu_get_prefix(idx))
		ass:append(menu_get_indent_marker(idx))
		ass:append(fmt.label .. "\\N")
	end

	mp.set_osd_ass(0, 0, ass.text)
end

function menu_get_prefix(pos)
	if pos == get_cursor_pos() then
		return opts.prefix_cursor
	elseif pos == get_selected_pos() then
		return opts.prefix_norm_sel
	elseif
		not data[url].formats[pos].is_unfolded
		and pos == get_parent_of_selected_pos()
	then
		return opts.prefix_norm_sel
	else
		return opts.prefix_norm
	end
end

function menu_get_indent_marker(pos)
	if data[url].formats[pos].is_unfolded then
		return opts.prefix_indent
	else
		return ""
	end
end

function menu_keys_bind()
	for _, v in ipairs(keys) do
		for i, key in ipairs(v[1]) do
			mp.add_forced_key_binding(key, v[2] .. i, v[3], v[4])
		end
	end
end

function menu_keys_unbind()
	for _, v in ipairs(keys) do
		for i in ipairs(v[1]) do
			mp.remove_key_binding(v[2] .. i)
		end
	end
end

function menu_cursor_move(i)
	if i == "top" then
		data[url].cursor_fmt_id = data[url].formats[1].format_id
	elseif i == "bottom" then
		data[url].cursor_fmt_id =
			data[url].formats[#data[url].formats].format_id
	else
		local pos = get_cursor_pos() + i

		if pos < 1 then
			pos = 1
		elseif pos > #data[url].formats then
			pos = #data[url].formats
		end

		data[url].cursor_fmt_id = data[url].formats[pos].format_id
	end

	menu_draw()
end

function menu_unfold()
	local cursor_fmt = data[url].formats[get_cursor_pos()]
	formats_fold(
		cursor_fmt.width,
		cursor_fmt.height,
		is_format_audio_only(cursor_fmt)
	)
	menu_draw()
end

function menu_fold()
	data[url].cursor_fmt_id = get_unfolded_cursor_fmt_id()
	formats_fold()
	menu_draw()
end

function get_unfolded_cursor_fmt_id()
	local function getres(fmt)
		if is_format_audio_only(fmt) then
			return "audio-only"
		else
			return (fmt.width or "null") .. "x" .. (fmt.height or "null")
		end
	end

	local cursor_fmt = data[url].formats[get_cursor_pos()]

	if cursor_fmt.is_unfolded then
		local cursor_res = ""

		for i = #data[url].formats, 1, -1 do
			local fmt = data[url].formats[i]

			if cursor_fmt.format_id == fmt.format_id then
				cursor_res = getres(fmt)
			end

			if cursor_res ~= "" and getres(fmt) ~= cursor_res then
				return data[url].formats[i + 1].format_id
			end

			if i == 1 then
				return fmt.format_id
			end
		end
	end

	return data[url].cursor_fmt_id
end

function get_cursor_pos()
	for idx, fmt in ipairs(data[url].formats) do
		if data[url].cursor_fmt_id == fmt.format_id then
			return idx
		end
	end

	return 0
end

function get_selected_pos()
	for idx, fmt in ipairs(data[url].formats) do
		if data[url].selected_fmt_id == fmt.format_id then
			return idx
		end
	end

	return 0
end

function get_parent_of_selected_pos()
	local function getres(fmt)
		if is_format_audio_only(fmt) then
			return "audio-only"
		else
			return (fmt.width or "null") .. "x" .. (fmt.height or "null")
		end
	end

	local sel_res = ""

	for i = #data[url].formats_unfolded, 1, -1 do
		local ufmt = data[url].formats_unfolded[i]

		if data[url].selected_fmt_id == ufmt.format_id then
			sel_res = getres(ufmt)
		end

		if sel_res ~= "" and getres(ufmt) ~= sel_res then
			return get_format_id_pos(
				data[url].formats_unfolded[i + 1].format_id
			)
		end

		if i == 1 then
			return 1
		end
	end

	return 0
end

function get_format_id_pos(id)
	for idx, fmt in ipairs(data[url].formats) do
		if id == fmt.format_id then
			return idx
		end
	end
	return 0
end

function menu_select()
	menu_hide()

	local d = data[url]
	local fmt = d.formats[get_cursor_pos()]

	-- nothing to do if the format is already the active one
	if not fmt or d.selected_fmt_id == fmt.format_id then
		return
	end

	d.selected_fmt_id = fmt.format_id
	chosen[url] = fmt.ytdl_format
	reload_resume()
end

function no_formats_available()
	return not istable(data[url])
		or not istable(data[url].formats)
		or #data[url].formats == 0
end

function build_format_label(fmt)
	local res, codec, br

	if is_format_audio_only(fmt) then
		res = "audio-only"
		codec = fmt.acodec
		br = fmt.abr or fmt.tbr
	else
		res = (fmt.width or "?") .. "x" .. (fmt.height or "?")
		codec = fmt.vcodec
		br = fmt.vbr or fmt.tbr
	end

	if codec then
		codec =
			codec:gsub("av01", "av1"):gsub("avc1", "h264"):gsub("h265", "hevc")
	end

	return strfmt_label(
		res,
		fmt.fps and numshorten(fmt.fps) or "",
		codec or "",
		br and numshorten(br * 10 ^ 3) or "",
		fmt.asr and numshorten(fmt.asr) or "",
		fmt.protocol or ""
	)
end

function get_menu_header()
	return strfmt_label("Resolution", "FPS", "Codec", "BR", "ASR", "Proto")
end

function strfmt_label(...)
	return string.format("%-10s %-3s %-5s %-4s %-4s %s", ...)
end

function build_ytdl_format_str(fmt)
	if is_format_audio_only(fmt) then
		return string.format("%s/bestaudio", fmt.format_id)
	else
		local audiofmt = "bestaudio"

		local w, h = tonumber(fmt.width) or 0, tonumber(fmt.height) or 0
		local short_edge = w > 0 and h > 0 and math.min(w, h) or math.max(w, h)
		local audio_resolution_limit = tonumber(opts.lower_quality_audio) or 0

		if audio_resolution_limit > 0 and short_edge > 0 and short_edge <= audio_resolution_limit then
			audiofmt = "bestaudio[abr<=70]"
		end

		return string.format(
			"%s+%s/%s+bestaudio/%s/best",
			fmt.format_id,
			audiofmt,
			fmt.format_id,
			fmt.format_id
		)
	end
end

function format_sort_fn(a, b)
	local params

	if opts.prioritize_proto then
		params = {
			"fps",
			"dynamic_range",
			"vcodec",
			"acodec",
			"protocol",
			"tbr",
			"vbr",
			"abr",
			"asr",
		}
	else
		params = {
			"fps",
			"dynamic_range",
			"vcodec",
			"acodec",
			"tbr",
			"vbr",
			"abr",
			"asr",
			"protocol",
		}
	end

	a.res = (a.width or 1) * (a.height or 1)
	b.res = (b.width or 1) * (b.height or 1)

	if a.res > b.res then
		return true
	elseif a.res < b.res then
		return false
	end

	for _, v in ipairs({ 1, 2 }) do
		for _, p in ipairs(params) do
			local do_sigcmp

			if v == 1 and isnum(a[p]) and isnum(b[p]) then
				do_sigcmp = true
			else
				do_sigcmp = false
			end

			local x = isnum(a[p]) and a[p] or get_param_precedence(p, a[p])
			local y = isnum(b[p]) and b[p] or get_param_precedence(p, b[p])

			if do_sigcmp then
				if sigcmp(x, ">", y) then
					return true
				elseif sigcmp(x, "<", y) then
					return false
				end
			else
				if x > y then
					return true
				elseif x < y then
					return false
				end
			end
		end
	end

	return a.format_id > b.format_id
end

function get_param_precedence(param, value)
	local order = {
		dynamic_range = {
			{ "sdr" },
			{ "^$" },
			{ "hlg" },
			{ "h?d?r?10$" },
			{ "h?d?r?10%+" },
			{ "h?d?r?12" },
			{ "dv" },
		},
		vcodec = {
			{ "theora" },
			{ "mp4v", "h263" },
			{ "vp0?8" },
			{ "[hx]264", "avc" },
			{ "[hx]265", "he?vc" },
			{ "vp0?9$" },
			{ "vp0?9%.2" },
			{ "av0?1" },
		},
		acodec = {
			{ "dts" },
			{ "^ac%-?3" },
			{ "e%-?a?c%-?3" },
			{ "mp3" },
			{ "mp?4a?" },
			{ "avc" },
			{ "vorbis", "ogg" },
			{ "opus" },
		},
		protocol = {
			{ "f4" },
			{ "ws", "websocket$" },
			{ "mms", "rtsp" },
			{ "^$" },
			{ "rtmpe?" },
			{ "websocket_frag" },
			{ ".*dash" },
			{ "m3u8.*" },
			{ "http$", "ftp$" },
			{ "https", "ftps" },
		},
	}

	if isempty(order[param]) then
		return tonumber(value) or 0
	elseif isempty(value) then
		value = ""
	end

	local n = 1

	for _, patternlist in ipairs(order[param]) do
		for _, pattern in ipairs(patternlist) do
			if value:lower():find(pattern) then
				return n
			end
		end
		n = n + 1
	end

	return 0
end

function is_format_useful(fmt)
	if (not istable(fmt)) or fmt.ext == "mhtml" or fmt.protocol == "mhtml" then
		return false
	end

	if
		opts.exclude_ai_upscaled
		and type(fmt.format_note) == "string"
		and fmt.format_note:find("AI%-upscaled")
	then
		return false
	end

	local params = {
		"format_id",
		"vcodec",
		"acodec",
		"width",
		"height",
		"vbr",
		"abr",
		"tbr",
	}

	for _, p in ipairs(params) do
		if is_param_valid(fmt[p]) then
			return true
		end
	end

	return false
end

function sanitize_format(fmt)
	local numeric_params = {
		"width",
		"height",
		"fps",
		"tbr",
		"vbr",
		"abr",
		"asr",
		"filesize",
		"filesize_approx",
	}

	local string_params = {
		"format_id",
		"dynamic_range",
		"vcodec",
		"acodec",
		"protocol",
		"language",
	}

	for _, p in ipairs(numeric_params) do
		if is_param_empty(fmt[p]) then
			fmt[p] = nil
		elseif isstr(fmt[p]) then
			fmt[p] = tonumber(fmt[p])
		elseif not isnum(fmt[p]) then
			fmt[p] = nil
		end
	end

	for _, p in ipairs(string_params) do
		if is_param_empty(fmt[p]) then
			fmt[p] = nil
		elseif isnum(fmt[p]) then
			fmt[p] = tostring(fmt[p])
		elseif not isstr(fmt[p]) then
			fmt[p] = nil
		end
	end

	fmt.vcodec = fmt.vcodec and fmt.vcodec:gsub("%..*", "") or nil
	fmt.acodec = fmt.acodec and fmt.acodec:gsub("%..*", "") or nil

	return fmt
end

function is_format_audio_only(fmt)
	return (is_param_valid(fmt.acodec) and (not is_param_valid(fmt.vcodec)))
		or (
			is_param_valid(fmt.audio_ext)
			and (not is_param_valid(fmt.video_ext))
		)
end

function is_param_valid(p)
	return isnum(p) or (isstr(p) and (not is_param_empty(p)))
end

function is_param_empty(p)
	return isempty(p) or p == "none" or p == "null"
end

function update_url()
	local path = mp.get_property("path")
	if isstr(path) and is_network_stream(path) then
		url = path
		return true
	else
		return false
	end
end

function numshorten(n)
	n = math.floor(n + 0.5)
	if n >= 10 ^ 9 then
		return string.format("%dG", n / 10 ^ 9)
	elseif n >= 10 ^ 6 then
		return string.format("%dM", n / 10 ^ 6)
	elseif n >= 10 ^ 3 then
		return string.format("%dK", n / 10 ^ 3)
	else
		return string.format("%d", n)
	end
end

function sigcmp(a, operator, b)
	local fraction = 0.15
	if operator == ">" and a > b + (a * fraction) then
		return true
	elseif operator == "<" and a + (b * fraction) < b then
		return true
	else
		return false
	end
end

function is_network_stream(path)
	local proto = path:match("^(%a+)://")

	if not proto then
		return false
	end

	for _, p in ipairs({
		"http",
		"https",
		"ytdl",
		"rtmp",
		"rtmps",
		"rtmpe",
		"rtmpt",
		"rtmpts",
		"rtmpte",
		"rtsp",
		"rtsps",
		"mms",
		"mmst",
		"mmsh",
		"mmshttp",
		"rtp",
		"srt",
		"srtp",
		"gopher",
		"gophers",
		"data",
		"ftp",
		"ftps",
		"sftp",
	}) do
		if proto == p then
			return true
		end
	end

	return false
end

function reload_resume()
	local timepos = mp.get_property_number("time-pos")
	local duration = mp.get_property_number("duration")

	-- Only restore the position for VOD. Live streams have no fixed start
	-- and should come back at their live edge.
	if timepos and duration and duration > 0 then
		local function seeker()
			mp.commandv("seek", timepos, "absolute+exact")
			mp.unregister_event(seeker)
		end
		mp.register_event("file-loaded", seeker)
	end

	-- Re-open the current entry in place; the playlist is left untouched.
	-- The on_load hook above applies the chosen format.
	mp.command("playlist-play-index current")
end

function isempty(v)
	return v == nil or v == ""
end

function isnum(v)
	return type(v) == "number"
end

function isstr(v)
	return type(v) == "string"
end

function istable(v)
	return type(v) == "table"
end

main()

-- vim:noexpandtab