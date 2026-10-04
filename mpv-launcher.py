#!/usr/bin/env python3
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback
from urllib.parse import unquote, urlsplit

# ===================== CONFIG =====================
MPV_BUNDLE_ID = "io.mpv"
MPV_APP_EXECUTABLE = "/Applications/mpv.app/Contents/MacOS/mpv"
MPV_CLI_FALLBACK_PATH = None
SOCKET_FALLBACK = True

CACHE_DIR = os.path.expanduser("~/.config/mpv/cache")

YTDLP_PIPE_PATH_PATTERNS = ("uwu",)

MPV_STREAM_ARGS = (
    "--force-seekable=yes",
    "--cache=yes",
    "--cache-secs=10",
)

YTDLP_STREAM_ARGS = (
    "-q",
    "--no-warnings",
    "--hls-use-mpegts",
)

YTDLP_PIPE_ARGS = (
    "-q",
    "--no-warnings",
    "--hls-use-mpegts"
    "--impersonate chrome",
)

MPV_PIPE_ARGS = (
    "--cache=yes",
)

YTDLP_DOWNLOAD_ARGS = (
    "--progress",
    "--newline",
)

# Disc kind -> (device option name, mpv URI).
DISC_MAP = {
    "dvd": ("dvd-device", "dvd://"),
    "bd": ("bluray-device", "bluray://"),
}

MAX_MANIFEST_BYTES = 10 * 1024 * 1024

LOG_ROTATE_AT = 524288
LOG_KEEP_LINES = 200
LOG_CHECK_EVERY = 20

# ===================== SETUP =====================
def setup():
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.environ.get("PATH", "").split(os.pathsep)
    for item in ("/usr/local/bin", "/opt/homebrew/bin"):
        if item not in path:
            path.append(item)
    os.environ["PATH"] = os.pathsep.join(path)
    os.environ.pop("LD_LIBRARY_PATH", None)
    os.environ.pop("LD_PRELOAD", None)


_log_lock = threading.Lock()
_log_counter = 0


def log(message):
    global _log_counter
    path = os.path.join(CACHE_DIR, "launcher-error.log")
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n"
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        return

    with _log_lock:
        _log_counter += 1
        check = _log_counter >= LOG_CHECK_EVERY
        if check:
            _log_counter = 0
    if not check:
        return
    try:
        if os.path.getsize(path) > LOG_ROTATE_AT:
            rotate_log()
    except OSError:
        pass


def rotate_log():
    path = os.path.join(CACHE_DIR, "launcher-error.log")
    try:
        if os.path.getsize(path) <= LOG_ROTATE_AT:
            return
        with open(path, encoding="utf-8", errors="replace") as f:
            keep = f.readlines()[-LOG_KEEP_LINES:]
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(keep)
    except OSError:
        pass


def clean_pipe_runs():
    root = os.path.join(CACHE_DIR, "pipe")
    try:
        now = time.time()
        for name in os.listdir(root):
            path = os.path.join(root, name)
            try:
                if os.path.isdir(path) and now - os.path.getctime(path) > 48 * 60 * 60:
                    shutil.rmtree(path, ignore_errors=True)
            except OSError:
                pass
    except OSError:
        pass


_maintenance_lock = threading.Lock()


def background_maintenance():
    if not _maintenance_lock.acquire(blocking=False):
        return

    def worker():
        try:
            rotate_log()
            clean_pipe_runs()
        finally:
            _maintenance_lock.release()

    threading.Thread(target=worker, daemon=True).start()


