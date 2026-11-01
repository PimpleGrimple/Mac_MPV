local utils = require("mp.utils")
local msg = require("mp.msg")

local max_age_days = 5
local home = os.getenv("HOME")
local browser = home and ("chrome:" .. home .. "/Library/Application Support/Google/Chrome") or "chrome"
local cookie_path = mp.command_native({"expand-path", "~~/cache/scripts/cookies.txt"})

local dir = cookie_path:match("(.*[/\\])")
if dir and not utils.file_info(dir) then
    local is_win = package.config:sub(1, 1) == "\\"
    mp.command_native({name = "subprocess", args = is_win and {"cmd", "/c", "mkdir", dir:gsub("/", "\\")} or {"mkdir", "-p", dir}})
end

local info = utils.file_info(cookie_path)
local missing = not info or not info.mtime or info.size == 0
if not missing and (os.time() - info.mtime) / 86400 <= max_age_days then return end

msg.info("Syncing cookies from browser...")

local cmd = {
    name = "subprocess",
    capture_stderr = true,
    args = {
        "yt-dlp", "--quiet", "--no-warnings", "--cookies-from-browser", browser,
        "--cookies", cookie_path, "--skip-download", "--no-playlist",
        "https://www.youtube.com"
    }
}

local function on_done(success, res)
    if success and res and res.status == 0 then
        msg.info("Cookie cache ready.")
    else
        msg.warn("Cookie sync failed: " .. (res and res.stderr or "unknown error"))
    end
end

if missing then
    on_done(mp.command_native(cmd) and true, mp.command_native(cmd))
else
    mp.command_native_async(cmd, on_done)
end