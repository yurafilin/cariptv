"""Local stand-ins for an Xtream Codes panel, a Jellyfin server and an M3U provider with an XMLTV guide,
for checking CarIPTV without real accounts. Video comes from Apple's public HLS test streams.

    python3 Tools/MockServers/mockservers.py                       # Simulator: http://127.0.0.1:8766
    python3 Tools/MockServers/mockservers.py --host 192.168.3.237  # a real iPhone on the same Wi-Fi

Then launch the app with `-CarIPTVDebugSources http://<host>:8766` (see CarIPTV/Debug/DebugSources.swift).
Login for Xtream and Jellyfin: username `1`, password `2`.
"""
import argparse, base64, gzip, http.server, json, os, re, struct, time, zlib
from urllib.parse import urlparse, parse_qs

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="127.0.0.1", help="address to listen on and to put into links")
parser.add_argument("--port", type=int, default=8766)
args = parser.parse_args()
BASE = "http://%s:%d" % (args.host, args.port)
# Plain MP4 files (see makevideo.swift), served with byte ranges like a real CDN.
MEDIA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "media")

# Apple's public test streams (fMP4 HLS and TS HLS).
VIDEO = {
    "live": "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
    "vod": "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8",
}


def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


COLORS = {"m1": (200, 60, 50), "m2": (40, 120, 200), "s1": (150, 80, 180), "e1": (220, 150, 40), "e2": (90, 90, 90)}
SHORT_EPG = {"1": "Morning Briefing", "2": "Live Football", "3": "Classic Cinema"}

XTREAM = {
    None: {"user_info": {"auth": 1, "status": "Active"}, "server_info": {}},
    "get_live_categories": [{"category_id": "1", "category_name": "News"}],
    "get_live_streams": [
        {"stream_id": 1, "name": "Mock News", "category_id": "1", "stream_icon": ""},
        {"stream_id": 2, "name": "Mock Sports", "category_id": "1", "stream_icon": ""},
        {"stream_id": 3, "name": "Mock Movies", "category_id": "1", "stream_icon": ""},
    ],
    "get_vod_categories": [{"category_id": "10", "category_name": "Films"}],
    "get_vod_streams": [
        {"stream_id": 101, "name": "Mock Film", "category_id": "10", "container_extension": "mp4",
         "stream_icon": BASE + "/poster/m1.png", "year": "2024"},
        {"stream_id": 102, "name": "Another Film", "category_id": "10", "container_extension": "mkv",
         "stream_icon": BASE + "/poster/m2.png", "year": "2025"},
    ],
    "get_series_categories": [{"category_id": "20", "category_name": "Shows"}],
    "get_series": [{"series_id": 201, "name": "Mock Show", "category_id": "20", "cover": BASE + "/poster/s1.png"}],
    "get_series_info": {"episodes": {"1": [
        {"id": "301", "episode_num": 1, "title": "Pilot", "container_extension": "mp4",
         "info": {"movie_image": BASE + "/poster/e1.png"}},
        {"id": "302", "episode_num": 2, "title": "Second", "container_extension": "mp4",
         "info": {"movie_image": BASE + "/poster/e2.png"}},
    ]}},
}

JF_VIEWS = [{"Id": "movies", "Name": "Movies", "CollectionType": "movies"},
            {"Id": "shows", "Name": "Shows", "CollectionType": "tvshows"}]
JF_ITEMS = {
    "movies": [{"Id": "m1", "Name": "Jelly Film", "Type": "Movie", "ProductionYear": 2023, "ImageTags": {"Primary": "t"}}],
    "shows": [{"Id": "s1", "Name": "Jelly Show", "Type": "Series", "ImageTags": {"Primary": "t"}}],
}
JF_EPISODES = [
    {"Id": "e1", "Name": "Episode One", "Type": "Episode", "IndexNumber": 1, "ParentIndexNumber": 1, "ImageTags": {"Primary": "t"}},
    {"Id": "e2", "Name": "Episode Two", "Type": "Episode", "IndexNumber": 2, "ParentIndexNumber": 1, "ImageTags": {"Primary": "t"}},
]


