"""Runtime configuration, from environment variables with sane defaults.

The systemd unit loads these from /etc/default/cockpit-audio (see cockpit-audio.env). CommSight
expects 16 kHz mono signed-16-bit PCM, so the audio format defaults should not normally change.
"""
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    bind_host: str = "0.0.0.0"   # listen on all interfaces (the Stratux Wi-Fi)
    port: int = 8090             # CommSight reads /audio.raw from here
    device: str = "auto"         # "auto" → detect a USB capture device; or an ALSA name e.g. plughw:1,0
    rate: int = 16000            # CommSight's native pipeline rate
    channels: int = 1            # mono
    fmt: str = "S16_LE"          # signed 16-bit little-endian

    @property
    def frame_bytes(self) -> int:
        """Bytes per ~20 ms write — keeps streaming latency low."""
        return int(self.rate * 0.020 * self.channels * 2)


def _int(env: dict, key: str, default: int) -> int:
    try:
        return int(env.get(key, default))
    except (TypeError, ValueError):
        return default


def from_env(env=None) -> Config:
    env = os.environ if env is None else env
    return Config(
        bind_host=env.get("AUDIO_BIND", "0.0.0.0"),
        port=_int(env, "AUDIO_PORT", 8090),
        device=env.get("AUDIO_DEVICE", "auto") or "auto",
        rate=_int(env, "AUDIO_RATE", 16000),
        channels=_int(env, "AUDIO_CHANNELS", 1),
        fmt=env.get("AUDIO_FORMAT", "S16_LE"),
    )
