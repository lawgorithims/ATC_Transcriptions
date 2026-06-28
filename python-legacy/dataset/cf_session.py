"""
Cloudflare-aware fetch for the LiveATC archive (secondary acquisition path).

``archive.php`` / ``archive.liveatc.net`` sit behind Cloudflare, so a plain urllib
GET gets a 403/JS-challenge. ``CloudflareSession`` drives a real Chromium via
Playwright to clear the managed challenge once (obtaining the ``cf_clearance``
cookie + matching User-Agent), then fetches the 30-min mp3 blocks through the
browser's request context so they carry the clearance.

This automates LEGITIMATE access to publicly listenable recordings for local
research/training — keep it polite (one warmed session, modest rate) and remember
the data is for local training only (LiveATC ToS; see README).

Install on the box:
    pip install playwright && playwright install chromium

Use as a drop-in fetcher for the archive downloader:
    with CloudflareSession() as cf:
        download_archive_range(..., fetch=cf.get)
"""

from __future__ import annotations

import time
from typing import Optional

_ARCHIVE_HOST = "https://www.liveatc.net/archive.php"


class CloudflareError(RuntimeError):
    """A Cloudflare-protected fetch failed. ``status`` carries the HTTP code if known."""

    def __init__(self, message: str, status: Optional[int] = None):
        super().__init__(message)
        self.status = status


class CloudflareSession:
    """A warmed Chromium context that can fetch Cloudflare-protected archive blocks."""

    def __init__(
        self,
        headless: bool = True,
        warmup_url: str = _ARCHIVE_HOST,
        challenge_wait_s: float = 12.0,
        executable_path: Optional[str] = None,
    ):
        self.headless = headless
        self.warmup_url = warmup_url
        self.challenge_wait_s = challenge_wait_s
        self.executable_path = executable_path
        self._pw = None
        self._browser = None
        self._context = None
        self._warmed = False

    def __enter__(self) -> "CloudflareSession":
        from playwright.sync_api import sync_playwright

        self._pw = sync_playwright().start()
        launch_kwargs = {"headless": self.headless}
        if self.executable_path:
            launch_kwargs["executable_path"] = self.executable_path
        self._browser = self._pw.chromium.launch(**launch_kwargs)
        self._context = self._browser.new_context(
            user_agent=(
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
            )
        )
        return self

    def __exit__(self, *exc) -> None:
        for closer in (self._context, self._browser):
            try:
                if closer:
                    closer.close()
            except Exception:
                pass
        if self._pw:
            try:
                self._pw.stop()
            except Exception:
                pass

    def warmup(self) -> None:
        """Visit the archive site and wait for Cloudflare's challenge to clear."""
        page = self._context.new_page()
        try:
            page.goto(self.warmup_url, wait_until="domcontentloaded", timeout=60000)
            # Give the managed challenge time to resolve; then confirm we have a
            # cf_clearance cookie (best-effort signal).
            deadline = time.time() + self.challenge_wait_s
            while time.time() < deadline:
                cookies = self._context.cookies()
                if any(c.get("name") == "cf_clearance" for c in cookies):
                    break
                page.wait_for_timeout(1000)
        finally:
            page.close()
        self._warmed = True

    def get(self, url: str, timeout: float = 60.0) -> bytes:
        """Fetch ``url`` bytes through the warmed browser context.

        Signature matches the archive downloader's ``fetch`` hook so it can be passed
        straight in. Raises :class:`CloudflareError` on a non-200 / challenge body.
        """
        if not self._warmed:
            self.warmup()
        resp = self._context.request.get(url, timeout=timeout * 1000)
        if resp.status != 200:
            if resp.status == 404:
                raise CloudflareError(f"HTTP 404 fetching {url}", status=404)
            # One re-warm + retry in case clearance expired mid-run.
            self.warmup()
            resp = self._context.request.get(url, timeout=timeout * 1000)
            if resp.status != 200:
                raise CloudflareError(f"HTTP {resp.status} fetching {url}", status=resp.status)
        body = resp.body()
        # A challenge interstitial is small HTML, not an mp3 — guard against it.
        ctype = (resp.headers or {}).get("content-type", "")
        if "html" in ctype.lower() and len(body) < 100_000:
            raise CloudflareError(f"Got HTML challenge instead of audio for {url}")
        return body
