-- cookie_cache.lua: Caches Chrome cookies to a static text file to bypass macOS Keychain lag
local utils = require("mp.utils")
local msg = require("mp.msg")
local opt = require("mp.options")

local opts = {
    cookie_path = "~~/cache/scripts/cookies.txt",
    browser = "chrome", -- Can be: "chrome", "brave", "edge", "firefox", "vivaldi", "chromium", "opera", or "safari"
    max_age_days = 7
}

opt.read_options(opts, "cookie_cache")
local resolved_path = mp.command_native({"expand-path", opts.cookie_path})

-- Ensure cache directory exists
local dir = resolved_path:match("(.*[/\\])")
if dir then
    local platform = mp.get_property_native("platform")
    if platform == "windows" then
        os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. dir .. '"')
    end
end

local function build_cmd()
    return {
        "yt-dlp",
        "--cookies-from-browser", opts.browser,
        "--cookies", resolved_path,
        "--skip-download",
        "--no-playlist",
        "--playlist-items", "0",
        "https://www.youtube.com"
    }
end

local function is_cookie_valid()
    local info = utils.file_info(resolved_path)
    if not info or not info.mtime or (info.size and info.size == 0) then
        return false, true -- invalid, missing/empty
    end
    local age_days = (os.time() - info.mtime) / 86400
    return age_days <= opts.max_age_days, false
end

local function sync_cookies(is_blocking)
    msg.info("Syncing YouTube cookies from browser...")
    local cmd = build_cmd()

    if is_blocking then
        local res = mp.command_native({
            name = "subprocess",
            args = cmd,
            playback_only = false,
            capture_stdout = false,
            capture_stderr = true
        })
        if res and res.status == 0 then
            msg.info("Created cookies cache: " .. resolved_path)
        else
            msg.warn("Failed initial cookies sync: " .. (res and res.stderr or "unknown error"))
        end
    else
        mp.command_native_async({
            name = "subprocess",
            args = cmd,
            playback_only = false,
            capture_stderr = true
        }, function(success, res)
            if success and res.status == 0 then
                msg.info("Refreshed cookies cache in background.")
            else
                msg.warn("Background cookie refresh failed: " .. (res and res.stderr or "unknown error"))
            end
        end)
    end
end

local valid, missing = is_cookie_valid()
if missing then
    sync_cookies(true)  -- Block once on initial creation so file exists for playback
elseif not valid then
    sync_cookies(false) -- Refresh asynchronously in background without delaying startup
end