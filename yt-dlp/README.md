# yt-dlp Configuration & Setup Guide 

A comprehensive guide and reference for the custom `yt-dlp` setup, integrated with **mpv**, **ModernX**, **cookie caching**, and **automated PO-Token (Proof of Origin) generation**.

---

## 📁 Important: Folder Location

> [!IMPORTANT]
> The `yt-dlp` configuration folder must be placed **next to** your `mpv` directory inside `~/.config/`, **NOT inside** the `mpv` folder itself.

### Directory Layout
```text
~/.config/
├── mpv/                       <-- Your mpv setup
│   ├── mpv.conf
│   ├── mess.conf
│   ├── scripts/
│   ├── shaders/
│   └── fonts/
│
└── yt-dlp/                    <-- Place yt-dlp config HERE (next to mpv)
    ├── config                 <-- Main yt-dlp configuration file
    └── README.md
```

### Installation Command
To install or copy this configuration to the correct location:

```bash
# 1. Create the ~/.config/yt-dlp directory
mkdir -p ~/.config/yt-dlp

# 2. Copy the config file into place
cp ~/.config/mpv/yt-dlp/config ~/.config/yt-dlp/config
```

---

## ⚡ Quick Overview

This configuration is optimized for:
* **Full Codec Availability:** Full support for modern codecs (**AV1**, **VP9**, **HEVC**, and **Opus**) up to **4K/8K HDR**.
* **Anti-Bot & 403 Bypass:** Automated Proof-of-Origin (PO-Token) generation via a headless browser to bypass YouTube's BotGuard defense.
* **Accelerated Downloads:** Multi-threaded parallel fragment downloading (4 concurrent streams).
* **Seamless mpv Integration:** Native support for `selectformat.lua` quality switching, ModernX OSC downloads, and automatic cookie cache synchronization.

---

## ⚙️ Configuration (`~/.config/yt-dlp/config`)

```text
# ==============================================================================
# yt-dlp Configuration
# ==============================================================================

# Authentication & Account
--cookies "~/.config/mpv/cache/scripts/cookies.txt"
--mark-watched

# Network & Performance Optimization
--force-ipv4
--retries 10
--fragment-retries 10
--socket-timeout 30
--concurrent-fragments 4

# Proof of Origin (PO-Token) Provider for YouTube Anti-Bot Bypass
# Default: Google Chrome (standard)
--extractor-args "youtubepot-wpc:browser_path=/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Subtitles, Metadata & Embeds (for standalone CLI downloads)
--embed-thumbnail
--embed-metadata
--embed-subs
--sub-langs "en.*,-live_chat"
--no-write-comments
```

---

## 🌐 Using Different Browsers

The setup defaults to standard **Google Chrome**, but you can easily use **Brave**, **Edge**, **Firefox**, **Vivaldi**, or **Chromium**.

### 1. Update `~/.config/yt-dlp/config`
Edit the `--extractor-args` line in `~/.config/yt-dlp/config` with the binary path for your browser:

#### macOS Browser Paths:
| Browser | Configuration Line |
| :--- | :--- |
| **Google Chrome** *(Default)* | `--extractor-args "youtubepot-wpc:browser_path=/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"` |
| **Brave Browser** | `--extractor-args "youtubepot-wpc:browser_path=/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"` |
| **Microsoft Edge** | `--extractor-args "youtubepot-wpc:browser_path=/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"` |
| **Mozilla Firefox** | `--extractor-args "youtubepot-wpc:browser_path=/Applications/Firefox.app/Contents/MacOS/firefox"` |
| **Vivaldi** | `--extractor-args "youtubepot-wpc:browser_path=/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"` |
| **Chromium** | `--extractor-args "youtubepot-wpc:browser_path=/Applications/Chromium.app/Contents/MacOS/Chromium"` |
| **Google Chrome Beta** | `--extractor-args "youtubepot-wpc:browser_path=/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta"` |

#### Windows Browser Paths:
* **Google Chrome:** `--extractor-args "youtubepot-wpc:browser_path=C:\Program Files\Google\Chrome\Application\chrome.exe"`
* **Brave:** `--extractor-args "youtubepot-wpc:browser_path=C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"`
* **Edge:** `--extractor-args "youtubepot-wpc:browser_path=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"`

---

### 2. Update `cookie_cache.lua` (mpv Cookie Exporter)
To export cookies from your preferred browser so mpv can access age-restricted or premium content:

Create or edit `~/.config/mpv/script-opts/cookie_cache.conf`:

```ini
# Browser choice: chrome, brave, edge, firefox, vivaldi, chromium, opera, safari
browser=chrome
```

#### Using Specific Browser Profiles:
If you have multiple user profiles in your browser, specify the profile name or path:
```ini
# Example for a specific Chrome Profile
browser=chrome:Default
# or
browser=chrome:Profile 1

# Example for Brave with custom path
browser=brave:~/Library/Application Support/BraveSoftware/Brave-Browser/Default
```

---

## 🛡️ How Anti-Bot Protection & PO-Tokens Work

YouTube implements a two-tier authentication system for media streams:

```
+-------------------------------------------------------------------------------+
|                             YouTube Request Flow                              |
+-------------------------------------------------------------------------------+
       |
       +---> [1. Account Identity (Cookies)]
       |     * Read from ~/.config/mpv/cache/scripts/cookies.txt
       |     * Grants access to private/premium content & watch history.
       |
       +---> [2. Client Integrity Challenge (PO-Token / BotGuard)]
             * Required for modern codecs (AV1, VP9, Opus).
             * Solved silently by: yt-dlp-getpot-wpc + Headless Browser
             * Prevents HTTP 403 Forbidden errors on googlevideo CDN streams.
```

### The Role of `yt-dlp-getpot-wpc`
* When `yt-dlp` encounters a YouTube stream requiring verification, `yt-dlp-getpot-wpc` launches a headless background instance of your browser.
* The browser solves YouTube's BotGuard script and extracts the freshly minted **PO-Token**.
* `yt-dlp` attaches this token to the video stream requests, allowing `mpv` to play **4K AV1 (`av01`)** and **Opus** audio without being rejected with a `403 Forbidden` error.

---

## 🛠️ Maintenance & Updates

### Upgrading `yt-dlp`
```bash
brew upgrade yt-dlp
```

### Installing / Reinstalling the PO-Token Plugin
```bash
# Install the provider plugin into the yt-dlp Python environment
/opt/homebrew/Cellar/yt-dlp/*/libexec/bin/python -m pip install yt-dlp-getpot-wpc
```

### Clearing the Cache
If you encounter unusual metadata errors:
```bash
yt-dlp --rm-cache-dir
```
