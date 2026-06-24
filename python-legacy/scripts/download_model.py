"""
Download fine-tuned Whisper-ATC model weights from Hugging Face Hub.

Idempotent: skips download when models/whisper-atc/model.safetensors exists
and matches the expected size (~922 MB).

Primary source: Hugging Face Hub (SingularityUS/ATC-whisper-v1 by default).
Fallback: MODEL_DOWNLOAD_URL or config.yaml model.download_url for a direct URL.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Project root is one level above scripts/
ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MODEL_PATH = ROOT / "models" / "whisper-atc" / "model.safetensors"
DEFAULT_HF_REPO = "SingularityUS/ATC-whisper-v1"
DEFAULT_HF_FILENAME = "model.safetensors"
EXPECTED_BYTES = 966_995_080  # ~922 MB
SIZE_TOLERANCE_BYTES = 1_048_576  # 1 MB


def _load_config() -> dict:
    config_path = ROOT / "config.yaml"
    if not config_path.is_file():
        return {}
    try:
        import yaml
    except ImportError:
        return {}
    try:
        with config_path.open(encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except OSError:
        return {}
    return data.get("model") or {}


def _config_model_dir() -> str | None:
    """Destination model dir from config.yaml's live_pipeline.model_path (if set)."""
    config_path = ROOT / "config.yaml"
    if not config_path.is_file():
        return None
    try:
        import yaml

        with config_path.open(encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except Exception:
        return None
    model_dir = (data.get("live_pipeline") or {}).get("model_path")
    return str(model_dir).strip() if model_dir else None


def resolve_hf_repo(cli_repo: str | None) -> str:
    if cli_repo:
        return cli_repo
    env_repo = os.environ.get("MODEL_HF_REPO", "").strip()
    if env_repo:
        return env_repo
    model_cfg = _load_config()
    hf_repo = model_cfg.get("hf_repo")
    if hf_repo:
        return str(hf_repo).strip()
    return DEFAULT_HF_REPO


def resolve_hf_filename(cli_filename: str | None) -> str:
    if cli_filename:
        return cli_filename
    env_filename = os.environ.get("MODEL_HF_FILENAME", "").strip()
    if env_filename:
        return env_filename
    model_cfg = _load_config()
    hf_filename = model_cfg.get("hf_filename")
    if hf_filename:
        return str(hf_filename).strip()
    return DEFAULT_HF_FILENAME


def resolve_download_url(cli_url: str | None) -> str | None:
    if cli_url:
        return cli_url
    env_url = os.environ.get("MODEL_DOWNLOAD_URL", "").strip()
    if env_url:
        return env_url
    model_cfg = _load_config()
    download_url = model_cfg.get("download_url")
    if download_url:
        return str(download_url).strip()
    return None


def resolve_expected_bytes() -> int:
    env_val = os.environ.get("MODEL_EXPECTED_BYTES", "").strip()
    if env_val:
        return int(env_val)
    cfg_bytes = _load_config().get("expected_bytes")
    if cfg_bytes:
        return int(cfg_bytes)
    return EXPECTED_BYTES


def resolve_model_path(cli_path: str | None) -> Path:
    if cli_path:
        return Path(cli_path).expanduser().resolve()
    env_path = os.environ.get("MODEL_DOWNLOAD_PATH", "").strip()
    if env_path:
        return Path(env_path).expanduser().resolve()
    # Fall back to <config live_pipeline.model_path>/<hf_filename> so one config
    # switch sends the right weights to the right model dir (small or turbo).
    cfg_dir = _config_model_dir()
    if cfg_dir:
        return (ROOT / cfg_dir / resolve_hf_filename(None)).expanduser().resolve()
    return DEFAULT_MODEL_PATH


def is_valid_model_file(path: Path, expected_bytes: int, tolerance: int) -> bool:
    if not path.is_file():
        return False
    size = path.stat().st_size
    return abs(size - expected_bytes) <= tolerance


def format_bytes(num: int) -> str:
    if num >= 1_073_741_824:
        return f"{num / 1_073_741_824:.2f} GB"
    if num >= 1_048_576:
        return f"{num / 1_048_576:.1f} MB"
    if num >= 1024:
        return f"{num / 1024:.1f} KB"
    return f"{num} B"


def _print_progress(downloaded: int, total: int, started: float) -> None:
    elapsed = max(time.time() - started, 0.001)
    rate = downloaded / elapsed
    if total > 0:
        pct = min(100.0, downloaded * 100.0 / total)
        bar_width = 30
        filled = int(bar_width * pct / 100.0)
        bar = "#" * filled + "-" * (bar_width - filled)
        msg = (
            f"\r  [{bar}] {pct:5.1f}%  "
            f"{format_bytes(downloaded)} / {format_bytes(total)}  "
            f"{format_bytes(int(rate))}/s"
        )
    else:
        msg = f"\r  {format_bytes(downloaded)} downloaded  {format_bytes(int(rate))}/s"
    sys.stdout.write(msg)
    sys.stdout.flush()


def download_file(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_suffix(dest.suffix + ".partial")

    req = urllib.request.Request(
        url,
        headers={"User-Agent": "ATC-Transcribe/1.0 (model downloader)"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            total = int(response.headers.get("Content-Length", 0) or 0)
            downloaded = 0
            chunk_size = 1024 * 256
            started = time.time()
            print(f"Downloading from:\n  {url}")
            print(f"Saving to:\n  {dest}")
            with partial.open("wb") as out:
                while True:
                    chunk = response.read(chunk_size)
                    if not chunk:
                        break
                    out.write(chunk)
                    downloaded += len(chunk)
                    _print_progress(downloaded, total, started)
            print()
    except urllib.error.HTTPError as exc:
        if partial.exists():
            partial.unlink()
        raise RuntimeError(f"HTTP {exc.code} while downloading model: {exc.reason}") from exc
    except urllib.error.URLError as exc:
        if partial.exists():
            partial.unlink()
        raise RuntimeError(f"Network error while downloading model: {exc.reason}") from exc

    partial.replace(dest)


def download_from_hf(repo_id: str, filename: str, dest: Path) -> None:
    try:
        from huggingface_hub import hf_hub_download
    except ImportError as exc:
        raise RuntimeError(
            "huggingface_hub is not installed. Run: pip install huggingface_hub"
        ) from exc

    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading from Hugging Face Hub:\n  {repo_id}/{filename}")
    print(f"Saving to:\n  {dest}")

    cached_path = hf_hub_download(
        repo_id=repo_id,
        filename=filename,
        local_dir=str(dest.parent),
        local_dir_use_symlinks=False,
    )
    cached = Path(cached_path)
    if cached.resolve() != dest.resolve():
        if dest.exists():
            dest.unlink()
        cached.replace(dest)


def _models_from_config() -> list[dict]:
    """Every model defined under config.yaml `model:` (small + turbo) to download."""
    cfg = _load_config()
    out = []
    for name in ("small", "turbo"):
        m = cfg.get(name)
        if isinstance(m, dict) and m.get("path") and m.get("hf_repo"):
            d = Path(m["path"])
            if not d.is_absolute():
                d = ROOT / d
            fname = str(m.get("hf_filename", DEFAULT_HF_FILENAME))
            eb = m.get("expected_bytes")
            out.append(
                {
                    "name": name,
                    "repo": str(m["hf_repo"]).strip(),
                    "filename": fname,
                    "path": d / fname,
                    "expected_bytes": int(eb) if eb else EXPECTED_BYTES,
                }
            )
    return out


def _process_one(model_path, expected_bytes, direct_url, hf_repo, hf_filename, args) -> int:
    """Download/verify a single model weight file. Returns 0 on success."""
    if is_valid_model_file(model_path, expected_bytes, SIZE_TOLERANCE_BYTES) and not args.force:
        print(f"Model OK: {model_path} ({format_bytes(model_path.stat().st_size)})")
        return 0

    if args.check_only:
        if model_path.is_file():
            size = model_path.stat().st_size
            print(
                f"Model missing or wrong size: {model_path} "
                f"(found {format_bytes(size)}, expected ~{format_bytes(expected_bytes)})"
            )
        else:
            print(f"Model not found: {model_path}")
        return 1

    if args.dry_run:
        if model_path.is_file():
            print(
                f"Would replace invalid model at {model_path} "
                f"({format_bytes(model_path.stat().st_size)})"
            )
        else:
            print(f"Would download model to {model_path}")
        if direct_url:
            print(f"Source: direct URL\n  {direct_url}")
        else:
            print(f"Source: Hugging Face Hub\n  {hf_repo}/{hf_filename}")
        print(f"Expected size: ~{format_bytes(expected_bytes)}")
        return 0

    try:
        if direct_url:
            download_file(direct_url, model_path)
        else:
            download_from_hf(hf_repo, hf_filename, model_path)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print(
            f"Manual fallback: download {hf_filename} and place it at {model_path}",
            file=sys.stderr,
        )
        print(
            f"Hugging Face: https://huggingface.co/{hf_repo}/blob/main/{hf_filename}",
            file=sys.stderr,
        )
        return 1

    if not is_valid_model_file(model_path, expected_bytes, SIZE_TOLERANCE_BYTES):
        size = model_path.stat().st_size if model_path.is_file() else 0
        print(
            f"ERROR: Downloaded file size mismatch "
            f"(got {format_bytes(size)}, expected ~{format_bytes(expected_bytes)})",
            file=sys.stderr,
        )
        return 1

    print(f"Model ready: {model_path} ({format_bytes(model_path.stat().st_size)})")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Download whisper-atc model weights from Hugging Face Hub."
    )
    parser.add_argument(
        "--url",
        help="Override with a direct download URL (skips Hugging Face Hub)",
    )
    parser.add_argument(
        "--repo",
        help=f"Hugging Face repo id (default: env MODEL_HF_REPO, config, or {DEFAULT_HF_REPO})",
    )
    parser.add_argument(
        "--filename",
        help=f"File name in the HF repo (default: {DEFAULT_HF_FILENAME})",
    )
    parser.add_argument(
        "--path",
        help="Override destination path (default: models/whisper-atc/model.safetensors)",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Only verify the model file exists with expected size; do not download",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would happen without downloading",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download even if an existing file matches the expected size",
    )
    args = parser.parse_args(argv)

    # Explicit single-model override (--repo / --path / --url) keeps legacy behavior.
    if args.repo or args.path or args.url:
        return _process_one(
            resolve_model_path(args.path),
            resolve_expected_bytes(),
            resolve_download_url(args.url),
            resolve_hf_repo(args.repo),
            resolve_hf_filename(args.filename),
            args,
        )

    # Default: ensure BOTH configured models (small + turbo) are present, so the
    # web server can switch between them with no new download.
    models = _models_from_config()
    if not models:
        return _process_one(
            resolve_model_path(None),
            resolve_expected_bytes(),
            resolve_download_url(None),
            resolve_hf_repo(None),
            resolve_hf_filename(None),
            args,
        )
    rc = 0
    for m in models:
        print(f"\n=== {m['name']} model ===")
        rc = _process_one(m["path"], m["expected_bytes"], None, m["repo"], m["filename"], args) or rc
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
