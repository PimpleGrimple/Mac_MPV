# macOS mpv Configuration

A performance-tuned [mpv](https://mpv.io) configuration designed for macOS (Apple Silicon and Liquid Retina / XDR displays). Features hardware-accelerated decoding, custom shaders, browser native messaging, intelligent audio equalization, and extensive script automation.

> [!NOTE]  
> Not tested on MacBook Pro (MBP). If you have a confirmed working HDR passthrough setup to utilize full panel brightness there, please feel free to share!

---

## Table of Contents
1. [Dependencies](#1-dependencies)
2. [Installation & Setup](#2-installation--setup)
3. [MPV Launcher (`mpv-launcher.py`)](#3-mpv-launcher-mpv-launcherpy)
4. [Browser Extensions & Native Messaging](#4-browser-extensions--native-messaging)
5. [Scripts & Capabilities](#5-scripts--capabilities)
6. [Credits](#6-credits)
7. [License](#7-license)

---

## 1. Dependencies

### Homebrew Packages
```bash
brew install mpv yt-dlp ffmpeg deno alass subliminal dovi_tool hdr10plus_tool pipx
```

| Package | Required By | Functional Purpose |
| :--- | :--- | :--- |
| `mpv` | Core | Video player backend |
| `yt-dlp` | ModernX, SelectFormat, Cookie Cache, Launcher | YouTube & web stream extraction backend |
| `ffmpeg` | ReplayGain, SmartCut, AutoSubSync, Auto Brightness | Encoding, loudness scanning, HDR signal analysis |
| `deno` | yt-dlp | Fast JS runtime for YouTube extraction challenges |
| `alass` | AutoSubSync (`scripts/autosubsync/`) | Voice-activity subtitle synchronization |
| `subliminal` | Subtitles (`scripts/subtitles.lua`) | CLI subtitle provider search & download |
| `dovi_tool` | Auto Brightness (`scripts/auto-brightness/`) | Dolby Vision RPU bitstream metadata extraction |
| `hdr10plus_tool` | Auto Brightness (`scripts/auto-brightness/`) | HDR10+ dynamic metadata extraction |
| `pipx` | AirPods FIR EQ (`scripts/airpodsEQ/`) | Isolated runner for impulse response generation |

### Python Environments
* **SmartCut**:
  ```bash
  python3 -m venv ~/.local/pipx/venvs/smartcut
  ~/.local/pipx/venvs/smartcut/bin/pip install av bitstring numpy pillow tqdm
  ```
* **AirPods FIR EQ** (`scripts/airpodsEQ/`): Runs directly via `pipx` (dependencies defined inline) or `pip install numpy scipy`.

---

## 2. Installation & Setup

1. **Clone configuration**:
   ```bash
   git clone https://github.com/PimpleGrimple/Mac-MPV.git ~/.config/mpv
   chmod +x ~/.config/mpv/mpv-launcher.py
   ```

2. **Configure yt-dlp (optional)**:
   Point yt-dlp to mpv's cookie cache and optimize downloads in `~/.config/yt-dlp/config`:
   ```bash
   mkdir -p ~/.config/yt-dlp
   cat << 'EOF' > ~/.config/yt-dlp/config
   --cookies "~/.config/mpv/cache/scripts/cookies.txt"
   --force-ipv4 --retries 10 --fragment-retries 10 --socket-timeout 30 --concurrent-fragments 4
   --embed-thumbnail --embed-metadata --embed-subs --sub-langs "en.*,-live_chat" --merge-output-format mkv
   EOF
   ```

3. **Install Fonts**:
   Unpack `fonts.zip` and install the fonts into macOS Font Book:
   ```bash
   unzip -o ~/.config/mpv/fonts.zip -d ~/.config/mpv/
   ```
   Install `fluent-system-icons.ttf`, `Segoe UI Semibold.ttf`, and `AOTFShinGoProMedium.otf` from `~/.config/mpv/fonts/`.

---

## 3. MPV Launcher (`mpv-launcher.py`)

`mpv-launcher.py` coordinates macOS app launching (`open -n -b io.mpv`), single-instance IPC queuing (`~/.config/mpv/cache/fallback.sock`), disc mounting, and browser native messaging. It auto-rotates its error log (`launcher-error.log` kept under 512 KB) and cleans stale pipe runs (> 48h).

### Usage Methods

* **Method 1: Zero-Argument Smart Trigger (Universal Hotkey)**  
  When run with no arguments (e.g. via macOS Shortcut, Raycast, Alfred, or `skhd`), it automatically resolves what to play:
  1. **Finder Selection**: If files or folders are highlighted in Finder, opens them immediately.
  2. **Clipboard Fallback**: If nothing is selected, inspects clipboard (`pbpaste`) for a web URL (`http://`, `https://`) or a local path and plays it.
  > *Tip: Bind a single global hotkey like `Cmd+Opt+V` to `~/.config/mpv/mpv-launcher.py` to play either highlighted Finder items or copied video links instantly.*

* **Method 2: Automator Quick Action (Right-Click Context Menu)**  
  Create a Finder context menu item:
  1. Open **Automator.app** -> **New Document** -> **Quick Action**.
  2. Set **Workflow receives current**: `files or folders` in `Finder.app`.
  3. Add **Run Shell Script** (`/bin/zsh`, pass input `as arguments`):
     ```zsh
     ~/.config/mpv/mpv-launcher.py "$@"
     ```
  4. Save as **"Open with MPV"**.

* **Method 3: Terminal / CLI**  
  ```bash
  # Files or playlists (first replaces, subsequent append)
  ~/.config/mpv/mpv-launcher.py video1.mkv video2.mp4

  # Recursive folder playback (automatically adds --directory-mode=recursive)
  ~/.config/mpv/mpv-launcher.py ~/Movies/Series/Season-01/

  # Web streaming with stream-cache flags pre-injected
  ~/.config/mpv/mpv-launcher.py "https://www.youtube.com/watch?v=..."

  # Pass custom mpv flags before targets
  ~/.config/mpv/mpv-launcher.py --fs --volume=75 -- video.mkv
  ```

* **Method 4: DVD & Blu-ray Directory Detection**  
  Directories containing `VIDEO_TS` or `BDMV` are automatically recognized and mounted via `--dvd-device=... dvd://` or `--bluray-device=... bluray://`.

* **Method 5: Browser Native Messaging Host**  
  Acts as a native messaging backend (`com.playinmpv.host`) communicating via JSON over `stdin`/`stdout`:
  - `PLAY`: Streams web video with custom titles, referrers, user agents, and format overrides.
  - Pipe Streaming: Piped `yt-dlp` $\rightarrow$ `mpv -` playback for custom/token streams with a 20s stall watchdog.
  - `DOWNLOAD`: Dispatches background downloads to Terminal with lockfile tracking (`dl-locks/`).
  - `FETCH_MANIFEST`: Bypasses web-player CORS restrictions via native `curl`.
  - `CHECK_STATUS`: Handshake verifying `yt-dlp` and `mpv` binary paths.

---

## 4. Browser Extensions & Native Messaging

Two browser extensions communicate directly with `mpv-launcher.py`:

* **Play in MPV**: [Chrome Web Store](https://chromewebstore.google.com/detail/njlpgpceeekkodgehpehlngpoeilcncf?utm_source=item-share-cb) — Adds browser buttons and context menu items to send links directly to mpv.
* **Media Blocker (`MediaBlocker/`)**: Unpacked Manifest V3 extension in `~/.config/mpv/MediaBlocker/`. Intercepts media stream requests (`.m3u8`, `.mpd`, `.mp4`) before web players initialize, rendering an overlay to **"Open in MPV"** or **"Download"**.

### Native Messaging Manifest Setup
Register the host for Chromium browsers:

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
*(For Brave or Edge, adjust directory to `Application Support/BraveSoftware/Brave-Browser/...` or `Application Support/Microsoft Edge/...`)*

---

## 5. Scripts & Capabilities

### Trimming & Encoding
* **SmartCut (`scripts/smartcut/`) (WIP)**: In-player smart trimmer. Lossless cuts re-encode GOP-boundary edges at CRF 10 and stream-copy intermediate frames.
  * `k`: First press sets Mark A; second press sets Mark B and launches background cut.
  * `K`: Cycle modes: `smartcut` (near-lossless MKV), `compress` (CRF 10), `pansmash` (panoramic image), `gif` (animated GIF).
  * ` ` ` (backtick): Monitor background process output in mpv console.

### Display & Color Management
* **Auto Brightness & CABC (`scripts/auto-brightness/`) (WIP)**: Dynamic backlight and optical gain manager for Liquid Retina / XDR panels.
  * CABC lowers hardware backlight on dark frames to reduce IPS glow and boosts highlights via GLSL hook (`cabc_gain.hook`).
  * Fast Dolby Vision / HDR10+ metadata extraction via `dovi_tool` and `hdr10plus_tool`.
  * `Alt+b`: Toggle HUD | `Ctrl+g`: Toggle optical gain | `Alt+h`: Highlight recovery | `Alt+l`: Toggle live CABC | `Alt+[` / `Alt+]`: Floor adjustment | `Alt+-` / `Alt+=`: Decay rate.
* **Dynamic 3D LUT Loader (`lut.lua`)**: Real-time `.cube` / `.3dl` switcher in `~/.config/mpv/luts/`.  
  * `e` / `E`: Next / previous LUT | `Ctrl+e`: Rescan LUT folder.
* **Battery Saver (`battery.lua`)**: Detects AC vs. battery via `pmset` to switch between high-power shaders and power-saving profiles.  
  * `B`: Manually toggle battery mode.

### Audio & Equalization
* **AirPods FIR Equalizer (`scripts/airpodsEQ/`) (WIP)**: Real-time minimum-phase FIR headphone correction.
  * **Auto Detection (`main.lua`)**: Watches audio devices and channel count. When AirPods are active on stereo audio, dynamically inserts the `afir` convolution filter (`lavfi` with `airpods_ir.wav`) and normalizes macOS volume to `50%` via AppleScript for consistent calibration. Unloads cleanly when disconnected.
  * **IR Generator (`generate_ir.py`)**: Computes minimum-phase impulse responses from raw frequency curves (`orig` $\rightarrow$ `target`):
    * Level-matches curves across the reference band (200 Hz – 8 kHz).
    * Clamps maximum boost/cut to $\pm 12\text{ dB}$ for driver protection.
    * Linearly tapers high frequencies from 15 kHz to 20 kHz.
    ```bash
    pipx run scripts/airpodsEQ/generate_ir.py original_raw.txt target_raw.txt
    ```
* **ReplayGain (`replaygain.lua`)**: Dynamic loudness normalization to `-14 LUFS` via EBU R128 scanning with `ffmpeg`.
  * `meta+s`: Scan current file | `meta+i`: Show LUFS stats | `meta+up`/`meta+down`: $\pm 1\text{ dB}$ | `meta+b`: Bake tags | `meta+r`: Reset.

### Subtitles & Lyrics
* **Subtitles & Lyrics (`subtitles.lua`)**: Online subtitle search via Subliminal and synchronized karaoke lyrics via Musixmatch / LRCLIB.
  * `q` / `Q`: Smart download / manual search primary subs | `Ctrl+q` / `Ctrl+Q`: Secondary subs.
* **AutoSubSync (`scripts/autosubsync/`)**: `n`: Retune subtitles against audio via voice activity detection (`alass`).
* **Sub-Pause & Sub-Skip (`sub-pause.lua`, `sub-skip.lua`)**:
  * `'`: Auto-pause at end of subtitle | `;`: Next subtitle line | `Alt+l`: Replay line | `\`: Toggle silence skip.
* **Styles (`styles.lua`)**: `Alt+u`: Subtitle styling menu | `u` / `U`: Cycle subtitle presets.

### Playback & Stream Utilities
* **AniSkip (`aniskip.lua`)**: `Alt+s`: Toggle anime opening/ending auto-skip | `ENTER`: Skip manually.
* **SponsorBlock (`sponsorblock/`)**: Auto-skip YouTube sponsor segments | `H`: Downvote segment.
* **SelectFormat (`selectformat.lua`)**: `y`: Format menu | `F`: Toggle video streams | `Alt+f`: Toggle audio streams.
* **Cookie Cache (`cookie-cache.lua`)**: Dumps Chrome cookies to `~~/cache/scripts/cookies.txt` every 5 days for member/age-gated streams.
* **ModernX OSC (`modernx.lua`)**: Custom on-screen controller using `fluent-system-icons.ttf` with seekbar previews.  
  * `b`: Toggle OSC | `d`: Description | `tab`: Chapters | `[` / `]`: Prev/next chapter | `z` / `Z`: Shuffle/unshuffle.
* **Screenshot Folder (`screenshotfolder.lua`)**: Saves titled screenshots/clips and copies images to clipboard.  
  * `s`: Screenshot with subs | `j`: Clean video frame | `J`: Window screenshot | `O`: Open screenshots | `Option+O`: Open clips.
* **CopyPaste (`copypaste.lua`)**: `meta+c`: Copy path/URL | `meta+v`: Paste & play | `meta+shift+t`: Copy URL with timestamp | `Alt+o`: Open in browser.
* **PiP (`pip.lua`)**: `Alt+p`: Toggle borderless, aspect-locked Picture-in-Picture window.
* **Playlist Manager (`playlist_manager.lua`)**: `p` / `meta+p`: Interactive playlist menu | `Ctrl+f`: Add favorite | `Alt+w`: Watch Later.
* **Chapter Maker (`chapter-maker.lua`)**: In-player chapter splitting and editing.
* **Auto Save State (`auto-save-state.lua`)**: Saves resume position, audio track, and subtitle track per file.
* **Thumbfast (`thumbfast.lua`)**: Timeline hover thumbnails rendered via background client.

---

## 6. Credits

- **Base Setup:** [zydezu/mpvconfig](https://github.com/zydezu/mpvconfig)
- **ModernX OSC:** [zydezu/ModernX](https://github.com/zydezu/ModernX)
- **Shaders, Presets & LUTs:** [hooke007/mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit) (Anime4K, ArtCNN, FSRCNNX, CuNNy, KrigBilateral, Ravu)
- **SmartCut:** [skeskinen/smartcut](https://github.com/skeskinen/smartcut)
- **AutoSubSync:** [joaquinteixeira/mpv-autosubsync](https://github.com/joaquinteixeira/mpv-autosubsync) & [kaegi/alass](https://github.com/kaegi/alass)
- **SponsorBlock:** [Ajayyy/SponsorBlock](https://github.com/ajayyy/SponsorBlock) & [po5/mpv_sponsorblock](https://github.com/po5/mpv_sponsorblock)
- **Thumbfast:** [po5/thumbfast](https://github.com/po5/thumbfast)
- **SelectFormat:** [koonix/mpv-selectformat](https://github.com/koonix/mpv-selectformat)
- **Subtitles & Subliminal:** [Diaoul/subliminal](https://github.com/Diaoul/subliminal)
- **subskip & subpause:** [Ben-Kerman/mpv-sub-scripts](https://github.com/Ben-Kerman/mpv-sub-scripts)
- **Browser Extension:** [Play in MPV Extension](https://chromewebstore.google.com/detail/njlpgpceeekkodgehpehlngpoeilcncf?utm_source=item-share-cb)
- **libplacebo Patch Reference:** [haasn/libplacebo#378](https://github.com/haasn/libplacebo/issues/378)

---

## 7. License

This configuration, custom scripts, and extensions (`MediaBlocker`, `mpv-launcher.py`, custom wrappers) are licensed under the [MIT License](LICENSE). Third-party scripts, shaders, and tools remain licensed under their respective original terms.
