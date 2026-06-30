# Stratux setup → moved to `stratux-pi/`

The complete Raspberry Pi code for the Stratux cockpit-audio gateway now lives in the **top-level
[`stratux-pi/`](../../../stratux-pi/)** folder — an installable Python package plus `install.sh`, a
systemd service, device-detection helpers, and a full setup guide.

Quick path on the Pi:

```bash
git clone https://github.com/lawgorithims/ATC_Transcriptions.git
cd ATC_Transcriptions/stratux-pi && sudo ./install.sh
```

Then in CommSight: **Settings → Stratux receiver** (host `192.168.10.1`, audio port `8090`), pick
**“Stratux receiver”** as the input source, and press **Start**.