def notify(title, message):
    try:
        subprocess.run(
            [
                "osascript",
                "-e",
                f"display notification {json.dumps(message)} with title {json.dumps(title)}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except Exception:
        pass

# ===================== EXECUTABLES =====================
def find_bin(name, path=None):
    if path:
        if "/" in path or "\\" in path:
            return path if os.path.isfile(path) and os.access(path, os.X_OK) else None
        return shutil.which(path)
    if name == "yt-dlp":
        return shutil.which("yt-dlp") or shutil.which("youtube-dl")
    return shutil.which(name)


def mpv_app_exists():
    return os.path.isfile(MPV_APP_EXECUTABLE) and os.access(MPV_APP_EXECUTABLE, os.X_OK)


def cli_fallback():
    return find_bin("mpv", MPV_CLI_FALLBACK_PATH)


def pipe_mpv_bin():
    if mpv_app_exists():
        return MPV_APP_EXECUTABLE
    return cli_fallback() or shutil.which("mpv")


def normalize(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1].strip()
    if value.startswith("file://"):
        value = unquote(urlsplit(value).path)
    return os.path.expanduser(value)


def origin_of(ref):
    """Return scheme://netloc for a referrer, or '' if unusable."""
    if not ref:
        return ""
    try:
        parsed = urlsplit(ref)
        if parsed.scheme and parsed.netloc:
            return f"{parsed.scheme}://{parsed.netloc}"
    except Exception:
        pass
    return ""

# ===================== MPV LAUNCH =====================
def launch_cli(args):
    binary = cli_fallback()
    if not binary:
        return False
    cmd = [binary, *args]
    log(f"CLI fallback launch={cmd!r}")
    try:
        subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return True
    except Exception as exc:
        log(f"CLI fallback failed: {exc}")
        return False


def launch_bundle(args):
    cmd = ["open", "-n", "-b", MPV_BUNDLE_ID, "--args", *args]
    log(f"bundle launch={cmd!r}")
    try:
        result = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode:
            log(
                f"bundle launch rc={result.returncode} "
                f"stderr={result.stderr.strip()!r}"
            )
            return False
        return True
    except Exception as exc:
        log(f"bundle launch failed: {exc}")
        return False


def launch_primary(args):
    # App bundle is always primary. CLI is only backup.
    if mpv_app_exists() and launch_bundle(args):
        return True
    return launch_cli(args)


def launch_empty():
    return launch_primary(())

# ===================== IPC FALLBACK =====================
def fallback_socket():
    return os.path.join(CACHE_DIR, "fallback.sock")


def socket_live(path):
    if not os.path.exists(path):
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(0.7)
            s.connect(path)
            s.sendall(b'{"command":["get_property","pid"]}\n')
            return bool(s.recv(256))
    except OSError:
        return False


def send_socket(payloads, startup_args=()):
    path = fallback_socket()
    os.makedirs(CACHE_DIR, exist_ok=True)

    if not socket_live(path):
        if os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass

        args = [
            "--idle=once",
            "--force-window=yes",
            f"--input-ipc-server={path}",
            *startup_args,
        ]

        if not launch_primary(args):
            return False

        for _ in range(20):
            time.sleep(0.05)
            if socket_live(path):
                break
        else:
            log(f"fallback socket did not appear: {path}")
            return False

    for payload in payloads:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(1.5)
                s.connect(path)
                s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
                if not s.recv(4096):
                    log(f"fallback IPC no response; payload={payload!r}")
                    return False
        except OSError as exc:
            log(f"fallback IPC failed: {exc}; payload={payload!r}")
            return False
    return True


def ipc_opts(args):
    out = []
    for arg in args:
        if not arg.startswith("--"):
            continue
        item = arg[2:]
        if "=" in item:
            key, value = item.split("=", 1)
        elif item.startswith("no-"):
            key, value = item[3:], "no"
        else:
            key, value = item, "yes"
        escaped = value.replace("\\", "\\\\").replace(",", "\\,")
        out.append(f"{key}={escaped}")
    return ",".join(out)


def load_payload(target, mode="replace", args=()):
    command = ["loadfile", target, mode]
    options = ipc_opts(args)
    if options:
        command.append(options)
    return {"command": command}


def prop_payload(name, value):
    return {"command": ["set_property", name, value]}


def launch_or_socket(direct_args, payloads, startup_args=()):
    """Try the primary launch (open -> CLI), then the socket fallback.

    Returns (ok, info). Never notifies; callers decide how to surface failure.
    The socket fallback is never skipped when SOCKET_FALLBACK is enabled.
    """
    if launch_primary(direct_args):
        return True, "mpv launched"
    if SOCKET_FALLBACK and send_socket(payloads, startup_args=startup_args):
        return True, "queued to fallback socket"
    return False, "direct and socket launch failed"

# ===================== YT-DLP OPTIONS =====================
def _quote_ytdl_value(value):
    value = str(value)
    if not value:
        return ""
    if any(ch in value for ch in (",", " ", ":", "\\", '"')):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return value


def ytdl_raw_options(args):
    short = {"-q": "quiet"}
    out = []
    for arg in args:
        if arg in short:
            out.append(short[arg] + "=")
            continue
        if not arg.startswith("--"):
            raise ValueError(f"unsupported yt-dlp option form: {arg!r}")

        item = arg[2:]
        if "=" in item:
            key, value = item.split("=", 1)
            out.append(f"{key}={_quote_ytdl_value(value)}")
        else:
            out.append(item + "=")
    return ",".join(out)


def mpv_ytdl_args(ytdlp_path=None, ref="", ua=""):
    args = []
    if ytdlp_path:
        args.append(f"--script-opts=ytdl_hook-ytdl_path={ytdlp_path}")

    # Force yt-dlp to inspect the URL first so selected format selectors work.
    args.append("--script-opt=ytdl_hook-try_ytdl_first=yes")

    # mpv's ytdl_hook forwards --referrer/--user-agent itself. Add only Origin
    # here (a UA with commas would be split by raw-options).
    raw_args = list(YTDLP_STREAM_ARGS)
    origin = origin_of(ref)
    if origin:
        raw_args.append(f"--add-headers=Origin: {origin}")

    try:
        raw = ytdl_raw_options(raw_args)
    except ValueError as exc:
        log(f"invalid YTDLP_STREAM_ARGS: {exc}")
        return args
    if raw:
        args.append(f"--ytdl-raw-options={raw}")
    return args

# ===================== CLIPBOARD / FINDER =====================
def clipboard():
    try:
        return subprocess.check_output(
            ["pbpaste"],
            text=True,
            encoding="utf-8",
        ).strip()
    except Exception as exc:
        log(f"clipboard failed: {exc}")
        return ""


def finder_selection():
    script = r'''tell application "Finder"
    set sel to selection
    if sel is {} then return ""
    set out to ""
    repeat with i in sel
        set out to out & (POSIX path of (i as alias)) & linefeed
    end repeat
    return out
end tell'''
    start = time.monotonic()
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=4,
            check=False,
        )
        elapsed = time.monotonic() - start
        if result.returncode:
            log(
                f"Finder failed in {elapsed:.3f}s: "
                f"rc={result.returncode} stderr={result.stderr.strip()!r}"
            )
            return []
        paths = [p for p in result.stdout.splitlines() if p]
        paths = [p for p in paths if not p.rstrip("/").endswith(".app")]
        log(f"Finder selection in {elapsed:.3f}s: {paths!r}")
        return paths
    except subprocess.TimeoutExpired:
        log("Finder selection timed out")
        return []
    except Exception as exc:
        log(f"Finder failed: {exc}")
        return []

# ===================== DOWNLOADS =====================
def clean_title(value):
    value = re.sub(r'[\\/:*?"<>|]', "", str(value or "video"))
    value = value.replace("\n", " ").replace("\r", " ").strip()
    # Strip common site-generated prefixes.
    value = re.sub(r"^(?:Watch|Download)\s+", "", value, flags=re.I)
    # Strip trailing site markers.
    value = re.sub(r"\s*(?:Online\s*-\s*)?Animepahe\s*$", "", value, flags=re.I)
    value = re.sub(r"\s*::\s*Animepahe\s*$", "", value, flags=re.I)
    # Strip leftover container/stream hints that sometimes land in titles.
    value = re.sub(r"\s*[\[\(](?:manifest|m3u8|mpd|dash|hls|mp4|mkv|webm)[\]\)]\s*$",
                   "", value, flags=re.I)
    return value or "video"


def download(url, title, base, format_selector=None):
    root = os.path.join(CACHE_DIR, "dl-locks")
    os.makedirs(root, exist_ok=True)
    lock = os.path.join(
        root,
        hashlib.sha1(f"{url}|{title}".encode("utf-8")).hexdigest()[:12] + ".lock",
    )
    try:
        os.mkdir(lock)
        os.chmod(lock, 0o700)
    except FileExistsError:
        notify("mpv-launcher", f"Already downloading: {title}")
        raise RuntimeError("download already in progress")

    # Title alone is the final name. yt-dlp's generic extractor sets %(id)s to
    # the manifest filename stem ("manifest" for a .mpd URL), which produced
    # ugly "Title [manifest].mkv" names. Dropping it means duplicates get
    # overwritten; if that ever matters, use %(autonumber)s instead.
    output = os.path.expanduser(f"~/Downloads/{title}.%(ext)s")

    # Args go in the file WITHOUT the binary; the binary is passed to xargs.
    ytdlp_bin = base[0]
    command = list(base[1:]) + list(YTDLP_DOWNLOAD_ARGS)
    if format_selector:
        command += ["-f", str(format_selector)]
    command += ["-o", output, url]

    args_file = os.path.join(lock, "yt-dlp.args")
    try:
        with open(args_file, "wb") as f:
            f.write(b"\0".join(str(arg).encode("utf-8") for arg in command))
            f.write(b"\0")

        lock_q = shlex.quote(lock)
        args_q = shlex.quote(args_file)
        title_q = shlex.quote(title)
        ytdlp_q = shlex.quote(ytdlp_bin)
        shell = (
            f"trap 'rm -rf {lock_q}' EXIT; "
            f"printf '%s\\n' 'Downloading:' {title_q}; "
            f"if ! /usr/bin/xargs -0 {ytdlp_q} < {args_q}; then "
            "  echo '[Failed] Download failed.'; "
            "  sleep 5; "
            "  exit 1; "
            "fi; "
            "echo '[Done] You can safely close this window.'; "
            "sleep 5"
        )

        terminal_command = "/bin/bash -lc " + shlex.quote(shell)
        log(
            f"[download] Terminal command length={len(terminal_command)} "
            f"argv_count={len(command)} args_file={args_file!r}"
        )

        applescript_command = terminal_command.replace("\\", "\\\\").replace('"', '\\"')
        applescript = (
            'tell application "Terminal"\n'
            '    activate\n'
            f'    do script "{applescript_command}"\n'
            'end tell'
        )
        subprocess.run(
            ["osascript", "-e", applescript],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )
    except Exception:
        shutil.rmtree(lock, ignore_errors=True)
        raise

# ===================== EXPLICIT PIPE =====================
class PipeRun:
    def __init__(self):
        clean_pipe_runs()
        root = os.path.join(CACHE_DIR, "pipe")
        os.makedirs(root, exist_ok=True)
        self.id = f"{os.getpid()}-{time.time_ns()}"
        self.dir = os.path.join(root, self.id)
        os.makedirs(self.dir, exist_ok=True)
        try:
            os.chmod(self.dir, 0o700)
        except OSError:
            pass
        self.ipc = os.path.join(self.dir, "mpv.sock")
        self.ylog = os.path.join(self.dir, "ytdlp.log")
        self.mlog = os.path.join(self.dir, "mpv.log")


def prop(path, name):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            s.connect(path)
            s.sendall((json.dumps({"command": ["get_property", name]}) + "\n").encode())
            return json.loads(s.recv(4096).decode()).get("data")
    except Exception:
        return None


def watchdog(mpv, ytdlp, pipe):
    time.sleep(10)
    if mpv.poll() is not None or ytdlp.poll() is not None:
        return
    idle = prop(pipe.ipc, "core-idle")
    if idle is None or idle is False:
        return
    time.sleep(10)
    if mpv.poll() is not None or ytdlp.poll() is not None:
        return
    cache = prop(pipe.ipc, "demuxer-cache-state")
    if cache is None or cache.get("fw-bytes", 0) > 0:
        return
    log(f"[{pipe.id}] pipe stalled idle={idle} cache={cache}")
    notify("mpv-launcher", "Stream stalled - no data received, closing")
    for process in (mpv, ytdlp):
        if process.poll() is None:
            try:
                process.terminate()
            except Exception:
                pass


def pipe_play(url, title, media_type, ycmd, format_selector=None):
    pipe = PipeRun()
    binary = pipe_mpv_bin()
    if not binary:
        log("pipe: mpv not found")
        shutil.rmtree(pipe.dir, ignore_errors=True)
        return

    name = os.path.basename(urlsplit(url).path) or "media"
    mpv_cmd = [
        binary,
        f"--input-ipc-server={pipe.ipc}",
        *MPV_PIPE_ARGS,
        f"--force-media-title={title} [{name}]",
    ]
    if media_type in ("image", "svg"):
        mpv_cmd += [
            "--image-display-duration=inf",
            "--loop-file=inf",
        ]
    mpv_cmd.append("-")

    ytdlp_cmd = list(ycmd) + list(YTDLP_PIPE_ARGS)
    if format_selector:
        ytdlp_cmd += ["-f", str(format_selector)]
    ytdlp_cmd += ["-o", "-", url]

    ytdlp = mpv = None
    try:
        with open(pipe.ylog, "w", encoding="utf-8") as yl, \
             open(pipe.mlog, "w", encoding="utf-8") as ml:
            ytdlp = subprocess.Popen(
                ytdlp_cmd,
                stdout=subprocess.PIPE,
                stderr=yl,
                cwd="/tmp",
            )
            try:
                mpv = subprocess.Popen(
                    mpv_cmd,
                    stdin=ytdlp.stdout,
                    stdout=ml,
                    stderr=subprocess.STDOUT,
                    cwd="/tmp",
                )
            except Exception:
                try:
                    ytdlp.terminate()
                    ytdlp.wait(timeout=2)
                except Exception:
                    pass
                raise
            finally:
                if ytdlp.stdout:
                    ytdlp.stdout.close()

            threading.Thread(
                target=watchdog,
                args=(mpv, ytdlp, pipe),
                daemon=True,
            ).start()

            mpv.wait()
            terminated = ytdlp.poll() is None
            if terminated:
                try:
                    ytdlp.terminate()
                    ytdlp.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try:
                        ytdlp.kill()
                    except Exception:
                        pass
            if ytdlp.returncode and ytdlp.returncode > 0 and not terminated:
                try:
                    with open(pipe.ylog, encoding="utf-8", errors="replace") as f:
                        text = f.read().strip()
                except OSError:
                    text = ""
                if "Broken pipe" not in text and "SIGPIPE" not in text:
                    last = text.splitlines()[-1] if text else "unknown yt-dlp error"
                    notify("mpv-launcher: playback failed", f"ERROR: {last}")
    except Exception:
        log(f"[{pipe.id}] pipe error:\n{traceback.format_exc()}")
    finally:
        for process in (mpv, ytdlp):
            if process is not None and process.poll() is None:
                try:
                    process.terminate()
                    process.wait(timeout=2)
                except Exception:
                    try:
                        process.kill()
                    except Exception:
                        pass
        try:
            os.remove(pipe.ipc)
        except OSError:
            pass


def _pipe_worker_command(payload):
    exe = sys.executable or shutil.which("python3") or "python3"
    script = os.path.realpath(__file__)
    return [exe, script, "--internal-pipe-play", payload]

# ===================== NORMAL WEB PLAYBACK =====================
def play_direct_url(url, ytdlp_path=None, title="",
                    ref="", ua="", extra_flags=(), custom=None):
    flags = list(extra_flags) + list(MPV_STREAM_ARGS)
    if title:
        flags.append(f"--force-media-title={title}")
    if ref:
        flags.append(f"--referrer={ref}")
    if ua:
        flags.append(f"--user-agent={ua}")
    if custom:
        try:
            flags += shlex.split(str(custom))
        except ValueError as exc:
            return False, f"Malformed custom flags: {exc}"

    ytdl_args = mpv_ytdl_args(ytdlp_path, ref, ua)
    launch_args = ytdl_args + flags + ["--", url]
    log(f"web launch={launch_args!r}")

    payloads = []
    if ref:
        payloads.append(prop_payload("referrer", ref))
    if ua:
        payloads.append(prop_payload("user-agent", ua))
    payloads.append(load_payload(url, "replace", flags))

    return launch_or_socket(launch_args, payloads, startup_args=ytdl_args)

# ===================== NATIVE MANIFEST FETCH =====================
def fetch_manifest(url, ref="", ua=""):
    """Fetch an HLS/DASH manifest outside the browser page's CORS context."""
    curl = shutil.which("curl") or "/usr/bin/curl"
    if not os.path.isfile(curl) or not os.access(curl, os.X_OK):
        return False, "curl executable not found"

    cmd = [
        curl,
        "--location",
        "--fail-with-body",
        "--silent",
        "--show-error",
        "--compressed",
        "--http1.1",
        "--connect-timeout", "8",
        "--max-time", "20",
        "-H", "Accept: */*",
    ]

    if ua:
        cmd += ["-A", ua]
    if ref:
        cmd += ["-e", ref]
        origin = origin_of(ref)
        if origin:
            cmd += ["-H", f"Origin: {origin}"]

    cmd.append(url)

    log(f"manifest fetch cmd={cmd!r}")
    try:
        result = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd="/tmp",
            timeout=25,
            check=False,
        )
    except subprocess.TimeoutExpired:
        log(f"manifest fetch timed out: {url}")
        return False, "manifest fetch timed out"
    except Exception as exc:
        log(f"manifest fetch failed to start: {exc}")
        return False, str(exc)

    if result.returncode != 0:
        err = result.stderr.decode("utf-8", errors="replace").strip()
        log(f"manifest fetch rc={result.returncode} stderr={err!r} url={url}")
        return False, err or f"curl exited with {result.returncode}"

    if len(result.stdout) > MAX_MANIFEST_BYTES:
        log(f"manifest too large: {len(result.stdout)} bytes url={url}")
        return False, "manifest exceeds size limit"

    text = result.stdout.decode("utf-8", errors="replace")
    log(f"manifest fetch ok bytes={len(result.stdout)} url={url}")
    return True, text

