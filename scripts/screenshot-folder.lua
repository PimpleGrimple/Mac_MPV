local mp = require("mp")
local screenshot_key           = "s"
local open_screenshots_keybind = "O"
local open_clips_keybind       = "Ø"
local include_YouTube_ID       = true
local copy_to_clipboard        = true

-- Keep the configured base directory before changing it for each video.
local base_screenshot_dir = mp.get_property("options/screenshot-dir", nil)
if base_screenshot_dir == nil then
    base_screenshot_dir = mp.get_property("options/screenshot-directory", "") or ""
end
local title = "default"
local current_screenshot_dir = ""

mp.msg.info(("[screenshot-folder] loaded as script '%s'; base screenshot directory: '%s'")
    :format(mp.get_script_name(), base_screenshot_dir))

local function sanitize(name)
    name = name and name:gsub("[\\/:*?\"<>|%[%]'`]", "") or ""
    if name == "" or name == "." or name == ".." then
        return "default"
    end
    return name
end

local function join_path(base, child)
    if not base or base == "" then
        return child
    end
    return base:gsub("/+$", "") .. "/" .. child
end

local function expand_path(path)
    return mp.command_native({ "expand-path", path }) or path
end

local function update_screenshot_directory()
    -- Expand special paths (for example ~~desktop/) before setting the option
    -- dynamically, so the per-video folder always resolves to a real path.
    local base = base_screenshot_dir
    if not base or base == "" then
        -- An unset screenshot-dir means mpv's launch working directory.
        base = "."
    end
    current_screenshot_dir = expand_path(join_path(base, title) .. "/")

    -- Options are exposed as options/<name> properties; "screenshot-dir"
    -- by itself is an option name, not a standalone mpv property.
    local ok, err = mp.set_property("options/screenshot-dir", current_screenshot_dir)
    if not ok then
        mp.msg.error("[screenshot-folder] could not set screenshot directory: " .. tostring(err))
    end
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
    end

    title = sanitize(fn)
    update_screenshot_directory()
end)

local function take_configured_screenshot()
    -- Use mpv's configured screenshot-template and screenshot-dir as-is.
    -- No custom duplicate-name detection or suffix retries are performed.
    local ok, result, err = pcall(mp.command_native, {
        name = "screenshot",
        args = { "subtitles" },
    })

    if ok and type(result) == "table" and type(result.filename) == "string" and result.filename ~= "" then
        return result.filename
    end

    if not ok then
        return nil, tostring(result)
    end
    return nil, tostring(err or "mpv did not return a screenshot filename")
end

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
    -- local cmd = { "xclip", "-sel", "c", "-t", "image/png", "-i", filepath }

    mp.command_native_async({ name = "subprocess", args = cmd })
end

mp.add_key_binding(screenshot_key, "screenshot_done", function()
    local sp = mp.get_property("sub-pos")
    mp.set_property("sub-pos", 100)
    local filepath, err = take_configured_screenshot()
    mp.set_property("sub-pos", sp)

    if not filepath or filepath == "" then
        mp.osd_message("Screenshot failed" .. (err and (": " .. err) or ""), 3)
        return
    end

    if copy_to_clipboard then
        copy_file_to_clipboard(filepath)
        mp.osd_message("Screenshot saved and copied", 2)
    else
        mp.osd_message("Screenshot saved", 2)
    end
end)

local function open_folder(path, label)
    if not path or path == "" then
        mp.osd_message(label .. " folder path is not available", 3)
        mp.msg.error("[screenshot-folder] cannot open " .. label .. ": empty path")
        return
    end

    local p = expand_path(path)
    if not p or p == "" then
        mp.osd_message("Could not resolve " .. label .. " folder path", 3)
        mp.msg.error("[screenshot-folder] could not expand path: " .. tostring(path))
        return
    end

    -- macOS: create the folder first and report errors instead of showing a
    -- misleading success message when the path or the `open` command fails.
    local ok, result, err = pcall(mp.command_native, {
        name = "subprocess",
        args = { "mkdir", "-p", p },
        capture_stdout = true,
        capture_stderr = true,
    })
    if not ok or not result or result.status ~= 0 then
        local detail = (not ok and tostring(result))
            or (err and tostring(err))
            or (result and result.stderr and result.stderr ~= "" and result.stderr)
            or "mkdir failed"
        mp.osd_message("Could not create " .. label .. " folder", 3)
        mp.msg.error("[screenshot-folder] mkdir failed for '" .. p .. "': " .. detail)
        return
    end

    local command, start_err = mp.command_native_async({
        name = "subprocess",
        args = { "open", p },
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, open_result, open_err)
        if success and open_result and open_result.status == 0 then
            mp.osd_message("Opened " .. label .. " folder", 2)
        else
            local detail = (open_err and tostring(open_err))
                or (open_result and open_result.stderr and open_result.stderr ~= "" and open_result.stderr)
                or "open command failed"
            mp.osd_message("Could not open " .. label .. " folder", 3)
            mp.msg.error("[screenshot-folder] open failed for '" .. p .. "': " .. detail)
        end
    end)
    if not command then
        mp.osd_message("Could not open " .. label .. " folder", 3)
        mp.msg.error("[screenshot-folder] could not start open command: " .. tostring(start_err))
    end
end

mp.add_key_binding(open_screenshots_keybind, "open_screenshots", function()
    local path = current_screenshot_dir
    if not path or path == "" then
        path = base_screenshot_dir
    end
    open_folder(path, "Screenshots")
end)

mp.add_key_binding(open_clips_keybind, "open_clips", function()
    open_folder("~/Pictures/mpv/clips/" .. title .. "/", "Clips")
end)

mp.msg.info(("[screenshot-folder] folder shortcuts registered: %s -> %s/open_screenshots; %s -> %s/open_clips")
    :format(open_screenshots_keybind, mp.get_script_name(), open_clips_keybind, mp.get_script_name()))
