"""
Publish whisper-atc model weights to Hugging Face Hub.

Usage:
    huggingface-cli login          # once per machine
    python scripts/publish_model_hf.py

Requires write access to the target repo (default: SingularityUS/ATC-whisper-v1
under the SingularityUS org).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MODEL_PATH = ROOT / "models" / "whisper-atc" / "model.safetensors"
DEFAULT_HF_REPO = "SingularityUS/ATC-whisper-v1"
DEFAULT_HF_FILENAME = "model.safetensors"
EXPECTED_BYTES = 966_995_080
SIZE_TOLERANCE_BYTES = 1_048_576


def format_bytes(num: int) -> str:
    if num >= 1_048_576:
        return f"{num / 1_048_576:.1f} MB"
    return f"{num} B"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Upload whisper-atc model.safetensors to Hugging Face Hub."
    )
    parser.add_argument(
        "--repo",
        default=DEFAULT_HF_REPO,
        help=f"Hugging Face repo id (default: {DEFAULT_HF_REPO})",
    )
    parser.add_argument(
        "--path",
        default=str(DEFAULT_MODEL_PATH),
        help="Local path to model.safetensors",
    )
    parser.add_argument(
        "--filename",
        default=DEFAULT_HF_FILENAME,
        help=f"Destination filename in the repo (default: {DEFAULT_HF_FILENAME})",
    )
    parser.add_argument(
        "--private",
        action="store_true",
        help="Create/update as a private model repo",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate local file only; do not upload",
    )
    args = parser.parse_args(argv)

    model_path = Path(args.path).expanduser().resolve()
    if not model_path.is_file():
        print(f"ERROR: Model file not found: {model_path}", file=sys.stderr)
        return 1

    size = model_path.stat().st_size
    if abs(size - EXPECTED_BYTES) > SIZE_TOLERANCE_BYTES:
        print(
            f"WARNING: Unexpected file size {format_bytes(size)} "
            f"(expected ~{format_bytes(EXPECTED_BYTES)})",
            file=sys.stderr,
        )

    repo_url = f"https://huggingface.co/{args.repo}"
    print(f"Repo:   {args.repo}")
    print(f"File:   {args.filename}")
    print(f"Model:  {model_path} ({format_bytes(size)})")
    print(f"URL:    {repo_url}")

    if args.dry_run:
        print("Dry run — no upload performed.")
        return 0

    try:
        from huggingface_hub import HfApi, create_repo
    except ImportError:
        print(
            "ERROR: huggingface_hub is not installed. Run: pip install huggingface_hub",
            file=sys.stderr,
        )
        return 1

    api = HfApi()
    try:
        who = api.whoami()
        print(f"Authenticated as: {who.get('name', who)}")
    except Exception as exc:
        print(
            "ERROR: Not authenticated with Hugging Face.\n"
            "  Run: huggingface-cli login\n"
            "  Or set HF_TOKEN with a write token from https://huggingface.co/settings/tokens",
            file=sys.stderr,
        )
        print(f"Details: {exc}", file=sys.stderr)
        return 1

    try:
        create_repo(
            repo_id=args.repo,
            repo_type="model",
            private=args.private,
            exist_ok=True,
        )
        print(f"Repository ready: {repo_url}")

        api.upload_file(
            path_or_fileobj=str(model_path),
            path_in_repo=args.filename,
            repo_id=args.repo,
            repo_type="model",
            commit_message=f"Upload {args.filename} ({format_bytes(size)})",
        )
    except Exception as exc:
        print(f"ERROR: Upload failed: {exc}", file=sys.stderr)
        return 1

    print("")
    print("Upload complete.")
    print(f"  {repo_url}/blob/main/{args.filename}")
    print(f"  https://huggingface.co/{args.repo}/resolve/main/{args.filename}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
