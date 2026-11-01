> [!NOTE]  
> Not tested on MacBook Pro. If you know a confirmed working setup for HDR passthrough on MBP, please open an issue or PR.

---

## Table of Contents

1. [Custom MPV Development Build (`mpv.zip`)](#1-custom-mpv-development-build-mpvzip)
2. [System Dependencies](#2-system-dependencies)
3. [Installation & Setup](#3-installation--setup)
4. [MPV Launcher (`mpv-launcher.py`) & System Integration](#4-mpv-launcher-mpv-launcherpy--system-integration)
5. [Browser Extension & Native Messaging](#5-browser-extension--native-messaging)
6. [Scripts & Automation Suite](#6-scripts--automation-suite)
7. [Credits & References](#7-credits--references)
8. [License](#8-license)

---

## 1. Custom MPV Development Build (`mpv.zip`)

Custom development build compiled with the following flags and integrations:
- **Base Version**: `mpv master` (commit `g82667e3cb-dirty`, version report `0.41.0-dev`).
- **libplacebo Version**: `v7.373.0` (Metal backend fork with `gpu-api=metal`, Vulkan, LCMS2, and SDR-to-HDR ITM desaturation patch).
- **Integrated Disc Support**: Linked with `libbluray`, `dvdnav`, and `dvda` for native Blu-ray and DVD playback.
- **VapourSynth Integration**: Dynamic runtime bridge (`--vf=vapoursynth`) linked against modern VapourSynth.
- **CoreAudio Fix**: Channel-map fix (commit `a9a9e5e`) applied to `audio/out/ao_coreaudio.c`.
- **Packaging**: Self-contained `.app` bundle with internal dynamic library paths re-linked (`install_name_tool`) and embedded MoltenVK ICD manifest.

---
## 2. System Dependencies

### Homebrew Packages
```bash
brew install yt-dlp ffmpeg deno alass subliminal mkvtoolnix
```

| Package | Required By | Purpose |
| :--- | :--- | :--- |
| `yt-dlp` | ModernX, SelectFormat, Cookie Cache, Launcher | Media stream extraction & format selection |
| `ffmpeg` | ReplayGain, SmartCut, AutoSubSync, Remux | Loudness scanning, GOP trimming, subtitle sync, remuxing |
| `deno` | yt-dlp | Fast JavaScript engine for YouTube extraction challenges |
| `alass` | AutoSubSync (`scripts/autosubsync/`) | Voice-activity subtitle synchronization |
| `subliminal` | Subtitles (`scripts/subtitles.lua`) | Subtitle searching & download |
| `mkvtoolnix` | Chapter Maker (`scripts/chapter_maker.lua`) | Chapter embedding and MKV metadata editing |

### Python Environments
* **SmartCut**:
  ```bash
  python3 -m venv ~/.local/pipx/venvs/smartcut
  ~/.local/pipx/venvs/smartcut/bin/pip install av bitstring numpy pillow tqdm
  ```

---

## 3. Installation & Setup

1. **Clone the Configuration**:
   ```bash
   git clone https://github.com/PimpleGrimple/Mac_MPV.git ~/.config/mpv
   chmod +x ~/.config/mpv/mpv-launcher.py
   ```

2. **Install MPV App**:
   Unpack `mpv.zip` into `/Applications` (or `~/Applications`):
   ```bash
   unzip -q ~/.config/mpv/mpv.zip -d /Applications/
   ```

3. **Install Fonts**:
   Unpack `fonts.zip` and open the fonts to install them into Font Book:
   ```bash
   unzip -o ~/.config/mpv/fonts.zip -d ~/.config/mpv/
   ```
   Install `fluent-system-icons.ttf`, `Segoe UI Semibold.ttf`, and `AOTFShinGoProMedium.otf` from `~/.config/mpv/fonts/`.

4. **Directory Setup & Aliases**:
   Create screenshot/config folders and symlinks:
   ```bash
   mkdir -p ~/.config/yt-dlp ~/Pictures/mpv/screenshots
   ln -s ~/Pictures/mpv ~/.config/mpv/screenshot
   ln -s ~/.config/yt-dlp/config ~/.config/mpv/"ytdlp config"
   ```

5. **Configure yt-dlp**:
   ```bash
   cat << 'EOF' > ~/.config/yt-dlp/config
   # Anti-Bot & Auth
   #--extractor-args "youtubepot-wpc:browser_path=/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
   #--impersonate chrome
   --cookies "~/.config/mpv/cache/scripts/cookies.txt"
   #--mark-watched # not working

   # Network Stability
   --force-ipv4
   --retries 10
   --fragment-retries 10
   --socket-timeout 30
   --concurrent-fragments 4
   --compat-options allow-unsafe-ext
   #--downloader=ffmpeg
   #--format="bestvideo[height<=?1440]+bestaudio/best"

   # Post-Processing & Output
   --embed-thumbnail
   --embed-metadata
   --embed-subs
   --sub-langs "en.*,-live_chat"
   --no-write-comments
   --remux-video mkv
   --merge-output-format mkv
   EOF
   ```

6. **Set Up macOS Quick Action / Keybind**:
   Create the Automator Quick Action(s) as documented in [Section 4](#4-mpv-launcher-mpv-launcherpy--system-integration) and assign hotkeys in **System Settings** → **Keyboard** → **Keyboard Shortcuts...** → **Services** → **General**.

---

## 4. MPV Launcher (`mpv-launcher.py`) & System Integration

`mpv-launcher.py` handles application launching (`open -n -b io.mpv`), single-instance IPC queuing (`~/.config/mpv/cache/fallback.sock`), optical disc mounting, and browser native messaging.

### Automator Quick Actions

You can set up either (or both) of these Quick Actions in **Automator.app**:

* **1. Universal Hotkey (Finder + Clipboard Fallback)**  
  - In Automator: create a **Quick Action**, set workflow receives **no input** in **any application**.
  - Add **Run Shell Script** (`/bin/zsh`):
    ```zsh
    $HOME/.config/mpv/mpv-launcher.py
    ```
  - **Behavior**: Checks highlighted items in Finder, or falls back to playing clipboard URLs/paths via macOS `pbpaste`.  
  - *Trade-off*: Can occasionally be inconsistent at reading Finder selection, and will not appear in Finder's right-click context menu.

* **2. Finder Right-Click Menu (Direct Selection)**  
  - In Automator: create a **Quick Action**, set workflow receives **files or folders** in **Finder.app**.
  - Add **Run Shell Script** (`/bin/zsh`, pass input **as arguments**):
    ```zsh
    "$HOME/.config/mpv/mpv-launcher.py" "$@"
    ```
  - **Behavior**: Appears directly in Finder's right-click menu (**Quick Actions** → **MPV**) and reliably opens the selected files/folders.  
  - *Trade-off*: Disables the clipboard fallback function because input is strictly bound to selected files.

Assign shortcuts for either service in **System Settings** → **Keyboard** → **Keyboard Shortcuts** → **Services** → **General**.

### DVD & Blu-ray Auto-Mount
Folders containing `VIDEO_TS` or `BDMV` are automatically mounted via `--dvd-device=... dvd://` or `--bluray-device=... bluray://`.

---

## 5. Browser Extension & Native Messaging

* **Media Blocker (`MediaBlocker/`)**: Unpacked Manifest V3 extension in `~/.config/mpv/MediaBlocker/` (merges stream detection and Play in MPV into one extension).
  - Intercepts stream requests (`.m3u8`, `.mpd`, `.mp4`) before web players load. Provides quality/bitrate selection, codec inspection (AV1, HEVC, VP9, H.264), direct stream playback, and `#MBSTREAM` payload copying.
  - Adds a one-click **Play in MPV** button on YouTube, context menu options, and toolbar popup (`Alt+M` popup menu, `Alt+P` play active tab).

### Setup

1. **Load Extension in Chrome**:
   - Open `chrome://extensions` and enable **Developer mode**.
   - Click **Load unpacked** and select `~/.config/mpv/MediaBlocker/`.

2. **Register Native Messaging Host**:
```bash
mkdir -p ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts
cat << EOF > ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts/com.playinmpv.host.json
{
  "name": "com.playinmpv.host",
  "description": "MPV Launcher Native Messaging Host",
  "path": "$HOME/.config/mpv/mpv-launcher.py",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://jejmniblnialndgjpkpfammnohfgljdi/"
  ]
}
EOF
```
> [!NOTE]
> A fixed public key is embedded in `manifest.json`, ensuring the extension ID (`jejmniblnialndgjpkpfammnohfgljdi`) stays identical across all machines.

---

## 6. Scripts & Automation Suite

* **deint.lua**:
  - Bound to `x`. Runs cadence analysis via `vsdetect` to detect progressive/interlaced video, 3:2 pulldown, and field order.
  - Automatically applies the best mpv filters and shaders to deinterlace.
* **smartcut**:
  - Frame-accurate lossless cutter. Re-encodes only GOP-boundary edges with CRF 10 and stream-copies intermediate frames.
  - `k`: Mark A / Mark B → trigger background cut | `K`: Cycle modes (`smartcut`, `compress`, `pansmash`, `gif`) | `` ` `` (backtick): Process console.
* **remux**:
  - Lossless remuxing and track manager via `ffmpeg -c copy`. Reorders and toggles video, audio, and subtitle tracks, delays, chapters, and font attachments.
  - `Ctrl+R`: Toggle menu | `Ctrl+Alt+r`: Immediate export.
* **auto_skip**:
  Consolidates all segment skipping into one engine:
  - **aniskip.lua**: Skips anime opening and ending sequences via the AniSkip API (`Alt+s` / `ENTER`).
  - **sponsorblock.lua**: Skips YouTube sponsor segments, intros, outros, and self-promotion.
  - **theintrodb.lua**: Skips TV show intro sequences using community timestamps.
  - **localchapters.lua**: Matches chapter titles for local opening/ending skips.
  - `Alt+s`: Toggle auto-skip | `Alt+R`: Force rescan.
* **auto_brightness.lua**:
  - Automatically adjusts target peak brightness for SDR, inverse tone mapping, and HDR on Liquid Retina / XDR displays.
* **lut.lua**: Switch `.cube` / `.3dl` color grading LUTs in `~/.config/mpv/luts/` (`e` / `E`).
* **battery.lua**: Monitors power state via `pmset` and toggles between high-power shaders and efficient battery profiles (`B`).
* **replaygain.lua**: EBU R128 loudness normalization scanning via `ffmpeg` to `-14 LUFS`.
  - `meta+s`: Scan current file | `meta+i`: Show stats | `meta+up`/`meta+down`: ±0.1 dB | `meta+b`: Hardbake tags | `meta+r`: Reset.
* **subtitles.lua**: Online subtitle search via Subliminal; synchronized karaoke lyrics via Musixmatch & LRCLIB.
  - `q`: Smart download primary subtitles | `Q`: Manual search.
* **smart_subs.lua**:
  - Automatically selects the best subtitle track matching `slang` based on priority keywords (`dialogue`, `full`, `complete`) and filters out unwanted tracks (`signs`, `songs`, `commentary`).
* **autosubsync**: Voice-activity subtitle synchronization against audio track via `alass` (`n`).
* **sub_pause.lua**: Auto-pause at start of subtitle (`"`), auto-pause at end of subtitle (`'`), jump to next subtitle line (`;`), replay line (`l`).
* **sub_skip.lua**: Auto-skip or speed-up gaps between subtitle lines (`\` toggle, `|` switch speed/seek mode).
* **styles.lua**: Interactive on-screen menu (`g-u`), forward (`u`), backward (`U`), reset default (`g-U`) for cycling custom subtitle font styles and appearance presets defined in `styles.conf`.
* **chapter_maker.lua**:
  - Interactive chapter creation, splitting, A-B loop conversion, renaming, and MKV embedding via `mkvpropedit`.
  - `c`: Split chapter | `Alt+m`: Mark A-B chapter | `Alt+r`: Rename chapter | `Alt+d`: Remove chapter | `Alt+z`: Undo | `Alt+e`: Export sidecar | `Alt+w`: Embed into MKV.
* **modernx.lua**: Fluent-design on-screen controller with seekbar hover thumbnails (`thumbfast.lua`).
* **thumbfast.lua**: On-the-fly seekbar thumbnail generation.
* **selectformat.lua**: In-player quality and stream selector for YouTube and multi-track media (`y`).
* **playlist_manager.lua**: Interactive playlist navigation and file management via `mp.input` (`meta+p`: Menu | `meta+f`: Favorite | `meta+W`: Watch later | `ctrl+e`: Export playlist).
* **screenshot_folder.lua**: Saves titled screenshots to media-specific folders and copies directly to clipboard (`j`: Video frame grab | `Alt+j`: Screenshot with subtitles | `J`: Window screenshot).
* **copypaste.lua**: Clipboard stream URL pasting and path copying (`meta+c`: Copy path/URL or active subtitle | `meta+v`: Paste and play | `meta+alt+c`: Copy timestamp).
* **pip.lua**: Toggles borderless, aspect-locked floating window (`Alt+p` / `π`).
* **auto_save.lua**: Persists playback position, selected audio track, and subtitle track across sessions.
* **cookie_cache.lua**: Extracts and caches browser cookies for yt-dlp playback.

---

## 7. Credits & References

- **Base Setup**: [zydezu/mpvconfig](https://github.com/zydezu/mpvconfig)
- **Shaders, Profiles & LUTs**: [hooke007/mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit)
- **Shaders, Profiles**: [he2a/mpv-config](https://github.com/he2a/mpv-config)
- **AltScale**: [garamond13/AltScale](https://github.com/garamond13/AltScale)
- **libplacebo Metal Fork**: [ab300819/libplacebo (metal-backend)](https://github.com/ab300819/libplacebo/tree/metal-backend)
- **The Stream Detector**: [54ac/stream-detector](https://github.com/54ac/stream-detector) (stream detection basis for Media Blocker)
- **Play in MPV Extension**: [franciscobecheli/play-in-mpv](https://github.com/franciscobecheli/play-in-mpv) by Francisco Becheli (native host bridge and player integration basis for Media Blocker)
- **SmartCut**: [skeskinen/smartcut](https://github.com/skeskinen/smartcut)
- **AutoSubSync**: [joaquinteixeira/mpv-autosubsync](https://github.com/joaquinteixeira/mpv-autosubsync) & [kaegi/alass](https://github.com/kaegi/alass)
- **SponsorBlock**: [Ajayyy/SponsorBlock](https://github.com/ajayyy/SponsorBlock) & [po5/mpv_sponsorblock](https://github.com/po5/mpv_sponsorblock)
- **Thumbfast**: [po5/thumbfast](https://github.com/po5/thumbfast)
- **SelectFormat**: [koonix/mpv-selectformat](https://github.com/koonix/mpv-selectformat)
- **Subliminal**: [Diaoul/subliminal](https://github.com/Diaoul/subliminal)
- **Subskip & Subpause**: [Ben-Kerman/mpv-sub-scripts](https://github.com/Ben-Kerman/mpv-sub-scripts)
- **libplacebo Patch Reference**: [haasn/libplacebo#378](https://github.com/haasn/libplacebo/issues/378)
- **CoreAudio Patch Reference**: [mpv-player/mpv commit a9a9e5e](https://github.com/mpv-player/mpv)

---

## 8. License

This configuration, custom scripts, and extensions (`MediaBlocker`, `mpv-launcher.py`, build scripts) are licensed under the [MIT License](LICENSE). Third-party scripts, shaders, and tools remain licensed under their respective original terms.
