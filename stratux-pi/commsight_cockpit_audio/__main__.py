"""Entry point: `python3 -m commsight_cockpit_audio`. Reads env config, allows CLI overrides."""
import argparse

from . import __version__, capture
from .config import Config, from_env
from .server import serve


def main():
    env = from_env()
    p = argparse.ArgumentParser(
        prog="commsight_cockpit_audio",
        description="CommSight cockpit-audio gateway (Stratux sidecar).")
    p.add_argument("--port", type=int, default=env.port)
    p.add_argument("--device", default=env.device, help='ALSA capture device, or "auto"')
    p.add_argument("--rate", type=int, default=env.rate)
    p.add_argument("--channels", type=int, default=env.channels)
    p.add_argument("--bind", default=env.bind_host)
    p.add_argument("--list-devices", action="store_true", help="print capture devices and exit")
    p.add_argument("--version", action="version", version="%(prog)s " + __version__)
    args = p.parse_args()

    if args.list_devices:
        devices = capture.list_capture_devices()
        if not devices:
            print("No capture devices (is the USB adapter plugged in? is alsa-utils installed?)")
        for d in devices:
            print("%-12s [%s] %s" % (d["alsa"], d["id"], d["name"]))
        print("\nauto would pick: %s" % capture.resolve_device("auto"))
        return

    serve(Config(bind_host=args.bind, port=args.port, device=args.device,
                 rate=args.rate, channels=args.channels, fmt=env.fmt))


if __name__ == "__main__":
    main()