def playlist():
    return "\n".join([
        '#EXTM3U url-tvg="%s/epg.xml.gz"' % BASE,
        '#EXTINF:-1 tvg-id="m3u.news" group-title="News",M3U News', BASE + "/live/1/2/1.m3u8",
        # No tvg-id: matched to the guide by name ("Guide Sport HD" ~ "Guide Sport").
        '#EXTINF:-1 group-title="Sport",Guide Sport HD', BASE + "/live/1/2/2.m3u8",
        '#EXTINF:-1 group-title="Other",No Guide Channel', BASE + "/live/1/2/3.m3u8",
        # A plain MP4, directly and behind a redirect (as googlevideo.com serves YouTube files).
        '#EXTINF:-1 group-title="Files",Progressive MP4', BASE + "/media/test.mp4",
        '#EXTINF:-1 group-title="Files",Redirected MP4', BASE + "/redirect/test.mp4",
        # Controls for CarPlay: Apple's stream and our packaged format, both over plain HTTP from the Mac
        # (make them with packagehls.swift and the commands in CLAUDE.md).
        '#EXTINF:-1 group-title="Controls",Apple HLS over HTTP', BASE + "/media/applehls/prog_index.m3u8",
        '#EXTINF:-1 group-title="Controls",Packaged HLS over HTTP', BASE + "/media/packaged/index.m3u8",
        # Apple's stream as a live channel (a sliding window, see live_loop): does the car take live HLS at all?
        '#EXTINF:-1 group-title="Controls",Live TS over HTTP', BASE + "/livesim/applehls.m3u8",
        "",
    ])


LIVE_SOURCES = {"applehls": "applehls/prog_index.m3u8"}


def live_loop(name, window=6):
    """A live playlist like an IPTV channel's: loops a local VOD media playlist by the wall clock,
    keeps the last `window` segments, marks a discontinuity at each wrap."""
    folder = "/media/" + os.path.dirname(name) + "/"
    maps, segments, tags = [], [], []
    for line in open(os.path.join(MEDIA, name)).read().splitlines():
        if line.startswith("#EXT-X-MAP"):
            maps.append(re.sub(r'URI="([^"]+)"', lambda m: 'URI="%s%s"' % (folder, m.group(1)), line))
        elif line.startswith("#EXTINF") or line.startswith("#EXT-X-BYTERANGE"):
            tags.append(line)
        elif line and not line.startswith("#"):
            duration = float(tags[0].split(":")[1].split(",")[0])
            segments.append((duration, tags, folder + line))
            tags = []
    count, total = len(segments), sum(d for d, _, _ in segments)
    loops, rest = divmod(time.time(), total)
    done = 0
    for duration, _, _ in segments:
        if rest < duration:
            break
        rest -= duration
        done += 1
    last = int(loops) * count + done - 1
    first = max(last - window + 1, 0)
    cycle, index = divmod(first, count)
    lines = ["#EXTM3U", "#EXT-X-VERSION:7",
             "#EXT-X-TARGETDURATION:%d" % int(max(d for d, _, _ in segments) + 0.999),
             "#EXT-X-MEDIA-SEQUENCE:%d" % first,
             "#EXT-X-DISCONTINUITY-SEQUENCE:%d" % max(cycle if index > 0 else cycle - 1, 0)] + maps
    for number in range(first, last + 1):
        cycle, index = divmod(number, count)
        if index == 0 and number > first:
            lines.append("#EXT-X-DISCONTINUITY")
        _, tags, uri = segments[index]
        lines += tags + [uri]
    return "\n".join(lines) + "\n"


def guide():
    """XMLTV around now, in +0300 like many providers write it; the second programme has no `stop`."""
    def stamp(t):
        return time.strftime("%Y%m%d%H%M%S", time.gmtime(t + 3 * 3600)) + " +0300"
    now = int(time.time()) // 1800 * 1800
    rows = ['<?xml version="1.0" encoding="UTF-8"?>', '<!DOCTYPE tv SYSTEM "xmltv.dtd">', "<tv>",
            '<channel id="M3U.News"><display-name>M3U News</display-name></channel>',
            '<channel id="sport.guide"><display-name>Guide Sport</display-name></channel>']
    for channel, first, second in [("m3u.news", "Headlines", "World Report"), ("sport.guide", "Pre-match", "Derby Live")]:
        rows.append('<programme start="%s" stop="%s" channel="%s"><title lang="en">%s</title></programme>'
                    % (stamp(now - 1800), stamp(now + 1800), channel, first))
        rows.append('<programme start="%s" channel="%s"><title>%s &amp; More</title></programme>'
                    % (stamp(now + 1800), channel, second))
    rows.append("</tv>")
    return gzip.compress("\n".join(rows).encode())


