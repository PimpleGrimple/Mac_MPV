local mp = require("mp")
local utils = require("mp.utils")
local display_protocol = os.getenv("XDG_SESSION_TYPE")

local options = {
    copy_keybind = [[ ["ctrl+c", "meta+c"] ]],
    paste_keybind = [[ ["ctrl+v", "meta+v"] ]],
    copy_sub_keybind = [[ ["ctrl+C", "meta+C"] ]],
    open_keybind = "o",

    linux_copy_command = { "xclip", "-silent", "-selection", "clipboard", "-in" },
    linux_paste_command = { "xclip", "-selection", "clipboard", "-o" },
    copy_youtube_timestamp = true,
}

if display_protocol == "wayland" then
    options.linux_copy_command = { "wl-copy" }
    options.linux_paste_command = { 'wl-paste' }
end

(require "mp.options").read_options(options)

options.copy_keybind = utils.parse_json(options.copy_keybind)
options.paste_keybind = utils.parse_json(options.paste_keybind)
options.copy_sub_keybind = utils.parse_json(options.copy_sub_keybind)

local device = "linux"
if os.getenv("windir") ~= nil then device = "windows"
elseif os.execute('[ -d "/Applications" ]') == 0 and os.execute('[ -d "/Library" ]') == 0 then device = "mac" end

local function bind_keys(keys, name, func)
    if not keys then mp.add_forced_key_binding(keys, name, func); return end
    for i = 1, #keys do
        mp.add_forced_key_binding(keys[i], name .. (i==1 and "" or i), func)
    end
end

local function set_clipboard(text)
    local args
    if device == "mac" then args = {"pbcopy"}
    elseif device == "linux" then args = options.linux_copy_command
    elseif device == "windows" then 
        args = {"powershell", "-NoProfile", "-Command", "Add-Type -AssemblyName PresentationCore; [System.Windows.Clipboard]::SetText('" .. text:gsub("'", "''") .. "')"}
    end
    if args then mp.command_native_async({name = "subprocess", args = args, stdin_data = text}) end
end

local function get_clipboard(callback)
    local args
    if device == "mac" then args = {"pbpaste"}
    elseif device == "linux" then args = options.linux_paste_command
    elseif device == "windows" then
        args = {"powershell", "-NoProfile", "-Command", "$c = Get-Clipboard -Raw -Format Text; if (-not $c) { $c = Get-Clipboard -Raw -Format FileDropList }; [Console]::Write($c)"}
    end
    if args then
        mp.command_native_async({name = "subprocess", args = args, capture_stdout = true}, function(success, res)
            if success and res.status == 0 then callback(res.stdout) end
        end)
    end
end

local function is_url(s) return string.match(s, "^[%w]+://[%w%.%-_]+%.[%a]+[-%w%.%-%_/?&=]*") ~= nil end

local function is_timestamp(str) return string.match(str, "^%d+:%d+$") or string.match(str, "^%d+:%d+:%d+$") end

local function convert_timestamp(timestamp)
    local parts = {}
    for p in string.gmatch(timestamp, "%d+") do table.insert(parts, tonumber(p)) end
    if #parts == 2 then return parts[1] * 60 + parts[2]
    elseif #parts == 3 then return parts[1] * 3600 + parts[2] * 60 + parts[3] end
end

local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

local function copy()
    local path = mp.get_property("path")
    if not path then return end
    path = path:match("^%s*(.-)%s*$")
    
    local is_yt = path:match("youtube%.com") or path:match("youtu%.be")
    local is_u = is_url(path)
    
    if is_u and not is_yt then
        local ua = mp.get_property("user-agent", "Mozilla/5.0")
        local ref = mp.get_property("referrer", "")
        local ua_str = string.format('--user-agent "%s"', ua)
        local ref_str = ref ~= "" and string.format('--referer "%s"', ref) or ""
        path = string.format('yt-dlp -q --impersonate chrome --cookies-from-browser chrome %s %s -o - "%s" | mpv --force-seekable=yes --cache=yes --demuxer-max-bytes=60M --demuxer-max-back-bytes=50M -', ua_str, ref_str, path)
        path = path:gsub("%s+", " ")
        mp.osd_message("Copied yt-dlp command")
    elseif is_u and options.copy_youtube_timestamp then
        path = path:gsub("([&?])t=%d+", function(s) return s == "?" and "?" or "" end):gsub("[?&]$", "")
        local t = mp.get_property_number("time-pos", 0)
        if t > 0 then path = path .. (path:find("?") and "&" or "?") .. "t=" .. math.floor(t) end
        mp.osd_message("Copied YouTube URL")
    else
        mp.osd_message("Copied path")
    end
    
    set_clipboard(path)
end

local function paste()
    mp.osd_message("Loading...", 3)
    get_clipboard(function(clip)
        if not clip then return end
        clip = clip:gsub("\n", " "):match("^%s*(.-)%s*$"):gsub('"', "")
        if clip == "" then return end
        
        local function add_item(type, val)
            if mp.get_property_number("playlist-count", 0) == 0 then mp.commandv("loadfile", val)
            else mp.osd_message("Added " .. type .. " to playlist"); mp.commandv("loadfile", val, "append-play") end
        end
        
        if is_url(clip) then add_item("URL", clip)
        elseif file_exists(clip) then add_item("file", clip)
        elseif is_timestamp(clip) then
            local t = convert_timestamp(clip)
            if t then mp.commandv("seek", t, "absolute", "exact") end
        end
    end)
end

local function open_current()
    local path = mp.get_property("path")
    if not path then return end
    local args
    if is_url(path) then
        if device == "windows" then args = { "powershell", "start", path }
        elseif device == "mac" then args = { "open", path }
        else args = { "xdg-open", path } end
    else
        if device == "windows" then args = { "explorer", "/select,", path }
        elseif device == "mac" then args = { "open", "-a", "Finder", "-R", path }
        else args = { "dbus-send", "--print-reply", "--dest=org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1.ShowItems", "array:string:file://" .. path, "string:" } end
    end
    mp.command_native_async({ name = "subprocess", args = args })
end


local function copy_sub()
    local sub = mp.get_property("sub-text")
    if sub and sub ~= "" then
        set_clipboard(sub:gsub("\n", " "))
        mp.osd_message("Copied subtitle")
    else
        mp.osd_message("No subtitle to copy")
    end
end

bind_keys(options.copy_keybind, "copy", copy)
bind_keys(options.paste_keybind, "paste", paste)
bind_keys(options.copy_sub_keybind, "copy_sub", copy_sub)
mp.add_forced_key_binding(options.open_keybind, "open_current", open_current)