--[[
screenshot_folder.lua

Saves screenshots into a per-video subfolder of --screenshot-dir and
(optionally) copies the saved image to the macOS clipboard.

    <screenshot-dir>/<video name>/<screenshot-template>.<ext>

For URLs the folder is named after media-title (+ YouTube ID).

================================================================================
MPV SCREENSHOT FLAGS
================================================================================
Command:  screenshot <flags>          (flags are joined with "+")

Base flags (what gets rendered into the image):

  video        Original video resolution. No subtitles, no OSD.
               ("-" is an alias for it.)
  subtitles    Original video resolution + subtitles. This is what a plain
               `screenshot` does (mpv's default).
  scaled       Scaled to the window/display size (what you see on screen,
               without any overlay).
  osd          Burn the OSD into the image.
  window       Alias of  scaled+subtitles+osd  -> a copy of the mpv window.

Modifier:

  each-frame   Toggle: saves a screenshot of EVERY frame until the command is
               issued again. Combine with a base flag, e.g. video+each-frame.
               Set --framedrop=no first, otherwise dropped frames give you
               duplicate images. Returns no filename, so no clipboard copy.

Useful combinations:

  flags                      result
  -------------------------  ----------------------------------------------
  video                      original res, clean
  subtitles                  original res + subs              (mpv default)
  scaled                     window res, clean
  scaled+subtitles           window res + subs, no OSD
  scaled+osd                 window res + OSD, no subs
  scaled+subtitles+osd       window res + subs + OSD  (== window)
  video+each-frame           clean original-res frame dump (toggle)

Notes:
  * `scaled` / `osd` are recent additions (mpv git master / newer releases).
    Older builds only know video, subtitles, window, each-frame.
  * The exact result depends on the video output (--vo). If it cannot do
    scaled/window screenshots, mpv falls back to `video` behaviour.
  * `subtitles` is dropped by mpv when subtitles are rendered inside the
    filter chain.
  * Related commands (not used here):
      screenshot-to-file "<file>" <flags>   save to an explicit path
      screenshot-raw <flags>                return raw pixels to a script
  * `async` can be added as a flag to make encoding/writing asynchronous, but
    this script needs the finished file for the clipboard, so it does not.

================================================================================
KEY BINDINGS
================================================================================
Bindings are the plain mp.add_key_binding lines at the bottom of the file.
Copy a line to add another one. Active by default:

  key   binding name          flags
  ----  --------------------  ------
  j     screenshot-video      video
  J     screenshot-window     window

A binding can also be triggered from input.conf, e.g.
    Ctrl+s script-binding screenshot_folder/screenshot-scaled-osd
(the script name comes from the file name: screenshot_folder.lua).

Heads-up: `j` / `J` shadow mpv's default "cycle sub" / "cycle sub down".
--]]

local mp = require("mp")

local include_YouTube_ID = true
local copy_to_clipboard  = true
local max_title_bytes    = 100

-- Read once at load: changing --screenshot-dir at runtime is not picked up.
local base_screenshot_dir = mp.get_property("options/screenshot-dir", "")
local title = "default"

-- Helpers --------------------------------------------------------------------

-- Cut to max bytes without splitting a UTF-8 character
-- (mpv usually runs Lua 5.1/LuaJIT, so there is no utf8 library).
local function utf8_truncate(s, max)
    if #s <= max then return s end
    local cut = max
    while cut > 0 do
        local b = s:byte(cut + 1)
        if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
    end
    return s:sub(1, cut)
end

-- Make a string safe to use as a single folder name.
local function sanitize(s)
    s = s:gsub("[%c/\\:*?\"<>|]", "")   -- control chars + path/reserved chars
    s = s:gsub("^[%s.]+", "")           -- no leading dots (hidden folder) / spaces
    s = s:gsub("[%s.]+$", "")           -- no trailing dots / spaces
    return s
end

local function update_screenshot_directory()
    local base = (base_screenshot_dir ~= "" and base_screenshot_dir) or "."
    local dir = base:gsub("/+$", "") .. "/" .. title .. "/"
    local ok, err = mp.set_property("options/screenshot-dir", dir)
    if not ok then
        mp.msg.error("[screenshot-folder] could not set screenshot directory: " .. tostring(err))
    end
end

local function refresh_title()
    local path = mp.get_property("path", "")
    local fn = mp.get_property("filename/no-ext", "")

    if path:match("^[%a][%w+.-]*://") then
        local yt = ""
        if include_YouTube_ID then
            local filename = mp.get_property("filename", "")
            yt = filename:match("[?&]v=([^&]+)")
                or filename:match("([%w_-]+)%?si=")
                or ""
        end
        local name = sanitize(utf8_truncate(mp.get_property("media-title", ""), max_title_bytes))
        fn = name .. ((name ~= "" and yt ~= "") and " " or "") .. yt
    end

    fn = sanitize(fn)
    local new_title = fn ~= "" and fn or "default"
    if new_title ~= title then
        title = new_title
        update_screenshot_directory()
    end
end

-- Clipboard ------------------------------------------------------------------
-- The path is passed as an argument (argv) instead of being spliced into the
-- AppleScript source, so quotes/backslashes/odd characters in it are harmless.
local CLIPBOARD_SCRIPT = [[
use framework "Foundation"
use framework "AppKit"
on run argv
    set theImage to current application's NSImage's alloc()'s initWithContentsOfFile:(item 1 of argv)
    if theImage is missing value then error "could not load image"
    set pasteboard to current application's NSPasteboard's generalPasteboard()
    pasteboard's clearContents()
    pasteboard's writeObjects:{theImage}
end run
]]

local function copy_file_to_clipboard(filepath, on_done)
    if filepath:sub(1, 1) == "-" then filepath = "./" .. filepath end
    mp.command_native_async({
        name = "subprocess",
        args = { "osascript", "-e", CLIPBOARD_SCRIPT, filepath },
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, result, err)
        local copied = success and result and result.status == 0
        if on_done then
            on_done(copied, copied and nil or (err or (result and result.stderr) or "osascript failed"))
        end
    end)
end

-- Screenshot -----------------------------------------------------------------

local function screenshot(flags)
    local is_each_frame = flags:find("each-frame", 1, true) ~= nil
    local result, cmd_err = mp.command_native({ "screenshot", flags })

    if result == nil then
        mp.msg.error("[screenshot-folder] screenshot '" .. flags .. "' failed: " .. tostring(cmd_err))
        mp.osd_message("Screenshot failed", 3)
        return
    end

    -- each-frame is a toggle and returns no filename.
    if is_each_frame then
        mp.osd_message("Each-frame screenshots toggled (" .. flags .. ")", 2)
        return
    end

    local filename = type(result) == "table" and result.filename
    if type(filename) ~= "string" or filename == "" then
        -- Saved, but this mpv version did not report the filename.
        mp.osd_message("Screenshot saved", 2)
        return
    end

    if not copy_to_clipboard then
        mp.osd_message("Screenshot saved", 2)
        return
    end

    copy_file_to_clipboard(filename, function(copied, copy_err)
        if copied then
            mp.osd_message("Screenshot saved and copied", 2)
        else
            mp.osd_message("Screenshot saved (copy failed)", 3)
            mp.msg.error("[screenshot-folder] clipboard copy failed: " .. tostring(copy_err))
        end
    end)
end

-- Wiring ---------------------------------------------------------------------

mp.register_event("file-loaded", refresh_title)

-- Streams often get their real title only after file-loaded (ytdl etc.).
mp.observe_property("media-title", "string", function()
    if mp.get_property("path", ""):match("^[%a][%w+.-]*://") then
        refresh_title()
    end
end)

-- Key bindings ---------------------------------------------------------------
-- One line per binding: copy a line, change the key, name and flags.
-- Unused ones are commented out; remove the leading "--" and give them a key.
-- (Flags are explained in the header above.)

mp.add_key_binding("j", "screenshot-video",  function() screenshot("video")  end)
mp.add_key_binding("J", "screenshot-window", function() screenshot("window") end)

-- mp.add_key_binding("KEY", "screenshot-subtitles",             function() screenshot("subtitles")            end)
-- mp.add_key_binding("KEY", "screenshot-scaled",                function() screenshot("scaled")               end)
-- mp.add_key_binding("KEY", "screenshot-scaled-subtitles",      function() screenshot("scaled+subtitles")     end)
-- mp.add_key_binding("KEY", "screenshot-scaled-osd",            function() screenshot("scaled+osd")           end)
-- mp.add_key_binding("KEY", "screenshot-scaled-subtitles-osd",  function() screenshot("scaled+subtitles+osd") end)
-- mp.add_key_binding("KEY", "screenshot-video-each-frame",      function() screenshot("video+each-frame")     end)