class Handler(http.server.BaseHTTPRequestHandler):
    def send_bytes(self, body, ctype, status=200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, value, status=200):
        self.send_bytes(json.dumps(value).encode(), "application/json", status)

    def send_file(self, path):
        if not os.path.isfile(path):
            return self.send_json({}, 404)
        size = os.path.getsize(path)
        start, end = 0, size - 1
        m = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
        if m:
            start = int(m.group(1)) if m.group(1) else 0
            end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
        with open(path, "rb") as f:
            f.seek(start)
            body = f.read(end - start + 1)
        self.send_response(206 if m else 200)
        types = {".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t", ".m4s": "video/iso.segment"}
        self.send_header("Content-Type", types.get(os.path.splitext(path)[1], "video/mp4"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        if m:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        m = re.match(r"^/media/((?:[\w-]+/)?[\w.-]+)$", urlparse(self.path).path)
        if m:
            return self.send_file(os.path.join(MEDIA, m.group(1)))
        self.send_json({}, 404)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def authorized(self):
        auth = (self.headers.get("Authorization") or "") + (self.headers.get("X-Emby-Token") or "")
        return "jf-token" in auth

    def do_POST(self):
        path = urlparse(self.path).path
        if path.endswith("/Users/AuthenticateByName"):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            if body.get("Username") == "1" and body.get("Pw") == "2":
                return self.send_json({"AccessToken": "jf-token", "User": {"Id": "jf-user", "ServerName": "Mock Jellyfin"}})
            return self.send_json({}, 401)
        self.send_json({}, 404)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        path = re.sub(r"^/emby(?=/)", "", url.path)

        if path == "/player_api.php":
            if q.get("username") != "1" or q.get("password") != "2":
                return self.send_json({"user_info": {"auth": 0}})
            if q.get("action") == "get_short_epg":
                now = int(time.time()) // 1800 * 1800
                name = SHORT_EPG.get(q.get("stream_id"), "Show")
                b64 = lambda t: base64.b64encode(t.encode()).decode()
                return self.send_json({"epg_listings": [
                    {"title": b64(name), "start_timestamp": str(now), "stop_timestamp": str(now + 1800)},
                    {"title": b64("Up Next: " + name), "start_timestamp": str(now + 1800), "stop_timestamp": str(now + 3600)}]})
            return self.send_json(XTREAM.get(q.get("action"), []))
        m = re.match(r"^/media/((?:[\w-]+/)?[\w.-]+)$", path)
        if m:
            return self.send_file(os.path.join(MEDIA, m.group(1)))
        m = re.match(r"^/redirect/([\w.-]+)$", path)
        if m:
            return self.redirect(BASE + "/media/" + m.group(1))
        if path == "/playlist.m3u":
            return self.send_bytes(playlist().encode(), "audio/x-mpegurl")
        if path == "/epg.xml.gz":
            return self.send_bytes(guide(), "application/gzip")
        m = re.match(r"^/livesim/(\w+)\.m3u8$", path)
        if m and m.group(1) in LIVE_SOURCES:
            return self.send_bytes(live_loop(LIVE_SOURCES[m.group(1)]).encode(), "application/vnd.apple.mpegurl")
        if re.match(r"^/live/1/2/", path):
            return self.redirect(VIDEO["live"])
        if re.match(r"^/(movie|series)/1/2/", path) or re.match(r"^/Videos/[^/]+/master\.m3u8$", path):
            return self.redirect(VIDEO["vod"])
        m = re.match(r"^/(?:poster/(\w+)\.png|Items/(\w+)/Images/Primary)$", path)
        if m:
            key = m.group(1) or m.group(2)
            return self.send_bytes(png(60, 90, COLORS.get(key, (120, 120, 120))), "image/png")
        if path == "/UserViews" or re.match(r"^/Users/[^/]+/Views$", path):
            return self.send_json({"Items": JF_VIEWS}) if self.authorized() else self.send_json({}, 401)
        if path == "/Items" or re.match(r"^/Users/[^/]+/Items$", path):
            return self.send_json({"Items": JF_ITEMS.get(q.get("ParentId"), [])}) if self.authorized() else self.send_json({}, 401)
        if re.match(r"^/Shows/[^/]+/Episodes$", path):
            return self.send_json({"Items": JF_EPISODES})
        self.send_json({}, 404)


print("Serving %s" % BASE, flush=True)
http.server.ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
