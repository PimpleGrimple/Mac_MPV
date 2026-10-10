> [!NOTE]  
> Not tested on MBP if you know a confirmed working setup to allow hdr passthrough there pls send.

---

## Table of Contents

1. [Highlights](#1-highlights)
2. [Custom MPV Development Build (`mpv.zip`)](#2-custom-mpv-development-build-mpvzip)
3. [System Dependencies](#3-system-dependencies)
4. [Installation & Setup](#4-installation--setup)
5. [MPV Launcher (`mpv-launcher.py`) & System Integration](#5-mpv-launcher-mpv-launcherpy--system-integration)
6. [Browser Extensions & Native Messaging](#6-browser-extensions--native-messaging)
7. [Scripts & Automation Suite](#7-scripts--automation-suite)
8. [Credits & References](#8-credits--references)
9. [License](#9-license)

---

## 1. Highlights

- **Custom-Patched MPV Dev**: Standalone `mpv.app` compiled from upstream dev (`master`) with inverse tone mapping (ITM) color-fix patches, macOS CoreAudio multi-channel fixes, and native VapourSynth bridge support.
- **Browser setup**: Universal smart launcher (`mpv-launcher.py`), Chromium MediaBlocker extension with format and bitrate inspection.
---

## 2. Custom MPV Development Build (`mpv.zip`)

The custom development build is built with the following toolchain parameters and flags:
- **Base Version**: `mpv master` (commit `g36abaa32d-dirty`, report version `0.41.0-dev`).
- **libplacebo Version**: `v7.360.1` (with Vulkan, LCMS2, and the SDR->HDR ITM desaturation patch applied).
- **VapourSynth Integration**: Linked against modern VapourSynth header and dylib tree (`--vf=vapoursynth` bridge enabled via dynamic runtime loader).
- **CoreAudio Fix**: Anki commit `a9a9e5e` channel-map fix applied to `audio/out/ao_coreaudio.c`.
- **Packaging**: Self-contained `.app` bundle with internal dynamic library paths re-linked (`install_name_tool`) and standalone MoltenVK ICD manifest embedded.

---
## 3. System Dependencies

### Homebrew Packages
```bash
brew install yt-dlp ffmpeg deno alass subliminal dovi_tool hdr10plus_tool mkvtoolnix
```

| Package | Required By | Purpose |
| :--- | :--- | :--- |
| `yt-dlp` | ModernX, SelectFormat, Cookie Cache, Launcher | Media stream extraction & format selection |
| `ffmpeg` | ReplayGain, SmartCut, AutoSubSync, Auto Brightness | Loudness scanning, GOP trimming, HDR analysis |
| `deno` | yt-dlp | Fast JavaScript engine for YouTube extraction challenges |
| `alass` | AutoSubSync (`scripts/autosubsync/`) | Voice-activity subtitle synchronization |
| `subliminal` | Subtitles (`scripts/subtitles.lua`) | Subtitle searching & download |
| `dovi_tool` | Auto Brightness (`scripts/auto-brightness/`) | Dolby Vision RPU bitstream metadata extraction |
| `hdr10plus_tool` | Auto Brightness (`scripts/auto-brightness/`) | HDR10+ dynamic metadata extraction |
| `mkvtoolnix` | VapourSynth (`vsprocess`) | Container remuxing and chapter preservation |

### Python Environments
* **SmartCut**:
  ```bash
  python3 -m venv ~/.local/pipx/venvs/smartcut
  ~/.local/pipx/venvs/smartcut/bin/pip install av bitstring numpy pillow tqdm
  ```

---

## 4. Installation & Setup

1. **Clone the Configuration**:
   ```bash
   git clone https://github.com/PimpleGrimple/Mac_MPV.git ~/.config/mpv
   chmod +x ~/.config/mpv/mpv-launcher.py
   ```

2. **Deploy the Custom MPV Build**:
   Unpack `mpv.zip` into your `/Applications` or user `~/Applications` folder:
   ```bash
   unzip -q ~/.config/mpv/mpv.zip -d /Applications/
   ```

3. **Install Fonts**:
   Unpack `fonts.zip` and install the fonts into macOS Font Book:
   ```bash
   unzip -o ~/.config/mpv/fonts.zip -d ~/.config/mpv/
   ```
   Install `fluent-system-icons.ttf`, `Segoe UI Semibold.ttf`, and `AOTFShinGoProMedium.otf` from `~/.config/mpv/fonts/`.

4. **Configure yt-dlp (Optional)**:
   ```bash
   mkdir -p ~/.config/yt-dlp
   cat << 'EOF' > ~/.config/yt-dlp/config
   --cookies "~/.config/mpv/cache/scripts/cookies.txt"
   --force-ipv4 --retries 10 --fragment-retries 10 --socket-timeout 30 --concurrent-fragments 4
   --embed-thumbnail --embed-metadata --embed-subs --sub-langs "en.*,-live_chat" --merge-output-format mkv
   EOF
   ```

---

## 5. MPV Launcher (`mpv-launcher.py`) & System Integration

`mpv-launcher.py` coordinates macOS application launching (`open -n -b io.mpv`), single-instance IPC queuing (`~/.config/mpv/cache/fallback.sock`), optical disc mounting, and browser native messaging.

### Methods of Use

* **Method 1: Zero-Argument Smart Trigger (Universal Hotkey)**  
  When triggered without arguments (e.g., via Raycast, Alfred, Shortcuts, or `skhd`):
  1. **Finder Selection**: If files or folders are highlighted in Finder, plays them immediately.
  2. **Clipboard Fallback**: If nothing is selected, inspects clipboard (`pbpaste`) for a web URL or local path and plays it.
  > *Tip: Bind `Cmd+Opt+V` to `~/.config/mpv/mpv-launcher.py`.*

* **Method 2: Automator Quick Action (Right-Click Context Menu)**  
  1. Open **Automator.app** $\rightarrow$ **Quick Action**.
  2. Set **Workflow receives current**: `files or folders` in `Finder.app`.
  3. Add **Run Shell Script** (`/bin/zsh`, pass input `as arguments`):
     ```zsh
     ~/.config/mpv/mpv-launcher.py "$@"
     ```
  4. Save as **"Open with MPV"**.

* **Method 3: Terminal / CLI**  
  ```bash
  # Files or playlists
  ~/.config/mpv/mpv-launcher.py video1.mkv video2.mp4

  # Recursive folder playback
  ~/.config/mpv/mpv-launcher.py ~/Movies/Series/Season-01/

  # Web streaming
  ~/.config/mpv/mpv-launcher.py "https://www.youtube.com/watch?v=..."
  ```

* **Method 4: DVD & Blu-ray Detection**  
  Folders containing `VIDEO_TS` or `BDMV` are automatically mounted via `--dvd-device=... dvd://` or `--bluray-device=... bluray://`.

---

## 6. Browser Extensions & Native Messaging

* **Play in MPV**: [Chrome Web Store](https://chromewebstore.google.com/detail/njlpgpceeekkodgehpehlngpoeilcncf?utm_source=item-share-cb) — Adds browser toolbar buttons and context menu actions to send links directly to mpv.
* **Media Blocker (`MediaBlocker/`)**: Unpacked Manifest V3 extension in `~/.config/mpv/MediaBlocker/`. Intercepts media stream requests (`.m3u8`, `.mpd`, `.mp4`) before web players initialize. Provides instant quality and bitrate selection, codec inspection (AV1, HEVC, VP9, H.264), direct stream playback, and `#MBSTREAM` payload copying.

### Register Native Messaging Host
```bash
mkdir -p ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts
cat << EOF > ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts/com.playinmpv.host.json
{
  "name": "com.playinmpv.host",
  "description": "MPV Launcher Native Messaging Host",
  "path": "$HOME/.config/mpv/mpv-launcher.py",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://njlpgpceeekkodgehpehlngpoeilcncf/",
    "chrome-extension://phbnnepeojngejmloimciipldpddlnii/"
  ]
}
EOF
```

---

## 7. Scripts & Automation Suite

### Video Restoration & Cadence
* **Deinterlace (`scripts/deint.lua`)**:
  - Bound to `x`. Runs deep cadence analysis on the active video using `vsdetect` from the VapourSynth bundle.
  - Instantly reveals progressive vs. interlaced status, 3:2 pulldown cadence, repeated frame ratios, field order, and suggested deinterlacing strategies.
  - Applies the best basic mpv filters and shaders to deinterlace it
* **SmartCut (`scripts/smartcut/`)**:
  - Frame-accurate lossless cutter. Re-encodes only the GOP-boundary edges with CRF 10 and stream-copies all intermediate frames.
  - `k`: Mark A / Mark B $\rightarrow$ trigger background cut | `K`: Cycle modes (`smartcut`, `compress`, `pansmash`, `gif`) | ` ` ` (backtick): Process console.

### Unified Auto-Skip Suite (`scripts/auto-skip/`)
Consolidates all segment skipping into an efficient, centralized engine:
* **AniSkip (`aniskip.lua`)**: Queries the AniSkip API to automatically or manually skip anime opening and ending sequences (`Alt+s` / `ENTER`).
* **SponsorBlock (`sponsorblock.lua` & `sponsorblock.py`)**: Skips YouTube sponsor segments, intros, outros, and self-promotion. Vote on segments with `H`.
* **TheIntroDB (`theintrodb.lua`)**: Automatically skips TV show intro sequences using community timestamps.
* **Local Chapters (`localchapters.lua`)**: Matches chapter titles for local opening/ending skips.

### Display & Backlight Control
* **Auto Brightness & CABC (`scripts/auto-brightness/`) [WIP may be removed]**:
  - Dynamic Content-Adaptive Backlight Control (CABC) and optical gain management for Liquid Retina / XDR panels.
  - Reduces backlight on dark scenes to minimize IPS glow, applying highlight compensation via GLSL hook (`cabc_gain.hook`).
  - Fast Dolby Vision and HDR10+ metadata extraction via `dovi_tool` and `hdr10plus_tool`.
  - `Alt+b`: HUD | `Ctrl+g`: Optical gain | `Alt+h`: Highlight recovery | `Alt+l`: Live CABC.
* **Dynamic 3D LUT Switcher (`scripts/lut.lua`)**: Switch `.cube` / `.3dl` color grading LUTs in `~/.config/mpv/luts/` (`e` / `E`).
* **Battery Saver (`scripts/battery.lua`)**: Monitors power state via `pmset` and toggles between high-power shaders and efficient battery profiles (`B`).

### Audio & Normalization
* **ReplayGain (`scripts/replaygain.lua`)**: EBU R128 loudness normalization scanning via `ffmpeg` to `-14 LUFS`.
  - `meta+s`: Scan current file | `meta+i`: Show stats | `meta+up`/`meta+down`: $\pm 1\text{ dB}$ | `meta+b`: Hardbake tags | `meta+r`: Reset.

### Subtitles & Audio Sync
* **Subtitles & Lyrics (`scripts/subtitles.lua`)**: Online subtitle search via Subliminal; synchronized karaoke lyrics via Musixmatch & LRCLIB.
  - `q` / `Q`: Smart download / manual search primary subtitles | `Ctrl+q` / `Ctrl+Q`: Secondary subtitles.
* **AutoSubSync (`scripts/autosubsync/`)**: Voice-activity subtitle synchronization against audio track via `alass` (`n`).
* **Sub-Pause & Sub-Skip (`scripts/sub-pause.lua`, `scripts/sub-skip.lua`)**:
  - `'`: Auto-pause at end of subtitle | `;`: Jump to next subtitle line | `Alt+l`: Replay line | `\`: Toggle silence skip.
* **Styles Menu (`scripts/styles.lua` + `script-modules/menu.lua`)**:
  - Interactive on-screen menu (`Alt+u`) for cycling custom subtitle font styles and appearance presets defined in `styles.conf`.

### Navigation & Management
* **ModernX OSC (`scripts/modernx.lua`)**: Fluent-design on-screen controller with seekbar hover thumbnails (`scripts/thumbfast.lua`).
* **Format Selector (`scripts/select-format.lua`)**: In-player quality and stream selector for YouTube and multi-track media (`y`).
* **Playlist Manager (`scripts/playlist-manager.lua`)**: Interactive playlist navigation and file management (`p`).
* **Screenshot Folder (`scripts/screenshot-folder.lua`)**: Saves titled screenshots, video frame grabs, and copies directly to clipboard (`s`, `j`, `O`).
* **CopyPaste (`scripts/copypaste.lua`)**: Clipboard stream URL pasting and path copying (`meta+c`, `meta+v`).
* **Picture-in-Picture (`scripts/pip.lua`)**: Toggles borderless, aspect-locked floating window (`Alt+p`).
* **Auto Save State (`scripts/auto-save.lua`)**: Persists playback position, selected audio track, and subtitle track across sessions.

---

## 8. Credits & References

- **Base Setup**: [zydezu/mpvconfig](https://github.com/zydezu/mpvconfig)
- **Shaders, Profiles & LUTs**: [hooke007/mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit)
- **Shaders, Profiles**: [he2a/mpv-config](https://github.com/he2a/mpv-config)
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

## 9. License

This configuration, custom scripts, and extensions (`MediaBlocker`, `mpv-launcher.py`, build scripts) are licensed under the [MIT License](LICENSE). Third-party scripts, shaders, and tools remain licensed under their respective original terms.
