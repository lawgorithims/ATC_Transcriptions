#!/usr/bin/env python3
"""CommSight cockpit-audio handshake tests (laptop side).

Quick link-health checks for the Raspberry Pi audio sidecar <-> CommSight iPad
path. Run this from a laptop joined to the Stratux WiFi AP (SSID "stratux"):

    python3 handshake_test.py
    python3 handshake_test.py --host 192.168.10.1 --audio-port 8090 --seconds 10
    python3 handshake_test.py --expect-tone 1000      # tone-loopback wire check
    python3 handshake_test.py --with-stratux          # also check /getSituation

Python 3.9+ standard library only; no third-party packages. Every network
operation has a timeout -- the suite never hangs.

This is a fast handshake check, NOT a soak test. For sustained-load
validation of the client, see ios/Tools/stratux_validate.sh.

Tests:
  T1  TCP reachability of the audio port
  T2  GET /health -- JSON status, device presence
  T3  GET /audio.raw -- byte rate + PCM sanity (level, clipping, dead input)
  T4  second concurrent stream client is rejected with 409
  T5  GET /audio.wav -- WAV header matches 16 kHz mono 16-bit
  T6  drop + immediate reconnect (the iPad does this constantly)
  T7  (--expect-tone HZ) Goertzel tone detection in the captured PCM
  T8  (--with-stratux) Stratux /getSituation on port 80

Exit code 0 only if every non-skipped test passed.
"""

import argparse
import array
import http.client
import json
import math
import socket
import struct
import sys
import time

DEFAULT_HOST = "192.168.10.1"
DEFAULT_AUDIO_PORT = 8090

EXPECT_RATE = 16000
EXPECT_CHANNELS = 1
EXPECT_BYTES_PER_SEC = 32000        # 16000 samples/s * 1 ch * 2 B
RATE_TOLERANCE = 0.15               # +/- 15%
CLIP_THRESHOLD = 32700              # |sample| at/above this counts as clipped
CLIP_MAX_FRACTION = 0.30

TCP_TIMEOUT = 3.0                   # T1 fail-fast
HTTP_TIMEOUT = 5.0                  # request/response timeout for small GETs
STREAM_TIMEOUT = 5.0                # per-read timeout while streaming
RECONNECT_DEADLINE = 5.0            # T6: bytes must flow again within this
LOCK_RELEASE_DEADLINE = 6.0         # wait for capture lock between stream tests
HEALTH_POLL_TIMEOUT = 2.0           # per-request timeout while polling /health
TONE_SEARCH_BINS = 4                # T7: search +/- this many DFT bins around
                                    # the target (+/-2 Hz on the 2 s window) to
                                    # tolerate tone-source/ADC clock skew

RESULTS = []                        # list of (test_id, name, status, reason)


# ---------------------------------------------------------------- utilities

def split_host(raw):
    """The app's host field may carry a port for the Stratux web-API side
    (e.g. "127.0.0.1:9408"). The audio side wants a bare host. Returns
    (bare_host, stratux_netloc)."""
    raw = raw.strip()
    if ":" in raw and not raw.startswith("["):
        return raw.split(":", 1)[0], raw
    return raw, raw


def close_quietly(conn):
    try:
        conn.close()
    except Exception:
        pass


def close_stream(conn, resp, rst=False):
    """Really close a streaming connection.

    With 'Connection: close' responses, http.client hands the socket to the
    response object at getresponse() time, so conn.close() alone does NOT
    close the file descriptor -- the response must be closed. With rst=True
    the socket is closed with SO_LINGER=0 so the server sees an immediate
    TCP RST (what the sidecar sees when the iPad drops off the AP) instead
    of a graceful FIN it might not notice for many seconds while its paced
    writes still fit in socket buffers."""
    if rst:
        sock = getattr(conn, "sock", None)
        if sock is None and resp is not None:
            raw = getattr(getattr(resp, "fp", None), "raw", None)
            sock = getattr(raw, "_sock", None)
        try:
            if sock is not None:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                struct.pack("ii", 1, 0))
        except Exception:
            pass
    if resp is not None:
        try:
            resp.close()
        except Exception:
            pass
    close_quietly(conn)


