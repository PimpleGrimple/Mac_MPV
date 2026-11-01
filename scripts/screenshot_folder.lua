local mp = require("mp")
local include_YouTube_ID = true
local copy_to_clipboard  = true

local base_screenshot_dir = mp.get_property("options/screenshot-dir", "")
local title = "default"

local function update_screenshot_directory()
    local base = (base_screenshot_dir ~= "" and base_screenshot_dir) or "."
    local dir = base:gsub("/+$", "") .. "/" .. title .. "/"
    local ok, err = mp.set_property("options/screenshot-dir", dir)
    if not ok then
        mp.msg.error("[screenshot-folder] could not set screenshot directory: " .. tostring(err))
    end
end

local function copy_file_to_clipboard(filepath, on_done)
    -- %q escapes quotes/backslashes and avoids %-format corruption.
    local script = string.format([[
        use framework "Foundation"
        use framework "AppKit"
        set theImage to current application's NSImage's alloc()'s initWithContentsOfFile:%q
        set pasteboard to current application's NSPasteboard's generalPasteboard()
        pasteboard's clearContents()
        pasteboard's writeObjects:{theImage}
    ]], filepath)
    mp.command_native_async({ name = "subprocess", args = { "osascript", "-e", script }, capture_stdout = true },
        function(success, result, err)
            local ok = success and result and result.status == 0
            if on_done then
                on_done(ok, ok and nil or (err or (result and result.stderr) or "osascript failed"))
            end
        end)
end

local function screenshot(mode)
    local ok, result = pcall(mp.command_native, { "screenshot", mode })
    if not ok or type(result) ~= "table" or type(result.filename) ~= "string" or result.filename == "" then
        mp.osd_message("Screenshot failed", 3)
        return
    end

    if not copy_to_clipboard then
        mp.osd_message("Screenshot saved", 2)
        return
    end

    copy_file_to_clipboard(result.filename, function(ok, copy_err)
        if ok then
            mp.osd_message("Screenshot saved and copied", 2)
        else
            mp.osd_message("Screenshot saved (copy failed)", 3)
            mp.msg.error("[screenshot-folder] clipboard copy failed: " .. tostring(copy_err))
        end
    end)
end

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", "")
    local fn = mp.get_property("filename/no-ext", "")

    if path:match("^[%w]+://") then
        local yt = ""
        if include_YouTube_ID then
            yt = mp.get_property("filename", ""):match("[?&]v=([^&]+)")
                or mp.get_property("filename", ""):match("([%w_-]+)%?si=")
                or ""
        end
        fn = mp.get_property("media-title", ""):sub(1, 100):match("^%s*(.-)%s*$")
            .. (yt ~= "" and (" " .. yt) or "")
        fn = fn:gsub("[/:]", "")
    end

    title = fn ~= "" and fn or "default"
    update_screenshot_directory()
end)

mp.add_key_binding("Alt+j", "screenshot",        function() screenshot("subtitles") end)
mp.add_key_binding("j", "screenshot-video",  function() screenshot("video")     end)
mp.add_key_binding("J", "screenshot-window", function() screenshot("window")    end)