# ===================== NATIVE MESSAGING =====================
def read_exact(size):
    out = bytearray()
    while len(out) < size:
        chunk = sys.stdin.buffer.read(size - len(out))
        if not chunk:
            raise ValueError("unexpected end of native-messaging input")
        out.extend(chunk)
    return bytes(out)


def read_message():
    size = struct.unpack("<I", read_exact(4))[0]
    if size > 10 * 1024 * 1024:
        raise ValueError("native message too large")
    return json.loads(read_exact(size).decode("utf-8"))


def send_message(obj):
    data = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(data)) + data)
    sys.stdout.buffer.flush()


def pipe_url(url):
    path = unquote(urlsplit(url).path or "").lower()
    return any(item.lower() in path for item in YTDLP_PIPE_PATH_PATTERNS)


def _ytdlp_command(ytdlp, ua, ref):
    command = [ytdlp]
    if ua:
        command += ["--user-agent", ua]
    if ref:
        command += ["--referer", ref]
    return command


def native_dispatch(message):
    if not isinstance(message, dict):
        raise ValueError("native message must be an object")
    if "url" in message and "type" not in message:
        message["type"] = "PLAY"

    if message.get("type") == "CHECK_STATUS":
        send_message({
            "ok": True,
            "ytdl_missing": not bool(find_bin("yt-dlp", message.get("ytdlp_path"))),
            "mpv_missing": not bool(mpv_app_exists() or cli_fallback()),
            "version": "0.5.7",
        })
        return

    if message.get("type") == "FETCH_MANIFEST":
        url = message.get("url", "")
        if not isinstance(url, str) or not url.strip():
            send_message({"ok": False, "error": "No manifest URL provided"})
            return
        ok, result = fetch_manifest(
            url.strip(),
            str(message.get("ref", "") or ""),
            str(message.get("ua", "") or ""),
        )
        if ok:
            send_message({"ok": True, "text": result})
        else:
            send_message({"ok": False, "error": result})
        return

    url = message.get("url", "")
    if not isinstance(url, str) or not url.strip():
        send_message({"ok": False, "error": "No URL provided"})
        return
    url = url.strip()

    ytdlp = find_bin("yt-dlp", message.get("ytdlp_path"))
    ref = str(message.get("ref", "") or "")
    ua = str(message.get("ua", "") or "")
    title = clean_title(message.get("title", "video"))
    format_selector = str(message.get("format", "") or "").strip()

    if message.get("type") == "DOWNLOAD":
        if not ytdlp:
            send_message({"ok": False, "error": "yt-dlp executable not found."})
            return
        command = _ytdlp_command(ytdlp, ua, ref)
        background_maintenance()
        try:
            download(url, title, command, format_selector)
            send_message({"ok": True, "info": f"Download queued: {title}"})
        except Exception as exc:
            send_message({"ok": False, "error": f"Download failed: {exc}"})
        return

    if message.get("type") != "PLAY":
        send_message(
            {"ok": False, "error": f"Unsupported message type: {message.get('type')!r}"}
        )
        return

    media_type = message.get("media_type", "")

    if pipe_url(url):
        if not ytdlp:
            send_message({"ok": False, "error": "yt-dlp executable not found."})
            return
        command = _ytdlp_command(ytdlp, ua, ref)
        background_maintenance()
        payload = json.dumps({
            "cmd": command,
            "url": url,
            "title": title,
            "media_type": media_type,
            "format": format_selector,
        })
        try:
            subprocess.Popen(
                _pipe_worker_command(payload),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            send_message({"ok": True, "info": "pipe playback started"})
        except OSError as exc:
            send_message({"ok": False, "error": f"Failed to start pipe: {exc}"})
        return

    flags = message.get("flags") or []
    if not isinstance(flags, list):
        send_message({"ok": False, "error": "flags must be a list"})
        return
    extra = [str(x) for x in flags]
    if format_selector:
        extra.append(f"--ytdl-format={format_selector}")
    if media_type in ("image", "svg"):
        extra += ["--image-display-duration=inf", "--loop-file=inf"]

    ok, info = play_direct_url(
        url,
        ytdlp_path=message.get("ytdlp_path"),
        title=title,
        ref=ref,
        ua=ua,
        extra_flags=extra,
        custom=message.get("custom_flags"),
    )
    send_message({"ok": ok, "info": info})


def native_main():
    try:
        native_dispatch(read_message())
    except Exception as exc:
        log(f"native error:\n{traceback.format_exc()}")
        try:
            send_message({"ok": False, "error": str(exc)})
        except Exception:
            pass
        sys.exit(1)

# ===================== LOCAL / FOLDER / DISC =====================
def split_args(args):
    opts, targets, done = [], [], False
    for item in args:
        if not done and item == "--":
            done = True
            continue
        (opts if not done and item.startswith("--") else targets).append(item)
    return opts, targets


def disc_info(path):
    if not os.path.isdir(path) or "://" in path:
        return None
    root = os.path.realpath(path)
    name = os.path.basename(root).lower()
    if name == "video_ts" or any(
        os.path.isdir(os.path.join(root, d)) for d in ("VIDEO_TS", "video_ts")
    ):
        return "dvd", os.path.dirname(root) if name == "video_ts" else root
    if name == "bdmv" or any(
        os.path.isdir(os.path.join(root, d)) for d in ("BDMV", "bdmv")
    ):
        return "bd", os.path.dirname(root) if name == "bdmv" else root
    return None


def _disc_plan(targets, discs, opts):
    """Direct args + socket payloads for a mixed disc/file list.

    Order is preserved. Disc URIs always load with mode=replace because
    dvd-device/bluray-device is global state; non-disc targets use replace
    only when they are the first target.
    """
    direct = list(opts)
    payloads = []
    for index, target in enumerate(targets):
        disc = discs.get(target)
        if disc:
            kind, device = disc
            dev_key, uri = DISC_MAP[kind]
            direct += [f"--{dev_key}={device}", uri]
            payloads.append(prop_payload(dev_key, device))
            payloads.append(load_payload(uri, "replace", opts))
        else:
            direct.append(target)
            payloads.append(
                load_payload(target, "replace" if index == 0 else "append", opts)
            )
    return direct, payloads


def _file_plan(targets, opts):
    """Direct args + socket payloads for local files/folders."""
    recursive = any(os.path.isdir(x) for x in targets)

    direct = list(opts)
    if recursive:
        direct.append("--directory-mode=recursive")
    direct += ["--", *targets]

    socket_opts = list(opts)
    if recursive:
        socket_opts.append("--directory-mode=recursive")
    payloads = [
        load_payload(
            os.path.realpath(x) if os.path.exists(x) else x,
            "replace" if i == 0 else "append",
            socket_opts,
        )
        for i, x in enumerate(targets)
    ]
    return direct, payloads


def local_cli(args):
    opts, raw_targets = split_args(args)
    if not raw_targets:
        launch_empty()
        return

    targets = [normalize(x) if "://" not in x else x for x in raw_targets]

    # Direct URL.
    if len(targets) == 1 and targets[0].startswith(("http://", "https://")):
        ok, info = play_direct_url(targets[0], title="", extra_flags=opts)
        if not ok:
            notify("mpv-launcher", f"{info}. See launcher-error.log.")
        return

    discs = {target: disc_info(target) for target in targets}
    if any(discs.values()):
        direct, payloads = _disc_plan(targets, discs, opts)
    else:
        direct, payloads = _file_plan(targets, opts)

    ok, info = launch_or_socket(direct, payloads)
    if not ok:
        notify("mpv-launcher", f"{info}. See launcher-error.log.")

# ===================== MAIN =====================
def main():
    setup()

    # Internal pipe worker.
    if len(sys.argv) >= 3 and sys.argv[1] == "--internal-pipe-play":
        data = json.loads(sys.argv[2])
        pipe_play(
            data["url"],
            data["title"],
            data["media_type"],
            data["cmd"],
            data.get("format", ""),
        )
        return

    # Browser native messaging.
    if len(sys.argv) >= 2 and any(
        x.startswith(("chrome-extension://", "moz-extension://"))
        for x in sys.argv[1:]
    ):
        native_main()
        return

    # Menu Quick Action: Automator supplies argv directly.
    if len(sys.argv) >= 2:
        local_cli(sys.argv[1:])
        return

    # Shortcut Quick Action: Finder selection first, then clipboard.
    selected = finder_selection()
    if selected:
        local_cli(selected)
        return

    target = normalize(clipboard())
    if target and (target.startswith(("http://", "https://")) or os.path.exists(target)):
        local_cli([target])
        return

    log("nothing to play (no Finder selection, no usable clipboard target)")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        log(f"unhandled error:\n{traceback.format_exc()}")
        raise