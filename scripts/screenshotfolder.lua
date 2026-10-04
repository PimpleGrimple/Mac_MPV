local mp = require("mp")

local screenshot_key           = "s"
local open_screenshots_keybind = "O"
local open_clips_keybind       = "Ø"
local save_location            = "~/Pictures/mpv/screenshots/"
local time_stamp_format        = "%tY-%tm-%td_%tH-%tM-%tS"
local include_YouTube_ID       = true
local copy_to_clipboard        = true

local title, last_timestamp, count = "default", "", 0
local current_filepath = ""

local function sanitize(name)
    return name and name:gsub('[\\/:*?"<>|%[%]\'%`]', '') or ""
end

local function set_template()
    local dir = save_location .. title .. "/"
    mp.set_property("screenshot-directory", dir)
    local ts = mp.command_native({ "expand-text", time_stamp_format })
    if ts ~= last_timestamp then
        count = 0
        last_timestamp = ts
    end
    local suf = count > 0 and ("(" .. (count + 1) .. ")") or ""
    local template = ts .. suf
    mp.set_property("screenshot-template", template)

    local ext = mp.get_property("screenshot-format", "png")
    local expanded_dir = mp.command_native({ "expand-path", dir })
    current_filepath = expanded_dir .. template .. "." .. ext
end

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", "")
    local fn = mp.get_property("filename/no-ext", "")
    if path:match("^[%w]+://") then
        local yt = ""
        if include_YouTube_ID then
            yt = mp.get_property("filename", ""):match("[?&]v=([^&]+)") or mp.get_property("filename", ""):match("([%w_-]+)%?si=") or ""
        end
        fn = mp.get_property("media-title", ""):sub(1, 100):match("^%s*(.-)%s*$") .. (yt ~= "" and (" " .. yt) or "")
    end
    title = sanitize(fn)
    count = 0
    set_template()
end)

local function copy_file_to_clipboard(filepath)
    -- macOS
    local script = string.format([[
        use framework "Foundation"
        use framework "AppKit"
        set theImage to current application's NSImage's alloc()'s initWithContentsOfFile:"%s"
        set pasteboard to current application's NSPasteboard's generalPasteboard()
        pasteboard's clearContents()
        pasteboard's writeObjects:{theImage}
    ]], filepath:gsub('"', '\\"'))
    local cmd = { "osascript", "-e", script }

    -- Windows
    -- local cmd = { "powershell", "-NoProfile", "-Command", "Add-Type -Assembly System.Windows.Forms, System.Drawing; [Windows.Forms.Clipboard]::SetImage([Drawing.Image]::FromFile('" .. filepath:gsub("'", "''") .. "'))" }

    -- Linux (Wayland)
    -- local cmd = { "sh", "-c", ('wl-copy < %q'):format(filepath) }

    -- Linux (X11)
    -- local ext = mp.get_property("screenshot-format", "png")
    -- local mime = (ext == "jpg" or ext == "jpeg") and "image/jpeg" or "image/png"
    -- local cmd = { "xclip", "-sel", "c", "-t", mime, "-i", filepath }

    mp.command_native_async({ name = "subprocess", args = cmd })
end

mp.add_key_binding(screenshot_key, "screenshot_done", function()
    local sp = mp.get_property("sub-pos")
    mp.set_property("sub-pos", 100)
    
    if copy_to_clipboard then
        mp.commandv("screenshot-to-file", current_filepath, "subtitles")
        copy_file_to_clipboard(current_filepath)
    else
        mp.commandv("screenshot")
    end
    
    mp.set_property("sub-pos", sp)
    mp.osd_message("Screenshot saved", 2)
    
    count = count + 1
    set_template()
end)

local function open_folder(path, label)
    local p = mp.command_native({ "expand-path", path })
    -- macOS
    mp.command_native({ name = "subprocess", args = { "mkdir", "-p", p } })
    mp.command_native_async({ name = "subprocess", args = { "open", p } })

    -- Linux
    -- mp.command_native({ name = "subprocess", args = { "mkdir", "-p", p } })
    -- mp.command_native_async({ name = "subprocess", args = { "xdg-open", p } })

    -- Windows
    -- mp.command_native({ name = "subprocess", args = { "cmd", "/c", "mkdir", p:gsub("/", "\\") } })
    -- mp.command_native_async({ name = "subprocess", args = { "explorer", p } })

    mp.osd_message("Opened " .. label .. " folder", 2)
end

mp.add_key_binding(open_screenshots_keybind, "open_screenshots", function()
    open_folder(save_location .. title .. "/", "Screenshots")
end)

mp.add_key_binding(open_clips_keybind, "open_clips", function()
    open_folder("~/Pictures/mpv/clips/" .. title .. "/", "Clips")
end)