def http_get(host, port, path, timeout=HTTP_TIMEOUT):
    """Simple bounded GET. Returns (status, headers_dict, body_bytes)."""
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("GET", path, headers={"Connection": "close"})
        resp = conn.getresponse()
        # Bounded read: never resp.read() an unknown server -- if the path
        # unexpectedly serves an endless stream, an unbounded read would
        # never finish (data keeps flowing, so the timeout never fires).
        body = b""
        while len(body) < 1048576:
            chunk = resp.read(65536)
            if not chunk:
                break
            body += chunk
        headers = {}
        for k, v in resp.getheaders():
            headers[k.lower()] = v
        resp.close()
        return resp.status, headers, body
    finally:
        close_quietly(conn)


def open_stream(host, port, path, timeout=STREAM_TIMEOUT):
    """Open a streaming GET; caller must close the returned connection.
    Returns (conn, resp)."""
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("GET", path, headers={"Connection": "close"})
        resp = conn.getresponse()
    except Exception:
        close_quietly(conn)
        raise
    return conn, resp


def read_exact(resp, n):
    """Read exactly n bytes from a streaming response (or fewer on EOF)."""
    buf = b""
    while len(buf) < n:
        chunk = resp.read(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def describe_error_body(body):
    """Render a JSON error body ({"ok": false, "error": ...}) as a hint."""
    try:
        obj = json.loads(body.decode("utf-8", "replace"))
        err = obj.get("error", "?")
        detail = obj.get("detail") or obj.get("hint") or ""
        if detail:
            return "%s (%s)" % (err, str(detail)[:120])
        return str(err)
    except Exception:
        return repr(body[:120])


def wait_stream_free(host, port, deadline_s=LOCK_RELEASE_DEADLINE):
    """Poll /health until streaming==false so the previous test's capture
    lock has been released. Returns one of:
      "free"        -- streaming==false (or /health answers but is broken:
                       non-200 / bad JSON, already flagged by T2 -- do not
                       gate the remaining tests on it)
      "locked"      -- /health kept reporting streaming==true to the deadline
      "unreachable" -- /health repeatedly TIMED OUT (server accepts TCP but
                       never answers); the lock state is unknowable, so the
                       caller should blame the hung /health, not the lock."""
    deadline = time.monotonic() + deadline_s
    timeouts = 0
    while time.monotonic() < deadline:
        try:
            status, _, body = http_get(host, port, "/health",
                                       timeout=HEALTH_POLL_TIMEOUT)
        except socket.timeout:
            # A hung /health can never report the lock free -- distinguish it
            # so the failure is not misattributed to the capture lock.
            timeouts += 1
            if timeouts >= 2:
                return "unreachable"
            continue
        except ConnectionRefusedError:
            # Nothing is listening (sidecar crashed?) -- no process is
            # holding the lock. Let the next test connect and report the
            # real error instead of blaming the capture lock.
            return "free"
        except Exception:
            timeouts = 0
            time.sleep(0.25)
            continue
        timeouts = 0
        if status != 200:
            return "free"
        try:
            obj = json.loads(body.decode("utf-8", "replace"))
        except ValueError:
            return "free"
        if not isinstance(obj, dict) or not obj.get("streaming", False):
            return "free"
        time.sleep(0.25)
    return "locked"


def stream_free_gate(host, port):
    """Wait for the previous stream test's capture lock to clear.
    Returns None if the next stream test may run, else a FAIL reason that
    names the actual culprit (held lock vs. hung /health)."""
    state = wait_stream_free(host, port)
    if state == "free":
        return None
    if state == "unreachable":
        return ("/health is not answering (repeated %.0f s timeouts: the "
                "server accepts TCP but never responds) -- cannot confirm "
                "the capture lock was released; fix the hung /health on "
                "the Pi" % HEALTH_POLL_TIMEOUT)
    return ("capture lock still held %.0f s after the previous stream "
            "closed -- lock not released on client disconnect"
            % LOCK_RELEASE_DEADLINE)


def decode_s16le(pcm):
    """bytes -> array of int16 samples (drops an odd trailing byte)."""
    usable = len(pcm) - (len(pcm) % 2)
    samples = array.array("h")
    samples.frombytes(pcm[:usable])
    if sys.byteorder == "big":
        samples.byteswap()
    return samples


def goertzel_power_k(samples, k):
    """Goertzel power at DFT bin index k. samples: sequence of numbers."""
    n = len(samples)
    w = 2.0 * math.pi * k / n
    coeff = 2.0 * math.cos(w)
    s1 = 0.0
    s2 = 0.0
    for x in samples:
        s0 = x + coeff * s1 - s2
        s2 = s1
        s1 = s0
    return s1 * s1 + s2 * s2 - coeff * s1 * s2


def goertzel_power(samples, rate, freq):
    """Goertzel power at freq (snapped to the nearest DFT bin)."""
    n = len(samples)
    return goertzel_power_k(samples, int(0.5 + (n * freq) / float(rate)))


# ------------------------------------------------------------------- tests

def t1_tcp_reach(host, port):
    t0 = time.monotonic()
    try:
        sock = socket.create_connection((host, port), timeout=TCP_TIMEOUT)
        sock.close()
        ms = (time.monotonic() - t0) * 1000.0
        return "PASS", "TCP connect to %s:%d in %.0f ms" % (host, port, ms)
    except socket.timeout:
        return "FAIL", ("no TCP response from %s:%d within %.0f s -- are you "
                        "on the stratux WiFi? (SSID 'stratux', Pi at %s)"
                        % (host, port, TCP_TIMEOUT, DEFAULT_HOST))
    except OSError as e:
        return "FAIL", ("cannot connect to %s:%d (%s) -- are you on the "
                        "stratux WiFi? Is the cockpit-audio sidecar installed "
                        "and running on the Pi? (run pi_selftest.sh on the Pi)"
                        % (host, port, e))


def t2_health(host, port):
    """Returns (status, reason, health_dict_or_None)."""
    try:
        status, headers, body = http_get(host, port, "/health")
    except Exception as e:
        return "FAIL", "GET /health failed: %s" % e, None
    if status != 200:
        return "FAIL", "GET /health returned HTTP %d: %s" % (
            status, describe_error_body(body)), None
    try:
        obj = json.loads(body.decode("utf-8", "replace"))
    except Exception as e:
        return "FAIL", "GET /health body is not valid JSON (%s)" % e, None
    if not isinstance(obj, dict):
        return "FAIL", "GET /health JSON is not an object", obj if isinstance(obj, dict) else None

    svc = obj.get("service")
    resolved = obj.get("resolved_device")
    present = obj.get("device_present")
    has_arecord = obj.get("arecord")
    streaming = obj.get("streaming")
    info = "service=%s resolved_device=%s device_present=%s streaming=%s" % (
        svc, resolved, present, streaming)

    if has_arecord is False:
        return "FAIL", ("arecord missing on the Pi (%s) -- fix: ssh in and "
                        "run: sudo apt-get install -y alsa-utils" % info), obj
    if present is False:
        return "FAIL", ("device_present=false for %s (%s) -- fix: plug in the "
                        "USB audio adapter, check 'arecord -l' on the Pi, or "
                        "set AUDIO_DEVICE in /etc/default/cockpit-audio"
                        % (resolved, info)), obj
    if obj.get("ok") is not True:
        return "FAIL", "health reports ok=false (%s)" % info, obj
    return "PASS", info, obj


def t3_audio_stream(host, port, seconds):
    """Stream /audio.raw for `seconds`; check byte rate and PCM sanity.
    Returns (status, reason, samples_or_None)."""
    try:
        conn, resp = open_stream(host, port, "/audio.raw")
    except socket.timeout:
        return "FAIL", "timed out opening /audio.raw", None
    except OSError as e:
        return "FAIL", "cannot open /audio.raw: %s" % e, None

    try:
        if resp.status == 409:
            body = resp.read(2048)
            return "FAIL", ("HTTP 409 %s -- another client already holds the "
                            "stream (the iPad?). Quit CommSight / disconnect "
                            "other clients and rerun."
                            % describe_error_body(body)), None
        if resp.status == 503:
            body = resp.read(2048)
            return "FAIL", ("HTTP 503 %s -- capture failed on the Pi; check "
                            "the USB audio adapter and 'arecord -l'"
                            % describe_error_body(body)), None
        if resp.status != 200:
            body = resp.read(2048)
            return "FAIL", "HTTP %d from /audio.raw: %s" % (
                resp.status, describe_error_body(body)), None

        # Header conformance (informational for the app, but a mismatch here
        # means the PCM interpretation below would be wrong).
        hdr_notes = []
        expect_hdrs = (("X-Audio-Format", "S16_LE"),
                       ("X-Audio-Rate", str(EXPECT_RATE)),
                       ("X-Audio-Channels", str(EXPECT_CHANNELS)))
        for name, want in expect_hdrs:
            got = resp.getheader(name)
            if got is not None and got != want:
                hdr_notes.append("%s=%s (expected %s)" % (name, got, want))
        if hdr_notes:
            return "FAIL", "audio format header mismatch: %s" % ", ".join(hdr_notes), None

        # First frame: the server pre-reads one 640 B frame before the 200,
        # so bytes should arrive immediately. Do not count arecord startup
        # in the rate measurement.
        try:
            first = read_exact(resp, 640)
        except socket.timeout:
            return "FAIL", "got 200 but no PCM within %.0f s" % STREAM_TIMEOUT, None
        if not first:
            return "FAIL", "got 200 but the stream closed with 0 bytes", None

        chunks = [first]
        counted = 0
        t0 = time.monotonic()
        while True:
            elapsed = time.monotonic() - t0
            if elapsed >= seconds:
                break
            try:
                data = resp.read(4096)
            except socket.timeout:
                return "FAIL", ("stream stalled: no bytes for %.0f s after "
                                "%.1f s / %d bytes (arecord wedged on the Pi?)"
                                % (STREAM_TIMEOUT, elapsed, counted)), None
            if not data:
                return "FAIL", ("server closed the stream after %.1f s / %d "
                                "bytes (expected an endless stream)"
                                % (elapsed, counted)), None
            chunks.append(data)
            counted += len(data)
        elapsed = time.monotonic() - t0
    finally:
        close_stream(conn, resp, rst=True)

    rate = counted / elapsed if elapsed > 0 else 0.0
    pcm = b"".join(chunks)
    samples = decode_s16le(pcm)
    n = len(samples)

    problems = []
    lo = EXPECT_BYTES_PER_SEC * (1.0 - RATE_TOLERANCE)
    hi = EXPECT_BYTES_PER_SEC * (1.0 + RATE_TOLERANCE)
    if not (lo <= rate <= hi):
        problems.append("byte rate %.0f B/s outside %d +/- %d%%"
                        % (rate, EXPECT_BYTES_PER_SEC, int(RATE_TOLERANCE * 100)))

    if n == 0:
        problems.append("no decodable samples")
        return "FAIL", "; ".join(problems), None

    smin = min(samples)
    smax = max(samples)
    sum_sq = 0.0
    clipped = 0
    for s in samples:
        sum_sq += float(s) * float(s)
        if s >= CLIP_THRESHOLD or s <= -CLIP_THRESHOLD:
            clipped += 1
    rms = math.sqrt(sum_sq / n)
    if rms > 0:
        dbfs = 20.0 * math.log10(rms / 32768.0)
        dbfs_str = "%.1f dBFS" % dbfs
    else:
        dbfs_str = "-inf dBFS"
    clip_frac = clipped / float(n)

    if smin == smax:
        problems.append("dead input: PCM is constant (%d) -- adapter unplugged"
                        " from the audio source, or capture channel muted"
                        % smin)
    if clip_frac >= CLIP_MAX_FRACTION:
        problems.append("clipping %.1f%% of samples (>= %d%%) -- reduce the "
                        "capture gain with alsamixer on the Pi"
                        % (clip_frac * 100.0, int(CLIP_MAX_FRACTION * 100)))

    info = ("%.1f s, %.0f B/s, %d samples, RMS %s, clip %.2f%%, range [%d, %d]"
            % (elapsed, rate, n, dbfs_str, clip_frac * 100.0, smin, smax))
    if problems:
        return "FAIL", "; ".join(problems) + " -- " + info, samples
    return "PASS", info, samples


def t4_second_client_409(host, port):
    try:
        conn_a, resp_a = open_stream(host, port, "/audio.raw")
    except OSError as e:
        return "FAIL", "could not open the first stream: %s" % e
    try:
        if resp_a.status != 200:
            body = resp_a.read(2048)
            return "FAIL", "first stream got HTTP %d (%s), cannot test the lock" % (
                resp_a.status, describe_error_body(body))
        try:
            got = read_exact(resp_a, 640)
        except socket.timeout:
            got = b""
        if not got:
            return "FAIL", "first stream sent no bytes, cannot test the lock"

        # While A holds the capture lock, B must be rejected with 409.
        try:
            conn_b, resp_b = open_stream(host, port, "/audio.raw")
        except OSError as e:
            return "FAIL", "second connection failed at TCP level: %s" % e
        try:
            status_b = resp_b.status
            if status_b == 200:
                body_b = b""          # endless stream -- do NOT read it out
            else:
                body_b = resp_b.read(2048)
        finally:
            close_stream(conn_b, resp_b, rst=True)

        if status_b != 409:
            return "FAIL", ("second concurrent client got HTTP %d, expected "
                            "409 audio_stream_already_in_use -- two clients "
                            "sharing one arecord would corrupt both streams"
                            % status_b)
        err = describe_error_body(body_b)
        if "audio_stream_already_in_use" not in err:
            return "FAIL", "second client got 409 but body says: %s" % err
        return "PASS", "second concurrent client correctly rejected: 409 %s" % err
    finally:
        close_stream(conn_a, resp_a, rst=True)


def t5_wav_header(host, port):
    try:
        conn, resp = open_stream(host, port, "/audio.wav")
    except OSError as e:
        return "FAIL", "cannot open /audio.wav: %s" % e
    try:
        if resp.status != 200:
            body = resp.read(2048)
            return "FAIL", "HTTP %d from /audio.wav: %s" % (
                resp.status, describe_error_body(body))
        ctype = resp.getheader("Content-Type", "")
        try:
            head = read_exact(resp, 64)
        except socket.timeout:
            return "FAIL", "got 200 but no WAV header bytes within %.0f s" % STREAM_TIMEOUT
    finally:
        close_stream(conn, resp, rst=True)

    if len(head) < 44:
        return "FAIL", "short read: only %d header bytes (need >= 44)" % len(head)
    if head[0:4] != b"RIFF" or head[8:12] != b"WAVE":
        return "FAIL", "not a RIFF/WAVE header: %r" % head[:16]

    # Walk chunks to find "fmt " (arecord puts it right at offset 12).
    pos = 12
    fmt_fields = None
    while pos + 8 <= len(head):
        cid = head[pos:pos + 4]
        (csize,) = struct.unpack("<I", head[pos + 4:pos + 8])
        if cid == b"fmt ":
            if pos + 8 + 16 > len(head):
                return "FAIL", "fmt chunk truncated in first 64 bytes"
            fmt_fields = struct.unpack("<HHIIHH", head[pos + 8:pos + 8 + 16])
            break
        if cid == b"data":
            break
        pos += 8 + csize + (csize % 2)
    if fmt_fields is None:
        return "FAIL", "no fmt chunk found in the first 64 bytes"

    audio_format, channels, rate, byte_rate, block_align, bits = fmt_fields
    bad = []
    if audio_format != 1:
        bad.append("format=%d (want 1=PCM)" % audio_format)
    if channels != EXPECT_CHANNELS:
        bad.append("channels=%d (want %d)" % (channels, EXPECT_CHANNELS))
    if rate != EXPECT_RATE:
        bad.append("rate=%d (want %d)" % (rate, EXPECT_RATE))
    if bits != 16:
        bad.append("bits=%d (want 16)" % bits)
    if byte_rate != EXPECT_BYTES_PER_SEC:
        bad.append("byte_rate=%d (want %d)" % (byte_rate, EXPECT_BYTES_PER_SEC))
    if bad:
        return "FAIL", "WAV fmt mismatch: %s" % ", ".join(bad)
    info = ("PCM %d Hz, %d ch, %d-bit, %d B/s (Content-Type: %s)"
            % (rate, channels, bits, byte_rate, ctype))
    return "PASS", info


def t6_reconnect(host, port):
    # Open a stream, confirm bytes, then drop it abruptly and reconnect
    # immediately -- exactly what the iPad's 1.5 s-backoff loop does after
    # every WiFi hiccup. Bytes must flow again within RECONNECT_DEADLINE.
    try:
        conn, resp = open_stream(host, port, "/audio.raw")
    except OSError as e:
        return "FAIL", "could not open the initial stream: %s" % e
    try:
        if resp.status != 200:
            body = resp.read(2048)
            return "FAIL", "initial stream got HTTP %d (%s)" % (
                resp.status, describe_error_body(body))
        try:
            got = read_exact(resp, 1280)
        except socket.timeout:
            got = b""
        if not got:
            return "FAIL", "initial stream sent no bytes"
    finally:
        close_stream(conn, resp, rst=True)  # abrupt drop (RST, like a WiFi vanish)

    t_drop = time.monotonic()
    deadline = t_drop + RECONNECT_DEADLINE
    last = "no attempt completed"
    attempts = 0
    while time.monotonic() < deadline:
        attempts += 1
        try:
            conn2, resp2 = open_stream(host, port, "/audio.raw", timeout=2.0)
        except OSError as e:
            last = "connect error: %s" % e
            time.sleep(0.2)
            continue
        try:
            if resp2.status == 200:
                try:
                    data = read_exact(resp2, 640)
                except socket.timeout:
                    data = b""
                if data:
                    ms = (time.monotonic() - t_drop) * 1000.0
                    return "PASS", ("bytes flowing again %.0f ms after the "
                                    "drop (attempt %d)" % (ms, attempts))
                last = "reconnected (200) but no bytes"
            elif resp2.status == 409:
                last = ("still 409 (capture lock not released after client "
                        "drop)")
            else:
                body = resp2.read(2048)
                last = "HTTP %d: %s" % (resp2.status, describe_error_body(body))
        finally:
            close_stream(conn2, resp2, rst=True)
        time.sleep(0.2)
    return "FAIL", ("no audio within %.0f s of a client drop (%d attempts; "
                    "last: %s) -- the iPad would show a dead audio feed after "
                    "every WiFi hiccup" % (RECONNECT_DEADLINE, attempts, last))


def t7_tone(samples, freq):
    if samples is None or len(samples) < 4000:
        return "FAIL", "not enough captured PCM from T3 to analyze"
    if freq <= 0 or freq >= EXPECT_RATE / 2.0:
        return "FAIL", "--expect-tone %.0f Hz is outside (0, %d) at a %d Hz sample rate" % (
            freq, EXPECT_RATE // 2, EXPECT_RATE)

    # Use up to 2 s from the middle of the capture (skips connect transients).
    want = 2 * EXPECT_RATE
    if len(samples) > want:
        start = (len(samples) - want) // 2
        window = samples[start:start + want]
    else:
        window = samples
    n = len(window)

    total = 0.0
    for x in window:
        total += float(x) * float(x)
    if total <= 0.0:
        return "FAIL", "captured PCM is silent; no tone to detect"

    # Search a small neighborhood of bins around the target rather than a
    # single bin-snapped probe. On the 2 s rectangular window the bins are
    # only 0.5 Hz wide, with Dirichlet nulls at exact bin offsets -- so a
    # mere 0.5 Hz of clock skew between the tone source and the USB
    # adapter's ADC (500 ppm at 1 kHz, routine for a phone playing a
    # resampled tone into a cheap adapter) would land a perfectly good tone
    # in a null and hard-FAIL the wire check. Take the strongest bin within
    # +/-TONE_SEARCH_BINS (+/-2 Hz here).
    k0 = int(0.5 + (n * freq) / float(EXPECT_RATE))
    best_k = max(1, k0 - TONE_SEARCH_BINS)
    p_tone = 0.0
    for k in range(max(1, k0 - TONE_SEARCH_BINS),
                   min(n // 2, k0 + TONE_SEARCH_BINS + 1)):
        p = goertzel_power_k(window, k)
        if p > p_tone:
            p_tone = p
            best_k = k
    best_hz = best_k * EXPECT_RATE / float(n)
    search_hz = TONE_SEARCH_BINS * EXPECT_RATE / float(n)
    # Fraction of signal energy at the winning bin (1.0 for a pure tone).
    tone_energy_frac = min(1.0, (2.0 * p_tone) / (n * total))

    # Off-tone probes (non-harmonic multiples) to establish the noise floor.
    probe_best = 0.0
    probes = []
    for mult in (0.62, 1.41, 1.73):
        pf = freq * mult
        if 0 < pf < EXPECT_RATE / 2.0:
            probes.append(pf)
            probe_best = max(probe_best, goertzel_power(window, EXPECT_RATE, pf))
    ratio = p_tone / probe_best if probe_best > 0 else float("inf")

    detected = tone_energy_frac >= 0.04 and ratio >= 5.0
    if ratio > 1e6:
        ratio_str = ">1e6x"
    else:
        ratio_str = "%.0fx" % ratio
    info = ("%.0f Hz (best bin %.2f Hz, searched +/-%.1f Hz) holds %.1f%% "
            "of signal energy, %s above off-tone probes (%s Hz)"
            % (freq, best_hz, search_hz, tone_energy_frac * 100.0, ratio_str,
               "/".join("%.0f" % p for p in probes)))
    if detected:
        return "PASS", "tone detected: " + info
    return "FAIL", ("tone NOT detected: " + info + " -- check the cable into "
                    "the Pi's USB adapter mic-in and the phone's tone volume")


def t8_stratux_situation(stratux_netloc):
    if ":" in stratux_netloc and not stratux_netloc.startswith("["):
        host, port_s = stratux_netloc.split(":", 1)
        try:
            port = int(port_s)
        except ValueError:
            return "FAIL", "bad Stratux host:port %r" % stratux_netloc
    else:
        host, port = stratux_netloc, 80
    try:
        status, _, body = http_get(host, port, "/getSituation")
    except Exception as e:
        return "FAIL", ("Stratux web API unreachable at %s:%d (%s) -- the "
                        "audio sidecar may still work, but the app gets no "
                        "GPS/traffic" % (host, port, e))
    if status != 200:
        return "FAIL", "GET /getSituation returned HTTP %d" % status
    try:
        obj = json.loads(body.decode("utf-8", "replace"))
    except Exception as e:
        return "FAIL", "/getSituation body is not valid JSON (%s)" % e
    if not isinstance(obj, dict):
        return "FAIL", "/getSituation JSON is not an object"
    fix = obj.get("GPSFixQuality")
    sats = obj.get("GPSSatellites")
    return "PASS", ("Stratux answering at %s:%d (GPSFixQuality=%s, "
                    "GPSSatellites=%s)" % (host, port, fix, sats))


# -------------------------------------------------------------------- main

def record(test_id, name, status, reason):
    RESULTS.append((test_id, name, status, reason))
    print("%-3s %-4s %-18s %s" % (test_id, status, name, reason))
    sys.stdout.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="CommSight Pi<->iPad audio-stream handshake tests "
                    "(quick link-health; for sustained load use "
                    "ios/Tools/stratux_validate.sh).")
    parser.add_argument("--host", default=DEFAULT_HOST,
                        help="Pi address (default %s)" % DEFAULT_HOST)
    parser.add_argument("--audio-port", type=int, default=DEFAULT_AUDIO_PORT,
                        help="cockpit-audio sidecar port (default %d)"
                             % DEFAULT_AUDIO_PORT)
    parser.add_argument("--seconds", type=float, default=10.0,
                        help="how long to sample /audio.raw in T3 (default 10)")
    parser.add_argument("--expect-tone", type=float, default=None, metavar="HZ",
                        help="run T7: detect this tone (Hz) in the captured "
                             "PCM (play it into the Pi's audio input first)")
    parser.add_argument("--with-stratux", action="store_true",
                        help="run T8: also check Stratux's own /getSituation "
                             "on port 80")
    args = parser.parse_args(argv)

    if args.seconds < 2.0:
        print("note: clamping --seconds to 2.0 (need enough PCM to analyze)")
        args.seconds = 2.0

    audio_host, stratux_netloc = split_host(args.host)
    port = args.audio_port
    print("target: audio http://%s:%d  stratux http://%s/" %
          (audio_host, port, stratux_netloc))
    print()

    samples = None
    reachable = False

    # T1
    status, reason = t1_tcp_reach(audio_host, port)
    record("T1", "tcp-reach", status, reason)
    reachable = (status == "PASS")

    # T2
    if reachable:
        status, reason, _health = t2_health(audio_host, port)
    else:
        status, reason = "SKIP", "skipped: no TCP connectivity (T1 failed)"
    record("T2", "health", status, reason)

    # T3
    if reachable:
        status, reason, samples = t3_audio_stream(audio_host, port, args.seconds)
    else:
        status, reason = "SKIP", "skipped: no TCP connectivity (T1 failed)"
    record("T3", "audio-stream", status, reason)

    # T4
    if reachable:
        gate = stream_free_gate(audio_host, port)
        if gate is not None:
            status, reason = "FAIL", gate
        else:
            status, reason = t4_second_client_409(audio_host, port)
    else:
        status, reason = "SKIP", "skipped: no TCP connectivity (T1 failed)"
    record("T4", "single-client-409", status, reason)

    # T5
    if reachable:
        gate = stream_free_gate(audio_host, port)
        if gate is not None:
            status, reason = "FAIL", "%s; cannot open /audio.wav" % gate
        else:
            status, reason = t5_wav_header(audio_host, port)
    else:
        status, reason = "SKIP", "skipped: no TCP connectivity (T1 failed)"
    record("T5", "wav-header", status, reason)

    # T6
    if reachable:
        gate = stream_free_gate(audio_host, port)
        if gate is not None:
            status, reason = "FAIL", "%s; cannot test reconnect" % gate
        else:
            status, reason = t6_reconnect(audio_host, port)
    else:
        status, reason = "SKIP", "skipped: no TCP connectivity (T1 failed)"
    record("T6", "reconnect", status, reason)

    # T7
    if args.expect_tone is None:
        status, reason = "SKIP", "skipped: no --expect-tone given"
    elif samples is None:
        status, reason = "FAIL", "no PCM captured in T3 to analyze"
    else:
        status, reason = t7_tone(samples, args.expect_tone)
    record("T7", "tone-loopback", status, reason)

    # T8
    if not args.with_stratux:
        status, reason = "SKIP", "skipped: run with --with-stratux to check"
    else:
        status, reason = t8_stratux_situation(stratux_netloc)
    record("T8", "stratux-situation", status, reason)

    # Summary
    print()
    print("=" * 72)
    print("SUMMARY")
    print("-" * 72)
    for test_id, name, status, reason in RESULTS:
        print("%-3s %-4s %-18s %s" % (test_id, status, name, reason))
    n_pass = sum(1 for r in RESULTS if r[2] == "PASS")
    n_fail = sum(1 for r in RESULTS if r[2] == "FAIL")
    n_skip = sum(1 for r in RESULTS if r[2] == "SKIP")
    print("-" * 72)
    print("result: %d passed, %d failed, %d skipped" % (n_pass, n_fail, n_skip))
    if n_fail == 0:
        print("HANDSHAKE OK -- the Pi->iPad audio link contract holds.")
        return 0
    print("HANDSHAKE FAILED -- fix the FAIL lines above before flying.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
