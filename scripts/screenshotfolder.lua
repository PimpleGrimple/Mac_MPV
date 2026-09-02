local mp = require("mp")
local options = {
    screenshot_key = 's',
    open_screenshots_keybind = "O",
    open_clips_keybind = "Ø",
    file_ext = "png",
    save_location = "~/Pictures/mpv/screenshots/",
    time_stamp_format = "%tY-%tm-%td_%tH-%tM-%tS",
    show_message = false,
    short_saved_message = true,
    save_as_time_stamp = true,
    save_based_on_chapter_name = false,
    include_YouTube_ID = true,
    copy_to_clipboard = true,
    clipboard_filename = "mpvscreenshot.png",
}
(require "mp.options").read_options(options)

local unpack = table.unpack or unpack
local title, chaptername, last_timestamp, count = "default", "", "", 0
local current_format = options.file_ext
local file, cmd
local platform = mp.get_property_native('platform')

if platform == 'windows' then
    file = os.getenv('TEMP') .. '\\' .. options.clipboard_filename
    cmd = { 'powershell', '-NoProfile', '-Command', "Add-Type -Assembly System.Windows.Forms, System.Drawing; [Windows.Forms.Clipboard]::SetImage([Drawing.Image]::FromFile('" .. file:gsub("'", "''") .. "'))" }
elseif platform == 'darwin' then
    file = os.getenv('TMPDIR') .. '/' .. options.clipboard_filename
    cmd = { 'osascript', '-e', string.format('set the clipboard to (read (POSIX file %q) as %s)', file, options.file_ext ~= '' and options.file_ext or 'PNG picture') }
else
    file = '/tmp/' .. options.clipboard_filename
    cmd = os.getenv('XDG_SESSION_TYPE') == 'wayland' and { 'sh', '-c', ('wl-copy < %q'):format(file) } or { 'xclip', '-sel', 'c', '-t', options.file_ext ~= '' and options.file_ext or 'image/png', '-i', file }
end

local function sanitize(name) return name and name:gsub('[\\/:*?"<>|]', '') or "" end

local function set_template()
    mp.set_property("screenshot-format", current_format)
    mp.set_property("screenshot-directory", options.save_location .. title .. "/")
    local ts = mp.command_native({ "expand-text", options.time_stamp_format })
    if ts ~= last_timestamp then count = 0; last_timestamp = ts end
    local suf = count > 0 and ("(" .. (count + 1) .. ")") or ""
    local tpl = (options.save_based_on_chapter_name and chaptername ~= "") and (sanitize(chaptername) .. " (" .. ts .. ")" .. suf) or (ts .. suf)
    mp.set_property("screenshot-template", tpl)
end

mp.observe_property("chapter-metadata/title", "string", function(_, v) chaptername = v or ""; set_template() end)
mp.observe_property("screenshot-format", "string", function(_, v) if v then current_format = v end end)

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", "")
    local fn = mp.get_property("filename/no-ext", "")
    if path:match("^[%w]+://") then
        local yt = ""
        if options.include_YouTube_ID then yt = mp.get_property("filename", ""):match("[?&]v=([^&]+)") or mp.get_property("filename", ""):match("([%w_-]+)%?si=") or "" end
        fn = mp.get_property("media-title", ""):sub(1, 100):match("^%s*(.-)%s*$") .. (yt ~= "" and (" [" .. yt .. "]") or "")
    end
    title = sanitize(fn); count = 0; set_template()
end)

mp.add_key_binding(options.screenshot_key, "screenshot_done", function()
    local sp = mp.get_property("sub-pos")
    mp.set_property("sub-pos", 100)
    mp.commandv("screenshot")
    if options.copy_to_clipboard then
        mp.commandv('screenshot-to-file', file, "subtitles")
        mp.command_native_async({ 'run', unpack(cmd) })
    end
    mp.set_property("sub-pos", sp)
    if options.show_message then mp.osd_message(options.short_saved_message and "Screenshot saved" or ("Screenshot saved to: " .. mp.command_native({ "expand-path", mp.get_property("screenshot-directory") }):gsub("\\", "/"))) end
    count = count + 1; set_template()
end)

local function open_folder(path, label)
    local p = mp.command_native({"expand-path", path})
    if platform == 'windows' then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul'); mp.command_native_async({name = "subprocess", args = {"explorer", p}})
    elseif platform == 'darwin' then os.execute('mkdir -p "' .. p .. '"'); mp.command_native_async({name = "subprocess", args = {"open", p}})
    else os.execute('mkdir -p "' .. p .. '"'); mp.command_native_async({name = "subprocess", args = {"xdg-open", p}}) end
    mp.osd_message("Opened " .. label .. " folder")
end

mp.add_key_binding(options.open_screenshots_keybind, "open_screenshots", function() open_folder(options.save_location .. title .. "/", "Screenshots") end)
mp.add_key_binding(options.open_clips_keybind, "open_clips", function() open_folder("~/Pictures/mpv/clips/" .. title .. "/", "Clips") end)
