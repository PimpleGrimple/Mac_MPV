> [!NOTE]  
> This setup has not been tested on a Macbook pro
> Please bring your own `input.conf` file, or be prepared to sort through my `mess.conf`!  
> If anyone actually manages to sort through that mess and clean it up, **please send it my way via a Pull Request**—I really don't feel like doing that myself. 

---

## Recommended
install the **Play in MPV** Chrome extension:

>  **[Play in MPV (Chrome Web Store)](https://chromewebstore.google.com/detail/njlpgpceeekkodgehpehlngpoeilcncf?utm_source=item-share-cb)**  
> *Play the currently open YouTube video in mpv with a single click.*

---

## Installation

### 1. Prerequisites

Make sure you have `mpv`, `yt-dlp`, and `ffmpeg` installed:

Download the latest release from the official [mpv GitHub Repository](https://github.com/mpv-player/mpv)

```bash
# Homebrew needed
brew install yt-dlp ffmpeg
```

### 2. Install Configuration

Clone this repository into your mpv configuration folder:

```bash
# macOS / Linux
git clone https://github.com/PimpleGrimple/mac_MPV.git ~/.config/mpv
```

### 3. Set Up yt-dlp Configuration (Placed NEXT to mpv)

The `yt-dlp` configuration belongs in `~/.config/yt-dlp/` (next to `mpv`, not inside it):

```bash
mkdir -p ~/.config/yt-dlp
cp ~/.config/mpv/yt-dlp/config ~/.config/yt-dlp/config
```

> See [`yt-dlp/README.md`](file:///Users/mahmoud/.config/mpv/Git/yt-dlp/README.md) for full instructions.

### 4. Install Fonts

Recommended to install to the font book on a mac just open them and click install UI requires custom and then you can safely delete the folder

---

## Credits

- **Original Setup:**  
  **[zydezu/mpvconfig](https://github.com/zydezu/mpvconfig)**

- **On-Screen Controller (ModernX):**  
  **[zydezu/ModernX](https://github.com/zydezu/ModernX)** — based on `mpv-osc-modern` by **maoiscat**, with contributions from `cyl0`, `dexeonify`, and `Samillion`.

- **SponsorBlock Integration:**  
  **[zydezu](https://github.com/zydezu/mpvconfig)** utilizing the **[SponsorBlock API](https://github.com/ajayyy/SponsorBlock)** by Ajay.

- **Subtitles & Synced Lyrics:**  
  `subtitles.lua` merges and adapts:
  - `autolyrics.lua` by **[zydezu](https://github.com/zydezu/mpvconfig)**
  - `ytsub.lua` by **[zydezu](https://github.com/zydezu/mpvconfig)** (forked from **[Idlusen/mpv-ytsub](https://github.com/Idlusen/mpv-ytsub)**)
  - `autosub.lua` via Subliminal

- **Thumbfast:**  
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
