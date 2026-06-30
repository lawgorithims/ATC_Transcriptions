"""ALSA capture helpers: enumerate capture devices, auto-pick the USB adapter, build the arecord
command. Thin wrappers over `arecord` so the server stays simple and the logic is testable.
"""
import re
import shutil
import subprocess

# "card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]"
_CARD_RE = re.compile(r"^card (\d+): (\S+) \[([^\]]*)\], device (\d+): (.+)$")
_HW_RE = re.compile(r"hw:(\d+),(\d+)")


def have_arecord() -> bool:
    return shutil.which("arecord") is not None


def list_capture_devices():
    """Parse `arecord -l` into a list of {card, device, id, name}. Empty on any error."""
    try:
        out = subprocess.run(["arecord", "-l"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return []
    devices = []
    for line in out.splitlines():
        m = _CARD_RE.match(line.strip())
        if m:
            devices.append({
                "card": int(m.group(1)), "device": int(m.group(4)),
                "id": m.group(2), "name": m.group(3),
                "alsa": f"plughw:{m.group(1)},{m.group(4)}",
            })
    return devices


def resolve_device(configured: str) -> str:
    """Turn the configured device into a concrete ALSA name. "auto" prefers a USB capture device,
    then the first capture device, then a conventional default."""
    if configured and configured.lower() != "auto":
        return configured
    devices = list_capture_devices()
    usb = [d for d in devices if "usb" in (d["name"] + " " + d["id"]).lower()]
    pick = usb or devices
    return pick[0]["alsa"] if pick else "plughw:1,0"


def device_present(device: str) -> bool:
    """True if the (resolved) device's card,device appears in `arecord -l`. Non-intrusive — it does
    NOT open the device (so it won't fight an active stream)."""
    m = _HW_RE.search(device)
    if not m:
        return False
    card, dev = int(m.group(1)), int(m.group(2))
    return any(d["card"] == card and d["device"] == dev for d in list_capture_devices())


def arecord_command(device: str, rate: int, channels: int, fmt: str, wav: bool):
    """The streaming capture command — raw PCM (CommSight) or WAV (browser/ffplay verification)."""
    return ["arecord", "-D", device, "-f", fmt, "-r", str(rate), "-c", str(channels),
            "-t", "wav" if wav else "raw", "-q"]
