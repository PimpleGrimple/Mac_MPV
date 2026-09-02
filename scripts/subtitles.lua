--[[
    subtitles.lua

    Merges three separate scripts into one, so a single keybind gets you
    the right kind of subtitles/lyrics no matter what's playing:

      - YouTube video   -> auto-generated captions   (was ytsub.lua)
      - Audio/music     -> synced lyrics              (was autolyrics.lua)
      - Local video      -> downloaded subtitles       (was autosub.lua, via Subliminal)

    Sources merged (full credit / original logic preserved):
      * autolyrics.lua by zydezu - https://github.com/zydezu/mpvconfig
      * ytsub.lua by zydezu, forked from https://github.com/Idlusen/mpv-ytsub
      * autosub.lua (Subliminal-based autosub script)

    All original manual keybindings and automatic-on-load behaviour are kept,
    so nothing about the old workflow breaks - there's just one new keybind
    (smart_binding, default "ctrl+s") that picks the right one automatically.

    NOTE ON script-opts: since all three scripts' options are now merged into
    one file, the option names below have gained prefixes to avoid clashes
    (e.g. autolyrics' "download_for_all" is now "lyrics_download_for_all").
    If you had a script-opts/autolyrics.conf, ytsub.conf, etc. rename it to
    script-opts/subtitles.conf and update the keys accordingly.
--]]

mp.utils = require("mp.utils")
mp.input = require("mp.input")

-- optionally import a module, returning nil instead of erroring if it's missing
local function want(name)
    local out
    if xpcall(function() out = require(name) end, function(e) out = e end) then
        return out      -- success
    else
        return nil, out -- error
    end
end

local http = want("socket.http")
local https = want("ssl.https")

------------------------------------------------------------------
-- OPTIONS
------------------------------------------------------------------
local options = {
    -- === smart dispatcher ===
    smart_binding = "4",           -- one keybind: picks lyrics / subs / yt-captions automatically

    -- === lyrics (from autolyrics.lua) ===
    musixmatch_token = "2501192ac605cc2e16b6b2c04fe43d1011a38d919fe802976084e7",
    lyrics_download_for_all = false,    -- try to get lyrics for music without metadata
    lyrics_load_for_youtube = true,     -- try to load lyrics on youtube videos
    lyrics_store_separate = true,       -- store lyrics in lyrics_store instead of next to the file
    lyrics_store = "~~/cache/scripts/lyrics/",
    lyrics_strip_artists = true,        -- remove lines with artist names from NetEase lyrics
    lyrics_cache_loading = true,        -- try to load lyrics that were already downloaded
    lyrics_run_automatically = false,   -- run lyric lookup without pressing a key
    lyrics_musixmatch_binding = "alt+m",
    lyrics_lrclib_binding = "alt+n",
    lyrics_offset_binding = "alt+o",

    -- === subtitles via Subliminal (from autosub.lua) ===
    subliminal_path = "/Users/mahmoud/.local/bin/subliminal",
    sub_auto = false,                   -- automatically download subs, no hotkey required
    sub_debug = false,                  -- use --debug in subliminal command
    sub_force = false,                  -- force download; overwrite existing subtitle files
    sub_utf8 = true,                    -- save all subtitle files as UTF-8
    sub_download_binding = "q",         -- NOTE: shadows mpv's default "quit-watch-later" binding
    sub_download2_binding = "n",        -- manually download the 2nd preferred language

    -- === YouTube auto-subs (from ytsub.lua) ===
    yt_source_lang = "en",              -- secondary language to load alongside the original
    yt_autoload_on_start = false,       -- automatically load auto-subs when a video starts
    yt_filter_sub_single_line = true,   -- remove duplicate/overlapping lines from auto-subs
    yt_select_binding = "alt+y",        -- interactively pick which auto-sub language to load
    yt_autoload_binding = "alt+Y",      -- load original + yt_source_lang auto-subs immediately
    yt_cache_dir = "~/.cache/ytsub/",
}
require("mp.options").read_options(options)

options.yt_cache_dir = mp.command_native({ "expand-path", options.yt_cache_dir })

-- Subliminal language preference order: { 'Name', 'ISO-639-1', 'ISO-639-2' }
-- If subtitles are found for the first language, other languages are not tried,
-- so put your preferred language first.
local sub_languages = {
    { 'English', 'en', 'eng' },
    { 'Japanese', 'ja', 'jpn' },
    -- { 'Arabic', 'ar', 'ara' },
    -- { 'French', 'fr', 'fre' },
    -- { 'Spanish', 'es', 'spa' },
    -- { 'German', 'de', 'ger' },
}

-- Optional provider logins for Subliminal, e.g.:
-- { '--opensubtitles', 'USERNAME', 'PASSWORD' },
local sub_logins = {
}

-- Paths excluded from Subliminal auto-downloading (substring or full path match)
local sub_excludes = {
    'no-subs-dl',
}

-- If non-empty, ONLY these paths get Subliminal auto-downloading
local sub_includes = {
}

------------------------------------------------------------------
-- SHARED HELPERS
------------------------------------------------------------------

-- Generic logger: always prints to terminal, optionally shows OSD
local function log(message, secs, osd)
    secs = secs or 2.5
    mp.msg.warn(message)
    if osd ~= false then
        mp.osd_message(message, secs)
    end
end

local function create_dir(path)
    local args
    if package.config:sub(1, 1) == '\\' then
        local win_path = path:gsub("/", "\\")
        args = { "cmd", "/c", "mkdir", win_path }
    else
        args = { "mkdir", "-p", path }
    end

    local res = mp.command_native({ name = "subprocess", args = args, playback_only = false })
    if res.status == 0 then
        mp.msg.info("Successfully created folder: " .. path)
    else
        mp.msg.error("Failed to create folder: " .. path)
    end
end

------------------------------------------------------------------
-- LYRICS (autolyrics.lua)
------------------------------------------------------------------

local lyrics_manual_run = false
local lyrics_got_lyrics = false
local lyrics_without_timestamps = false
local lyrics_downloading_name = ""
local lyrics_old_sub_count, lyrics_sub_count

local function lyrics_error(message)
    mp.msg.error(message)
    if mp.get_property_native("vo-configured") and lyrics_manual_run then
        mp.osd_message(message, 5)
    end
end

local function lyrics_curl(args)
    local r = mp.command_native({ name = "subprocess", capture_stdout = true, args = args })

    if r.killed_by_us then
        return false
    end
    if r.status < 0 then
        lyrics_error("subprocess error: " .. r.error_string)
        return false
    end
    if r.status > 0 then
        lyrics_error("curl failed with code " .. r.status)
        return false
    end

    local response, err = mp.utils.parse_json(r.stdout)
    if err then
        lyrics_error("Unable to parse the JSON response")
        return false
    end
    return response
end

local function lyrics_get_metadata()
    local metadata = mp.get_property_native("metadata")
    local title, artist, album
    if metadata then
        if next(metadata) == nil then
            mp.msg.info("Couldn't load metadata!")
        else
            title = metadata.title or metadata.TITLE or metadata.Title
            if options.lyrics_download_for_all then
                title = mp.get_property("media-title")
                title = title:gsub("%b[]", "") .. " "
            end
            artist = mp.get_property("filtered-metadata/by-key/Artist") or mp.get_property("filtered-metadata/by-key/Album_Artist") or mp.get_property("filtered-metadata/by-key/Uploader")
            if options.lyrics_download_for_all and not artist then
                artist = " "
            end
            album = metadata.album or metadata.ALBUM or metadata.Album or ""
        end
    else
        mp.msg.info("Couldn't load metadata!")
    end

    if not title then
        lyrics_error("This song has no title metadata")
        return false
    end
    if not artist then
        lyrics_error("This song has no artist metadata")
        return false
    end

    local duration = mp.get_property_number("duration") or 0
    return title, artist, album, duration
end

local function lyrics_strip_artists(lyrics)
    for _, pattern in pairs({ '作词', '作詞', '作曲', '制作人', '编曲', '編曲', '詞', '曲' }) do
        lyrics = lyrics:gsub('%[[%d:%.]*] ?' .. pattern .. ' ?[:：] ?.-\n', '')
    end
    return lyrics
end

local function lyrics_save(lyrics)
    if lyrics == "" or #lyrics < 100 then
        lyrics_error("Lyrics not found")
        return
    end

    local current_sub_path = mp.get_property("current-tracks/sub/external-filename")

    if current_sub_path and lyrics:find("^%[") == nil then
        lyrics_error("Only lyrics without timestamps are available, so the existing LRC file won't be overwritten")
        return
    end

    lyrics = lyrics:gsub("’", "'"):gsub("' ", "'"):gsub("\\", "")

    if options.lyrics_strip_artists then
        lyrics = lyrics_strip_artists(lyrics)
    end

    local function is_url(s)
        local url_pattern = "^[%w]+://[%w%.%-_]+%.[%a]+[-%w%.%-%_/?&=]*"
        return string.match(s, url_pattern) ~= nil
    end

    lyrics_downloading_name = lyrics_downloading_name:gsub("\\", " "):gsub("/", " ")

    local path = mp.get_property("path")
    local media = lyrics_downloading_name .. " [" .. mp.get_property("filename/no-ext") .. "]"
    local pattern = '[\\/:*?"<>|]'

    if (is_url(path) and path or nil) and options.lyrics_load_for_youtube then
        local youtube_ID = ""
        if not lyrics_downloading_name then
            youtube_ID = " [" .. mp.get_property("filename"):match("[?&]v=([^&]+)") .. "]"
        end
        local filename = string.gsub(media:sub(1, 100):gsub(pattern, ""), "^%s*(.-)%s*$", "%1") .. youtube_ID
        path = mp.command_native({ "expand-path", options.lyrics_store .. filename })
    else
        if options.lyrics_store_separate then
            path = mp.command_native({ "expand-path", options.lyrics_store .. media })
        end
    end

    local lrc_path = (path:gsub("?", "") .. ".lrc")
    local dir_path = lrc_path:match("(.+[\\/])")

    if mp.utils.readdir(dir_path) == nil and options.lyrics_store_separate then
        create_dir(dir_path)
    end

    local lrc = io.open(lrc_path, "w")
    if lrc == nil then
        lyrics_error("Failed writing to " .. lrc_path)
        return
    end
    lrc:write(lyrics)
    lrc:close()

    if lyrics:find("^%[") then
        mp.command(current_sub_path and "sub-reload" or "rescan-external-files")
        if lyrics_manual_run then
            mp.osd_message("Lyrics downloaded")
        end
        lyrics_got_lyrics = true
        lyrics_without_timestamps = false
    else
        if lyrics_manual_run then
            mp.osd_message("Lyrics without timestamps downloaded")
        end
        lyrics_without_timestamps = true
    end
end

local function lyrics_musixmatch_download()
    local title, artist, album, duration = lyrics_get_metadata()
    if not title then return end

    mp.msg.info("Fetching lyrics (musixmatch)")
    if lyrics_manual_run then
        mp.osd_message("Fetching lyrics (musixmatch)")
    end
    mp.msg.info("Requesting: " .. title .. " - " .. artist)

    local response = lyrics_curl({
        "curl",
        "--silent",
        "--get",
        "--cookie", "x-mxm-token-guid=" .. options.musixmatch_token,
        "https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get",
        "--data", "app_id=web-desktop-app-v1.0",
        "--data", "usertoken=" .. options.musixmatch_token,
        "--data-urlencode", "q_track=" .. title,
        "--data-urlencode", "q_artist=" .. artist,
    })

    if not response then return end

    if response.message.header.status_code == 401 and response.message.header.hint == "renew" then
        lyrics_error("The Musixmatch token has been rate limited - https://github.com/guidocella/mpv-lrc >>> script-opts/lrc.conf explains how to generate a new one.")
        return
    end

    if response.message.header.status_code ~= 200 then
        lyrics_error("Request failed with status code " .. response.message.header.status_code .. ". Hint: " .. response.message.header.hint)
        return
    end

    local lyrics = ""
    local body = response and response.message and response.message.body and response.message.body.macro_calls
    if not body then
        lyrics_error("Invalid response structure: macro_calls not found")
        return
    end
    local matcher = body["matcher.track.get"]
    if not matcher or not matcher.message or not matcher.message.header then
        lyrics_error("Invalid matcher.track.get structure")
        return
    end

    if matcher.message.header.status_code == 200 then
        local track = matcher.message.body and matcher.message.body.track
        if not track or not track.artist_name or not track.track_name then
            lyrics_error("Track data missing")
            return
        end
        lyrics_downloading_name = track.artist_name .. " - " .. track.track_name

        if track.has_subtitles == 1 then
            local subtitles = body["track.subtitles.get"]
            if subtitles and subtitles.message and subtitles.message.body then
                local subtitle_list = subtitles.message.body.subtitle_list
                if subtitle_list and subtitle_list[1] and subtitle_list[1].subtitle then
                    lyrics = subtitle_list[1].subtitle.subtitle_body or ""
                else
                    lyrics_error("Subtitles data is malformed")
                end
            else
                lyrics_error("Subtitle data missing")
            end
        elseif track.has_lyrics == 1 then
            local lyrics_data = body["track.lyrics.get"]
            if lyrics_data and lyrics_data.message and lyrics_data.message.body and lyrics_data.message.body.lyrics then
                lyrics = lyrics_data.message.body.lyrics.lyrics_body or ""
            else
                lyrics_error("Lyrics data is missing or malformed")
            end
        elseif track.instrumental == 1 then
            lyrics_error("This is an instrumental track")
            return
        else
            lyrics_error("No lyrics or subtitles found")
        end
    end

    lyrics_save(lyrics)
end

local function lyrics_lrclib_download()
    local title, artist, album, duration = lyrics_get_metadata()
    if not title or not artist or not album or not duration then return end

    mp.osd_message('Fetching lyrics (lrclib.net)')

    local response = lyrics_curl({
        "curl",
        "--silent",
        "--get",
        "https://lrclib.net/api/get",
        "--data-urlencode", "track_name=" .. title,
        "--data-urlencode", "artist_name=" .. artist,
        "--data-urlencode", "album_name=" .. album,
        "--data-urlencode", "duration=" .. duration,
    })

    if not response or not response.artistName or not response.trackName then return end

    if response.instrumental == true then
        lyrics_error("This is an instrumental track")
        return
    end

    lyrics_downloading_name = response.artistName .. " - " .. response.trackName
    lyrics_save(response.syncedLyrics)
end

local function lyrics_auto_download()
    if lyrics_old_sub_count ~= lyrics_sub_count and options.lyrics_cache_loading then
        print("Subs previously downloaded - not downloading again")
    else
        lyrics_got_lyrics = false
        lyrics_musixmatch_download()
        if not lyrics_got_lyrics then
            lyrics_lrclib_download()
        end
        if lyrics_without_timestamps then
            mp.osd_message("Lyrics without timestamps downloaded automatically")
        end
        if not lyrics_got_lyrics then
            lyrics_error("Lyrics not found")
        end
    end
end

local function lyrics_get_sub_count()
    local track_list = mp.get_property_native("track-list", {})
    local sub_count = 0
    for _, track in ipairs(track_list) do
        if track["type"] == "sub" then
            sub_count = sub_count + 1
        end
    end
    return sub_count
end

local function lyrics_check_downloaded()
    lyrics_old_sub_count, lyrics_sub_count = lyrics_get_sub_count(), nil

    if lyrics_old_sub_count > 0 then
        print("Subtitles detected - aborting lyrics lookup")
        return
    end

    if options.lyrics_cache_loading then
        local current_sub_path = mp.get_property("current-tracks/sub/external-filename")
        mp.set_property("sub-file-paths", mp.command_native({ "expand-path", options.lyrics_store }))
        mp.command(current_sub_path and "sub-reload" or "rescan-external-files")
        lyrics_sub_count = lyrics_get_sub_count()
    end

    if options.lyrics_run_automatically then
        lyrics_auto_download()
    end
end

------------------------------------------------------------------
-- SUBTITLES VIA SUBLIMINAL (autosub.lua)
------------------------------------------------------------------

local sub_directory, sub_filename, sub_tracks

local function sub_download(language)
    language = language or sub_languages[1]
    if #language == 0 then
        log('No Language found\n')
        return false
    end

    log('Searching ' .. language[1] .. ' subtitles ...', 30)

    local cmd = { args = { options.subliminal_path } }
    local a = cmd.args

    for _, login in ipairs(sub_logins) do
        a[#a + 1] = login[1]
        a[#a + 1] = login[2]
        a[#a + 1] = login[3]
    end
    if options.sub_debug then
        a[#a + 1] = '--debug'
    end

    a[#a + 1] = 'download'
    if options.sub_force then
        a[#a + 1] = '-f'
    end
    if options.sub_utf8 then
        a[#a + 1] = '-e'
        a[#a + 1] = 'utf-8'
    end

    a[#a + 1] = '-l'
    a[#a + 1] = language[2]
    a[#a + 1] = '-d'
    a[#a + 1] = sub_directory
    a[#a + 1] = sub_filename

    local result = mp.utils.subprocess(cmd)

    if string.find(result.stdout, 'Downloaded 1 subtitle') then
        mp.set_property('slang', language[2])
        mp.commandv('rescan_external_files')
        log(language[1] .. ' subtitles ready!')
        return true
    else
        log('No ' .. language[1] .. ' subtitles found\n')
        return false
    end
end

local function sub_download2()
    sub_download(sub_languages[2])
end

local function sub_allowed()
    local duration = tonumber(mp.get_property('duration'))
    local active_format = mp.get_property('file-format')

    if not options.sub_auto then
        mp.msg.warn('Automatic downloading disabled!')
        return false
    elseif duration < 900 then
        mp.msg.warn('Video is less than 15 minutes\n=> NOT auto-downloading subtitles')
        return false
    elseif sub_directory:find('^http') then
        mp.msg.warn('Automatic subtitle downloading is disabled for web streaming')
        return false
    elseif active_format:find('^cue') then
        mp.msg.warn('Automatic subtitle downloading is disabled for cue files')
        return false
    else
        local not_allowed = { 'aiff', 'ape', 'flac', 'mp3', 'ogg', 'wav', 'wv', 'tta' }
        for _, file_format in pairs(not_allowed) do
            if file_format == active_format then
                mp.msg.warn('Automatic subtitle downloading is disabled for audio files')
                return false
            end
        end

        for _, exclude in pairs(sub_excludes) do
            local escaped_exclude = exclude:gsub('%W', '%%%0')
            if sub_directory:find(escaped_exclude) then
                mp.msg.warn('This path is excluded from auto-downloading subs')
                return false
            end
        end

        for i, include in ipairs(sub_includes) do
            local escaped_include = include:gsub('%W', '%%%0')
            local included = sub_directory:find(escaped_include)
            if included then
                break
            elseif i == #sub_includes then
                mp.msg.warn('This path is not included for auto-downloading subs')
                return false
            end
        end
    end

    return true
end

local function sub_should_download_in(language)
    for i, track in ipairs(sub_tracks) do
        local subtitles = track['external'] and 'subtitle file' or 'embedded subtitles'

        if not track['lang'] and (track['external'] or not track['title']) and i == #sub_tracks then
            local status = track['selected'] and ' active' or ' present'
            log('Unknown ' .. subtitles .. status)
            mp.msg.warn('=> NOT downloading new subtitles')
            return false
        elseif track['lang'] == language[3] or track['lang'] == language[2] or
            (track['title'] and track['title']:lower():find(language[3])) then
            if not track['selected'] then
                mp.set_property('sid', track['id'])
                log('Enabled ' .. language[1] .. ' ' .. subtitles .. '!')
            else
                log(language[1] .. ' ' .. subtitles .. ' active')
            end
            mp.msg.warn('=> NOT downloading new subtitles')
            return false
        end
    end
    mp.msg.warn('No ' .. language[1] .. ' subtitles were detected\n=> Proceeding to download:')
    return true
end

local function sub_control_downloads()
    mp.set_property('sub-auto', 'fuzzy')
    mp.set_property('slang', sub_languages[1][2])
    mp.msg.warn('Reactivate external subtitle files:')
    mp.commandv('rescan_external_files')
    sub_directory, sub_filename = mp.utils.split_path(mp.get_property('path'))

    if not sub_allowed() then return end

    sub_tracks = {}
    for _, track in ipairs(mp.get_property_native('track-list')) do
        if track['type'] == 'sub' then
            sub_tracks[#sub_tracks + 1] = track
        end
    end
    if options.sub_debug then
        for _, track in ipairs(sub_tracks) do
            mp.msg.warn('Subtitle track', track['id'], ':\n{')
            for k, v in pairs(track) do
                if type(v) == 'string' then v = '"' .. v .. '"' end
                mp.msg.warn('  "' .. k .. '":', v)
            end
            mp.msg.warn('}\n')
        end
    end

    for _, language in ipairs(sub_languages) do
        if sub_should_download_in(language) then
            if sub_download(language) then return end
        else
            return
        end
    end
    log('No subtitles were found')
end

------------------------------------------------------------------
-- YOUTUBE AUTO-SUBS (ytsub.lua)
------------------------------------------------------------------

local function yt_error(message)
    mp.msg.error(message)
    mp.osd_message("ytsub: " .. message, 5)
end

local function yt_notify(message)
    mp.msg.info(message)
end

local function yt_create_cache_dir()
    local res = mp.utils.file_info(options.yt_cache_dir)
    if res and res.is_dir then return end
    create_dir(options.yt_cache_dir)
end
yt_create_cache_dir()

local function yt_filter_sub(path)
    local lines = {}
    for line in io.lines(path) do
        table.insert(lines, line)
    end

    local out = io.open(path, "w")
    if out ~= nil then
        for i, line in ipairs(lines) do
            if i < 5 or i % 8 == 5 or i % 8 == 7 or i % 8 == 0 then
                out:write(line, "\n")
            end
        end
        out:close()
    end
end

local function yt_load_autosub(lang, sub_info, ytid, is_primary, select_track)
    if select_track == nil then select_track = true end
    local lang_name, url

    if sub_info ~= nil then
        for _, v in pairs(sub_info) do
            lang_name = v["name"]
            if v["ext"] == "vtt" then
                url = v["url"]
            end
        end
    end
    if lang_name == nil or url == nil then
        yt_error("could not get lang name or url from sub info")
        return
    end

    yt_notify("loading " .. lang_name)

    local subfile_base = mp.utils.join_path(options.yt_cache_dir, ytid)
    local subfile = subfile_base .. "." .. lang .. ".vtt"

    local sub_is_available = false
    local f = io.open(subfile, "r")
    if f ~= nil then
        io.close(f)
        sub_is_available = true
    else
        if http ~= nil and https ~= nil then
            local body, status = http.request(url)
            if body ~= nil and status == 200 then
                f = assert(io.open(subfile, "wb"))
                f:write(body)
                f:close()
                sub_is_available = true
            end
        end

        if not sub_is_available then
            local ytdl_path = mp.get_property_native("user-data/mpv/ytdl/path")
            if ytdl_path ~= nil then
                mp.command_native({
                    name = "subprocess",
                    args = { ytdl_path, "--skip-download", "--sub-lang", lang, "--write-auto-sub", "-o", subfile_base, "--", ytid },
                })
                f = io.open(subfile, "r")
                if f ~= nil then
                    io.close(f)
                    sub_is_available = true
                end
            end
        end

        if sub_is_available and options.yt_filter_sub_single_line then
            yt_filter_sub(subfile)
        end
    end

    if not sub_is_available then
        yt_error("failed to download " .. lang_name)
        return
    end

    if is_primary then
        mp.command("sub-add " .. subfile .. " " .. (select_track and "select" or "auto") .. " 'auto-generated' '" .. lang .. "'")
    elseif select_track then
        local n_tracks = mp.get_property_native("track-list/count")
        local n_subs = 0
        for i = 0, n_tracks - 1 do
            if mp.get_property_native("track-list/" .. i .. "/type") == "sub" then
                n_subs = n_subs + 1
            end
        end
        mp.command("sub-add " .. subfile .. " auto 'auto-generated' '" .. lang .. "'")
        mp.set_property("secondary-sid", n_subs + 1)
    else
        mp.command("sub-add " .. subfile .. " auto 'auto-generated' '" .. lang .. "'")
    end
    yt_notify(lang_name .. " loaded")
end

local function yt_is_available()
    return mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result") ~= nil
end

local function yt_download(is_auto, is_silent)
    local ytdl_output = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
    if ytdl_output == nil then
        if not is_silent then yt_error("no ytdl info available") end
        return
    end

    local j = mp.utils.parse_json(ytdl_output["stdout"])
    local subs = j["automatic_captions"]
    if subs == nil or next(subs) == nil then
        if not is_silent then yt_error("no auto-subs found") end
        return
    end

    if is_auto then
        local source_lang = options.yt_source_lang

        local has_real_subs = false
        if j["subtitles"] ~= nil then
            for k, _ in pairs(j["subtitles"]) do
                if k ~= "live_chat" then
                    has_real_subs = true
                    break
                end
            end
        end
        local select_track = not has_real_subs

        local orig_lang
        for k, _ in pairs(subs) do
            if string.find(k, "(orig)") ~= nil then
                orig_lang = k
                break
            end
        end

        yt_load_autosub(orig_lang, subs[orig_lang], j["id"], true, select_track)
        if source_lang ~= nil then
            if orig_lang == source_lang .. "-orig" then
                yt_notify("source language and original language are the same (" .. source_lang .. ")")
            else
                yt_load_autosub(source_lang, subs[source_lang], j["id"], false, select_track)
            end
        end
    else
        local langs = {}
        for k, _ in pairs(subs) do
            table.insert(langs, k)
        end

        mp.input.select({
            prompt = "Select a language",
            items = langs,
            submit = function(lang_id) yt_load_autosub(langs[lang_id], subs[langs[lang_id]], j["id"], true) end,
        })
    end
end

------------------------------------------------------------------
-- SMART DISPATCHER - the one keybind
------------------------------------------------------------------

local function is_audio_only()
    local track_list = mp.get_property_native("track-list", {})
    local has_real_video = false
    for _, track in ipairs(track_list) do
        -- exclude album-art / cover-image "video" tracks
        if track.type == "video" and not track.image and not track.albumart then
            has_real_video = true
        end
    end
    return not has_real_video
end

local function smart_subtitle_download()
    local path = mp.get_property("path") or ""

    if yt_is_available() then
        log("Downloading YouTube captions...", 2.5)
        yt_download(true, false)
        return
    end

    if is_audio_only() then
        log("Fetching lyrics...", 2.5)
        lyrics_manual_run = true
        lyrics_auto_download()
        return
    end

    log("Downloading subtitles...", 2.5)
    sub_directory, sub_filename = mp.utils.split_path(path)
    sub_tracks = {}
    for _, track in ipairs(mp.get_property_native("track-list", {})) do
        if track["type"] == "sub" then
            sub_tracks[#sub_tracks + 1] = track
        end
    end
    for _, language in ipairs(sub_languages) do
        if sub_should_download_in(language) then
            if sub_download(language) then return end
        else
            return
        end
    end
    log('No subtitles were found')
end

------------------------------------------------------------------
-- KEYBINDINGS & AUTOMATIC EVENTS
------------------------------------------------------------------

-- the new unified keybind
mp.add_key_binding(options.smart_binding, "smart-subtitle-download", smart_subtitle_download)

-- original lyrics keybindings
mp.add_key_binding(options.lyrics_musixmatch_binding, "musixmatch-download", function()
    lyrics_manual_run = true
    lyrics_auto_download()
end)
mp.add_key_binding(options.lyrics_lrclib_binding, "netease-download", function()
    lyrics_manual_run = true
    lyrics_lrclib_download()
end)
mp.add_key_binding(options.lyrics_offset_binding, "offset-sub", function()
    local sub_path = mp.get_property("current-tracks/sub/external-filename")
    if not sub_path then
        lyrics_error("No external subtitle is loaded")
        return
    end
    mp.set_property("sub-delay", mp.get_property_number("playback-time"))
    mp.command("sub-reload")
    mp.osd_message("Subtitles updated")
end)

-- original Subliminal keybindings
mp.add_key_binding(options.sub_download_binding, "download_subs", sub_download)
mp.add_key_binding(options.sub_download2_binding, "download_subs2", sub_download2)
mp.register_event('file-loaded', sub_control_downloads)

-- original YouTube keybindings
mp.add_key_binding(options.yt_select_binding, "ytsub-select", function() yt_download(false) end)
mp.add_key_binding(options.yt_autoload_binding, "ytsub-autoload", function() yt_download(true) end)
if options.yt_autoload_on_start then
    mp.register_event("file-loaded", function() yt_download(true, true) end)
end

-- original lyrics on-load cache check / auto-run
lyrics_check_downloaded()
