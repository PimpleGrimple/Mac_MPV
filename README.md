# 🎬 Modern MPV Configuration

A modern, high-performance **mpv** setup crafted for pristine visual quality, rich subtitle & lyric integrations, seamless YouTube streaming, and an elegant on-screen controller.

---

## ✨ Features

- **🎨 Modern User Interface:** Powered by **ModernX OSC** with custom Fluent icons, smooth seekbars, chapter markers, and PiP mode.
- **⚡ High-Performance Rendering & Shaders:**
  - `gpu-next` video output with Apple Silicon hardware acceleration (`videotoolbox`) and Display P3 color calibration.
  - High-end AI upscaling & neural shaders: **ArtCNN**, **CuNNy**, **Anime4K**, **FSRCNNX**, **SSimDownscaler**, **KrigBilateral**, and **Ravu**.
- **📝 Intelligent Subtitles & Synced Lyrics:**
  - Auto-fetches YouTube subtitles & auto-generated captions.
  - Fetches synced lyrics for music / audio tracks.
  - Local video subtitle search & auto-downloading.
  - Subtitle pause/skip controls for language learning.
- **⏭️ Anime & Stream Enhancements:**
  - **Aniskip**: Auto-detects and skips Anime Openings (OP), Endings (ED), and recaps.
  - **SponsorBlock**: Automatically skips sponsored segments, intros, and self-promotions on YouTube.
  - **Thumbfast**: Real-time high-performance hover thumbnail previews across the timeline.
  - **SelectFormat**: Interactive format/resolution menu for YouTube and web streams.
- **🔋 macOS Battery Profile**: Automatically optimizes decoding and quality profiles when switching between AC power and battery.
- **📋 Seamless Clipboard & Cookie Cache**: Instant YouTube URL copy/paste and cookie caching to eliminate macOS Keychain lag.

---

## 🌐 Recommended Browser Companion

For the best web streaming experience, install the **Play in MPV** Chrome extension:

> 🔗 **[Play in MPV (Chrome Web Store)](https://chromewebstore.google.com/detail/njlpgpceeekkodgehpehlngpoeilcncf?utm_source=item-share-cb)**  
> *Play the currently open YouTube video in mpv with a single click.*

---

## 📥 Installation

### 1. Prerequisites

Make sure you have `mpv`, `yt-dlp`, and `ffmpeg` installed:

```bash
# macOS (Homebrew)
brew install mpv yt-dlp ffmpeg
```

### 2. Install Configuration

Clone this repository into your mpv configuration folder:

```bash
# macOS / Linux
git clone https://github.com/<YOUR_USERNAME>/<YOUR_REPO_NAME>.git ~/.config/mpv
```

### 3. Set Up yt-dlp Configuration (Placed NEXT to mpv)

The `yt-dlp` configuration belongs in `~/.config/yt-dlp/` (next to `mpv`, not inside it):

```bash
mkdir -p ~/.config/yt-dlp
cp ~/.config/mpv/yt-dlp/config ~/.config/yt-dlp/config
```

> See [`yt-dlp/README.md`](file:///Users/mahmoud/.config/mpv/Git/yt-dlp/README.md) for full instructions on configuring other browsers (Brave, Edge, Firefox, etc.) and PO-Token anti-bot bypass.

### 4. Install Required Fonts

The UI requires custom fonts located in the `fonts/` directory for ModernX and the icons:
1. Open the `fonts/` directory.
2. Install:
   - **`fluent-system-icons.ttf`** (Required for ModernX OSC icons)
   - **`Segoe UI Semibold.ttf`** or **`AOTFShinGoProMedium.otf`** (Required for typography)

---

## ⌨️ Keybindings & Input (`mess.conf`)

> [!NOTE]  
> **A note on the input config:**  
> Please bring your own `input.conf` file, or be prepared to sort through my `mess.conf`!  
> If anyone actually manages to sort through that mess and clean it up, **please send it my way via a Pull Request**—I really don't feel like doing that myself. 😅

### Common Shortcuts Cheat Sheet

| Key | Action |
|---|---|
| `Space` / `Right Click` | Play / Pause |
| `Double Click` | Toggle Fullscreen |
| `←` / `→` | Seek 5 seconds backward / forward |
| `Shift` + `←` / `→` | Exact 1-second seek (no OSD) |
| `Ctrl` + `←` / `→` | Seek to previous / next subtitle |
| `Ctrl` + `s` | Smart Subtitle / Synced Lyric Fetcher |
| `Alt` + `s` | Toggle Anime OP/ED auto-skipping (Aniskip) |
| `Ctrl` + `f` | Open Format Selection Menu (`selectformat`) |
| `Ctrl` + `v` / `Cmd` + `v` | Paste URL / timestamp to play |
| `Ctrl` + `c` / `Cmd` + `c` | Copy current URL and timestamp to clipboard |
| `s` | Screenshot (saved to custom screenshot folder) |
| `O` | Open screenshots directory |
| `Q` | Quit and save playback position |

---

## 📜 Credits & Acknowledgements

This setup is built on the shoulders of the amazing mpv open-source community:

- **Original Base Setup & Inspiration:**  
  Special thanks to **[zydezu/mpvconfig](https://github.com/zydezu/mpvconfig)** for the original configuration baseline, fonts, and script workflow inspirations.

- **On-Screen Controller (ModernX):**  
  **[zydezu/ModernX](https://github.com/zydezu/ModernX)** — based on `mpv-osc-modern` by **maoiscat**, with contributions from `cyl0`, `dexeonify`, and `Samillion`.

- **SponsorBlock Integration:**  
  **[zydezu](https://github.com/zydezu/mpvconfig)** utilizing the **[SponsorBlock API](https://github.com/ajayyy/SponsorBlock)** by Ajay.

- **Subtitles & Synced Lyrics:**  
  `subtitles.lua` merges and adapts:
  - `autolyrics.lua` by **[zydezu](https://github.com/zydezu/mpvconfig)**
  - `ytsub.lua` by **[zydezu](https://github.com/zydezu/mpvconfig)** (forked from **[Idlusen/mpv-ytsub](https://github.com/Idlusen/mpv-ytsub)**)
  - `autosub.lua` via Subliminal

- **Thumbfast (Fast Seekbar Previews):**  
  **[po5/thumbfast](https://github.com/po5/thumbfast)** by **po5** (MPL-2.0 License).

- **Format Selection:**  
  **[koonix/mpv-selectformat](https://github.com/koonix/mpv-selectformat)** by **koonix** (MIT License).

- **Sub-Pause:**  
  **Ben Kerman** (© 2022 Ben Kerman).

- **Shaders & Scalers:**
  - **[Anime4K](https://github.com/bloc97/Anime4K)** by **bloc97**
  - **[ArtCNN](https://github.com/Artoria2e5/ArtCNN)** by **Artoria2e5** & **agilob**
  - **[FSRCNNX](https://github.com/igv/FSRCNN-TensorFlow-DirectML)** & **SSimDownscaler** by **igv**
  - **[CuNNy](https://github.com/HelpSeeker/CuNNy)** by **HelpSeeker**
  - **[KrigBilateral](https://gist.github.com/Shiandow)** by **Shiandow**
  - **[Ravu](https://github.com/bjin/mpv-prescalers)** by **bjin**

- **Browser Integration:**  
  **[Play in MPV Extension](https://chromewebstore.google.com/detail/njlpgpceeekkodgehpehlngpoeilcncf?utm_source=item-share-cb)** for one-click streaming.
