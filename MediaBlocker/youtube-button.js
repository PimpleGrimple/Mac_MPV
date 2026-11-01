/**
 * YouTube player button (from "Play in MPV").
 *
 * Only injects the control-bar button and handles YouTube's SPA navigation.
 * Launching, settings, auto-pause, start time and the keyboard shortcut all live
 * in content.js (self.__mbPlayHere) so they behave the same on every site.
 */

const BUTTON_ID  = 'play-in-mpv-player-button';
const STYLES_ID  = 'play-in-mpv-styles';

// ---------------------------------------------------------------------------
// SVG icon — widescreen monitor + play triangle
// No explicit width/height attributes: CSS drives the actual rendered size
// so the icon scales correctly in every player size (including fullscreen).
// ---------------------------------------------------------------------------
const MPV_ICON_SVG = `
<svg class="mpv-btn-icon" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">
  <!-- Widescreen monitor outline, centred with breathing room on all sides -->
  <rect x="6" y="9" width="24" height="15" rx="2"
        fill="none" stroke="currentColor" stroke-width="1.8"/>
  <!-- Play triangle centred inside the screen -->
  <polygon points="14,13 14,20 23,16.5" fill="currentColor"/>
  <!-- Small base/stand below the screen -->
  <line x1="18" y1="24" x2="18" y2="27" stroke="currentColor" stroke-width="1.8"/>
  <line x1="13" y1="27" x2="23" y2="27" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>
</svg>`.trim();

const MPV_SPINNER_SVG = `
<svg class="mpv-btn-spinner" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">
  <!-- Spinner base track -->
  <circle cx="18" cy="18" r="12" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="3"/>
  <!-- Rotating arc -->
  <circle cx="18" cy="18" r="12" fill="none" stroke="currentColor" stroke-width="3"
          stroke-dasharray="75.4" stroke-dashoffset="55" stroke-linecap="round"/>
</svg>`.trim();

// ---------------------------------------------------------------------------
// Inject a one-time <style> block so the SVG sizes itself via CSS instead of
// relying on guessed pixel values. height:100% makes it fill the control bar;
// width:auto preserves the square viewBox aspect ratio. This works at every
// player size, including theater mode and fullscreen.
// ---------------------------------------------------------------------------
function injectStyles() {
  if (document.getElementById(STYLES_ID)) return;
  const style = document.createElement('style');
  style.id = STYLES_ID;
  style.textContent = `
    #${BUTTON_ID} {
      display: inline-flex !important;
      align-items: center !important;
      justify-content: center !important;
      width: 46px !important;
      height: 100% !important;
      padding: 0 !important;
      margin: 0 !important;
      border: none !important;
      background: transparent !important;
      position: relative !important;
    }
    #${BUTTON_ID} svg {
      display: block !important;
      position: static !important;
      width: 36px !important;
      height: 36px !important;
      margin: 0 !important;
      padding: 0 !important;
    }
    #${BUTTON_ID} svg.mpv-btn-icon {
      transform: none !important;
    }
    #${BUTTON_ID} .mpv-btn-spinner {
      display: none !important;
    }
    #${BUTTON_ID}.loading .mpv-btn-icon {
      display: none !important;
    }
    #${BUTTON_ID}.loading .mpv-btn-spinner {
      display: block !important;
      transform-origin: center !important;
      animation: play-in-mpv-spin 1s linear infinite !important;
    }
    @keyframes play-in-mpv-spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }
  `;
  document.head.appendChild(style);
}

// ---------------------------------------------------------------------------
// Button injection
// ---------------------------------------------------------------------------

let isLoading = false;

function createButton() {
  const btn = document.createElement('button');
  btn.id        = BUTTON_ID;
  btn.className = 'ytp-button play-in-mpv-btn';
  btn.title     = 'Play in MPV';
  btn.setAttribute('aria-label', 'Play in MPV');
  btn.innerHTML = MPV_ICON_SVG + MPV_SPINNER_SVG;
  btn.addEventListener('click', onButtonClick);
  return btn;
}

function injectButton(controls) {
  injectStyles();
  const btn = createButton();
  // Prepend so it sits to the left of the Autoplay toggle
  controls.prepend(btn);
}

function attemptInjection() {
  try {
    // Don't add a duplicate button
    if (document.getElementById(BUTTON_ID)) return;

    const controls = document.querySelector('.ytp-right-controls');
    if (controls) {
      injectButton(controls);
    } else {
      // DOM not ready yet — retry
      setTimeout(attemptInjection, 300);
    }
  } catch (err) {
    // Fail silently; the context menu fallback remains available
    console.warn('[Play in MPV] Button injection failed:', err);
  }
}

// ---------------------------------------------------------------------------
// Click handler — hand off to content.js; show the spinner only when mpv's
// window isn't forced open immediately (otherwise there's nothing to wait for).
// ---------------------------------------------------------------------------
function onButtonClick() {
  if (isLoading || typeof self.__mbPlayHere !== 'function') return;
  const btn = document.getElementById(BUTTON_ID);

  chrome.storage.local.get({ forceWindow: true }, (settings) => {
    const showSpinner = !settings.forceWindow && btn;
    const startedAt = Date.now();
    if (showSpinner) {
      isLoading = true;
      btn.classList.add('loading');
      btn.style.cursor = 'not-allowed';
    }

    self.__mbPlayHere((result) => {
      if (result && !result.ok) console.error('[Media Blocker] mpv launch failed:', result.error);
      if (!showSpinner) return;
      const delay = Math.max(0, 3500 - (Date.now() - startedAt)); // keep the spinner visible briefly
      setTimeout(() => {
        isLoading = false;
        btn.classList.remove('loading');
        btn.style.cursor = '';
      }, delay);
    });
  });
}

// ---------------------------------------------------------------------------
// SPA navigation — YouTube fires yt-navigate-finish on every "page" change
// ---------------------------------------------------------------------------
function handleNavigation() {
  if (window.location.pathname.startsWith('/watch')) {
    attemptInjection();
  }
}

window.addEventListener('yt-navigate-finish', handleNavigation);
handleNavigation(); // also on first load, if we land directly on /watch
