# TestFlight Disaster-Recovery Runbook

How to rebuild the ability to ship **CommSight** to TestFlight from scratch on a **fresh,
ephemeral Scaleway Apple-Silicon Mac**, in case the current build box (`macmini-m4`) is
deleted. This is the exact path that shipped **build 1 (2026-06-27)**.

> ⚠️ **This repo is PUBLIC.** No secrets or key identifiers are stored here. The actual
> values you need live in two private places — see the next section.

---

## 0. What you need that is NOT in this repo

| Thing | Where it lives | Notes |
|---|---|---|
| **`.p8` API private key** (`AuthKey_CDZ8T6TG53.p8`) | Your local machine: `C:\Users\bsusl\AuthKey_CDZ8T6TG53.p8` | The ONLY true secret. Apple will **not** re-issue it. If lost: revoke + create a new key in App Store Connect → Users and Access → Integrations (then update the IDs below). |
| **The 4 env IDs** (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`, `TEAM_ID`) | Claude memory note `ios-testflight-upload-config` (persists across sessions), and your own records | Not committed because the repo is public. App id, bundle id, SKU are also there. |
| **SSH key** for the Mac | `~/.ssh/id_ed25519` (Windows: `C:\Users\bsusl\.ssh\id_ed25519`) | Used for every Scaleway Mac (`User m1`). |

If you're doing this in a new Claude session, just ask Claude to read the
`ios-testflight-upload-config` memory note — it has the real values to paste into the env.

---

## TL;DR (once a box exists and the toolchain is installed)

```bash
# from the repo's ios/ dir on the Mac, with the .p8 already copied over:
ASC_KEY_ID=<from memory note> \
ASC_ISSUER_ID=<from memory note> \
ASC_KEY_PATH=/Users/m1/AuthKey_CDZ8T6TG53.p8 \
TEAM_ID=<from memory note> \
BUILD_NUMBER=<next unused integer> \
bash Tools/ship_testflight.sh
```

`Tools/ship_testflight.sh` is the **headless-correct** ship script (archive unsigned → sign
for App Store distribution at export). **Do not** use `Tools/testflight.sh` over SSH — its
signed archive defaults to Development signing and fails on a headless box (see §5).

---

## 1. Provision a fresh Scaleway Mac + SSH

Reference: Claude memory `apple-silicon-instance` (full gotchas). Summary:

1. Create the Mac in the Scaleway console. **No SSH key is injected at creation** — first
   connect with the password Scaleway shows. `sshpass`/`plink` aren't on the Windows box, so
   push the key with Python `paramiko`: append `~/.ssh/id_ed25519.pub` to the Mac's
   `~/.ssh/authorized_keys`. Then key auth works.
2. Add/replace the host in `~/.ssh/config` (`User m1`, `IdentityFile ~/.ssh/id_ed25519`,
   `IdentitiesOnly yes`). The IP changes per box — confirm the current one.

```
Host macmini-m4
    HostName <new-ip>
    User m1
    IdentityFile C:\Users\bsusl\.ssh\id_ed25519
    IdentitiesOnly yes
```

## 2. Bootstrap the toolchain

The Scaleway image ships **Xcode** (verify `xcodebuild -version`; build 1 used Xcode 26.3)
but **no Homebrew, no xcodegen**, and only system **Python 3.9.6**.

```bash
# Homebrew (needs sudo once for /opt/homebrew; grant a temp NOPASSWD sudoers entry so
# NONINTERACTIVE=1 brew doesn't stall, then REMOVE it after — public IP):
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
/opt/homebrew/bin/brew install xcodegen ffmpeg python@3.11
# xcodegen also vendored at ~/.xcodegen/xcodegen/bin/xcodegen — ship_testflight.sh finds either.
```

## 3. Clone the repo + restore iOS build inputs

```bash
git clone https://github.com/lawgorithims/ATC_Transcriptions.git ~/ATC_Transcribe
cd ~/ATC_Transcribe/ios
```

Build inputs the archive needs:

- **`Vendor/llama.xcframework`** (git-ignored, the embedded CPU-LLM framework). Rebuild it:
  `bash Tools/build_llama_xcframework.sh`. This is **required** — the app target embeds it.
- **Models** — for the normal **LEAN** TestFlight build you do **NOT** need them: the app
  downloads the Whisper CoreML model + GGUF LLM on first launch from the public HuggingFace
  repos (`SingularityUS/atc-whisperkit` + Qwen). `ship_testflight.sh` (LEAN=1, default) moves
  `Resources/Models` aside before archiving anyway. Only for an **offline/bundled** build
  (`LEAN=0`) do you need to populate `Resources/Models/` — convert CoreML
  (`Tools/convert_to_coreml.md`) + fetch the GGUF (`Tools/fetch_llm_model.sh`), and confirm
  the HF repos are still published (`Tools/publish_models.md`).
- **App icon** is committed (`Assets.xcassets/AppIcon.appiconset/AppStore.png`) — nothing to do.

## 4. Copy the `.p8` key onto the box and lock it down

From the Windows machine:

```bash
scp "/c/Users/bsusl/AuthKey_CDZ8T6TG53.p8" macmini-m4:/Users/m1/AuthKey_CDZ8T6TG53.p8
ssh macmini-m4 'chmod 600 /Users/m1/AuthKey_CDZ8T6TG53.p8'
```

## 5. Ship

Run the TL;DR command (§ top). Bump `BUILD_NUMBER` to the next integer Apple hasn't seen.
The Apple-side prerequisites (App ID, App Store Connect app record, API key) already exist
and **do not** need recreating — only the build box does.

---

## Why `Tools/testflight.sh` fails over SSH (and `ship_testflight.sh` works)

`testflight.sh` does a *signed* archive that defaults to **Development** signing → two failures
on a headless box: (1) "team has no devices" (dev profiles need a registered device);
(2) "private key is not installed" (no signing identity in any keychain on a fresh box).
App Store **distribution** signing has neither limitation but is only applied at *export*.
`ship_testflight.sh` therefore archives **UNSIGNED** (`CODE_SIGNING_ALLOWED=NO`), then exports
with the distribution profile, which `-allowProvisioningUpdates` + the ASC key mint in the
cloud (no devices needed). It also spins up a throwaway keychain so the new signing key has
somewhere to land, and restores everything on exit.

### Troubleshooting
- **"private key is not installed"** at export → an orphaned **Development** cert is in the
  way. Revoke it in the portal (developer.apple.com → Certificates), then re-run. (The ASC
  API can revoke it too, but Claude's API DELETE is guardrail-blocked, so do it in the UI.)
- **Inspect certs/builds via the ASC API** (read-only): reuse the JWT in the "Verify the
  credentials" snippet below, just change the path — `GET /v1/certificates?limit=200` lists
  certs (each `id` + `certificateType`; `DELETE /v1/certificates/{id}` revokes), and
  `GET /v1/builds?filter[app]={appId}&sort=-uploadedDate` lists recent builds + their
  `processingState`.

---

## Verify the credentials authenticate (read-only, no upload)

```bash
python3 -m venv /tmp/ascval && /tmp/ascval/bin/pip -q install pyjwt cryptography
ASC_KEY_ID=<...> ASC_ISSUER_ID=<...> ASC_KEY_PATH=/Users/m1/AuthKey_CDZ8T6TG53.p8 \
/tmp/ascval/bin/python3 - <<'PY'
import os,time,json,urllib.request,jwt
k=open(os.environ['ASC_KEY_PATH']).read(); now=int(time.time())
tok=jwt.encode({'iss':os.environ['ASC_ISSUER_ID'],'iat':now,'exp':now+600,'aud':'appstoreconnect-v1'},
               k,algorithm='ES256',headers={'kid':os.environ['ASC_KEY_ID'],'typ':'JWT'})
req=urllib.request.Request('https://api.appstoreconnect.apple.com/v1/apps?fields[apps]=name,bundleId',
                           headers={'Authorization':'Bearer '+tok})
d=json.load(urllib.request.urlopen(req,timeout=30))
print('OK', [(a['attributes']['name'],a['attributes']['bundleId']) for a in d.get('data',[])])
PY
```
Expect: `OK [('CommSight', 'com.flycommsight.atctranscribe')]`.

---

## Post-upload: install on a device

App Store Connect → **CommSight** → **TestFlight** → wait for "Processing" to finish (~10–30
min) → **Internal Testing** → add yourself as a tester → install the **TestFlight** app on the
iPhone/iPad and accept the invite.

---

## Env reference (fill from the private sources in §0)

| Var | Value |
|---|---|
| `ASC_KEY_ID` | *(memory note `ios-testflight-upload-config`)* |
| `ASC_ISSUER_ID` | *(memory note)* |
| `ASC_KEY_PATH` | `/Users/m1/AuthKey_CDZ8T6TG53.p8` |
| `TEAM_ID` | *(memory note)* |
| App | **CommSight**, bundle `com.flycommsight.atctranscribe`, SKU `commsight-ios` |
