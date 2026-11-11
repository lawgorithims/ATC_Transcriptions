# Nav cycle watchdog — deploying it on the EC2 box

## Why

On 2026-11-11 the live channel was serving cycle **2610**, which expired on 2026-10-29 — thirteen
days earlier. Cycle 2611 had been **built on 2026-10-20** and was sitting in `~/CommSight/navbuild/2611`
the entire time. Nothing failed, nothing was logged, nobody was told. `publish_nav.py`'s own header
records the same thing happening once before, when both databases sat on cycle 2607 for months.

A dropped cycle is silent by construction: the app falls back to its bundled floor, so a fresh
install looks perfect, and the only pilots affected are the ones who took an over-the-air update
and are now flying expired procedures.

## Install

```bash
sudo mkdir -p /opt/obelisk/nav /etc/obelisk
sudo rsync -a nav/cycle_watch.py nav/deploy/alert_on_stale.sh /opt/obelisk/nav/
sudo install -m 600 /dev/null /etc/obelisk/nav-watch.env     # then fill it in, see below
sudo cp nav/deploy/nav-cycle-watch.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nav-cycle-watch.timer
systemctl list-timers nav-cycle-watch.timer                  # confirm the next run
sudo systemctl start nav-cycle-watch.service                 # run it once now
journalctl -u nav-cycle-watch.service -n 40
```

`/etc/obelisk/nav-watch.env`, chmod 600 — ⚠️ **never in the repo, which is public**:

```
RESEND_API_KEY=...        # the same key the website uses for transactional mail
ALERT_TO=you@example.com
ALERT_FROM=alerts@obeliskaerospace.com
```

and add `EnvironmentFile=/etc/obelisk/nav-watch.env` to the `[Service]` section.

## What it does

Daily at 1000Z — after the 0901Z activation, so it sees the world as a pilot does on roll day.

| Exit | Meaning | Mail |
| --- | --- | --- |
| 0 | published cycle is current | only to close a previous alert |
| 1 | **EXPIRED** — pilots on OTA updates are stale now | yes |
| 2 | expiring within 14 days — time to build and stage | yes |
| 3 | could not check (network, malformed manifest) | **yes** |

⚠️ **Exit 3 alerts on purpose.** A watchdog that goes quiet when it cannot reach the network looks
exactly like one reporting all-clear.

⚠️ **It does not repeat itself daily.** A mail that says the same thing for three weeks becomes
furniture. The state file holds the last status; a repeat waits for the status to change or for
`ESCALATE_AFTER_DAYS` (7) to pass.

⚠️ **It needs no credentials to CHECK** — only to mail. It reads the public dataset over plain
HTTPS exactly as the app does, so the check itself cannot break because a token expired.

## What it does NOT do yet

It does not build or publish. Detecting the miss is the half that was absent; closing it is still:

```bash
python3 nav/publish_nav.py --publish    --from-dir <build dir>        # the in-force cycle, live
python3 nav/publish_nav.py --stage-next --from-dir <next-cycle dir>   # ahead of the date
```

Automating that end needs the FAA download, the `build_cifp.py` / `build_apt.py` pipeline and an
`HF_TOKEN` on the box — none of which lives there today; the packs are built on the Mac. The
watchdog already reports whether the FAA has posted the next cycle, which is the signal a build job
would wait on.

⚠️ **Never publish a cycle as live before its effective date.** `publish_nav.py` refuses it unless
`--stage-next` is given, and `RELEASING.md` §2 explains why: a future cycle served as current shows
no banner and no refusal, which is worse than stale data because nothing on screen says so.
