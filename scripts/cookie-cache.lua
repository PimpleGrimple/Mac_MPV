local utils = require("mp.utils")
local msg = require("mp.msg")

local max_age_days = 5
local browser = os.getenv("HOME") and ("chrome:" .. os.getenv("HOME") .. "/Library/Application Support/Google/Chrome") or "chrome"
local cookie_path = mp.command_native({"expand-path", "~~/cache/scripts/cookies.txt"})

-- Ensure directory exists
local dir = cookie_path:match("(.*[/\\])")
if dir and not utils.file_info(dir) then
    local is_win = package.config:sub(1, 1) == "\\"
    mp.command_native({name = "subprocess", args = is_win and {"cmd", "/c", "mkdir", dir:gsub("/", "\\")} or {"mkdir", "-p", dir}})
end

-- Validate current cache
local info = utils.file_info(cookie_path)
local is_missing = not info or not info.mtime or (info.size == 0)
local is_expired = not is_missing and ((os.time() - info.mtime) / 86400 > max_age_days)

-- Exit immediately if cache is healthy
if not is_missing and not is_expired then return end

msg.info("Syncing cookies from browser...")

local cmd = {
    name = "subprocess", 
    capture_stderr = true,
    args = {
        "yt-dlp", "--quiet", "--no-warnings", "--cookies-from-browser", browser,
        "--cookies", cookie_path, "--skip-download", "--no-playlist",
        "--playlist-items", "0", "https://www.youtube.com"
    }
}

local function on_done(success, res)
    if success and res.status == 0 then
        msg.info("Cookie cache ready.")
    else
        msg.warn("Cookie sync failed: " .. (res and res.stderr or "unknown error"))
    end
end

-- Block if missing, otherwise refresh silently in background
if is_missing then
    on_done(true, mp.command_native(cmd))
else
    mp.command_native_async(cmd, on_done)
end