"""SponsorBlock helper for providers/sponsorblock.lua.

Usage: sponsorblock.py <command> <args...>

  ranges   SERVER VIDEO_ID CATEGORIES SHA_LENGTH
  submit   SERVER VIDEO_ID START END CATEGORY UID_PATH USER_ID
  stats    SERVER UUID UID_PATH USER_ID VIEW VOTE_TYPE      (VIEW / VOTE_TYPE may be "")
  username SERVER NAME UID_PATH USER_ID

Positional on purpose: YouTube IDs can start with "-", which option parsers choke on.
"""
import hashlib
import json
import os
import random
import string
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 15
USER_AGENT = "mpv_sponsorblock/1.0 (https://github.com/po5/mpv_sponsorblock)"

opener = urllib.request.build_opener()
opener.addheaders = [("User-Agent", USER_AGENT)]
urllib.request.install_opener(opener)


def get_uid(uid_path, user_id):
    """Explicit user_id wins; otherwise reuse (or create) the stored random one."""
    if user_id:
        return user_id
    if os.path.isfile(uid_path):
        with open(uid_path) as f:
            return f.read()
    uid = "".join(random.choices(string.ascii_letters + string.digits, k=36))
    os.makedirs(os.path.dirname(uid_path), exist_ok=True)
    with open(uid_path, "w") as f:
        f.write(uid)
    return uid


def cmd_ranges(server, video_id, categories, sha_length):
    """Print 'start,end,uuid,category' entries joined by ':'; 'error' on failure; '' if none."""
    n = int(sha_length)
    sha = hashlib.sha256(video_id.encode()).hexdigest()[:n] if 3 <= n <= 32 else None
    query = urllib.parse.urlencode([("categories", json.dumps(categories.split(",")))])
    if sha:
        url = f"{server}/api/skipSegments/{sha}?{query}"
    else:
        url = f"{server}/api/skipSegments?videoID={video_id}&{query}"

    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
            segments = json.load(response)
    except urllib.error.HTTPError as e:   # must precede URLError (its parent class)
        print("" if e.code == 404 else "error")
        return
    except (OSError, ValueError):
        print("error")
        return

    times = []
    for segment in segments:
        if sha:
            if segment["videoID"] != video_id:
                continue
            for s in segment["segments"]:
                times.append(f'{s["segment"][0]},{s["segment"][1]},{s["UUID"]},{s["category"]}')
        else:
            times.append(f'{segment["segment"][0]},{segment["segment"][1]},{segment["UUID"]},{segment["category"]}')
    print(":".join(times))


def cmd_submit(server, video_id, start, end, category, uid_path, user_id):
    """Print 'success', the HTTP error code, or 'error'."""
    payload = {
        "videoID": video_id,
        "segments": [{"segment": [float(start), float(end)], "category": category}],
        "userID": get_uid(uid_path, user_id),
    }
    try:
        req = urllib.request.Request(
            server + "/api/skipSegments",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=TIMEOUT)
        print("success")
    except urllib.error.HTTPError as e:
        print(e.code)
    except Exception:
        print("error")


def cmd_stats(server, uuid, uid_path, user_id, view, vote_type):
    uid = get_uid(uid_path, user_id)
    try:
        if view:
            urllib.request.urlopen(f"{server}/api/viewedVideoSponsorTime?UUID={uuid}", timeout=TIMEOUT)
        if vote_type:
            urllib.request.urlopen(
                f"{server}/api/voteOnSponsorTime?UUID={uuid}&userID={uid}&type={vote_type}", timeout=TIMEOUT)
    except Exception:
        pass


def cmd_username(server, name, uid_path, user_id):
    uid = get_uid(uid_path, user_id)
    try:
        data = urllib.parse.urlencode({"userID": uid, "userName": name}).encode()
        urllib.request.urlopen(urllib.request.Request(server + "/api/setUsername", data=data), timeout=TIMEOUT)
    except Exception:
        pass


COMMANDS = {
    "ranges": cmd_ranges,
    "submit": cmd_submit,
    "stats": cmd_stats,
    "username": cmd_username,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](*sys.argv[2:])
