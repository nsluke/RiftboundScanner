#!/usr/bin/env python3 -I
"""Fetch the community Riftbound catalog and the reference image for every printing.

Downloads go into gitignored folders only:
  data/cards.json      the catalog snapshot (MIT, github.com/Dystorted888/riftbound-card-data)
  cache/images/<id>.png one reference image per printing, from Riot's CDN

Images are Riot Games property and are cached for personal prototyping only.
Everything downloaded is treated as untrusted data: nothing here is executed,
and each image is validated by its PNG/JPEG signature before being kept.

Usage:  python3 -I Scripts/fetch-images.py [--workers 4] [--limit N] [--force]
"""
import argparse
import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CATALOG_SOURCES = [
    "https://raw.githubusercontent.com/Dystorted888/riftbound-card-data/main/data/cards.json",
    "https://raw.githubusercontent.com/slimtreble/Riftbound-card-data/main/data/cards.json",
]
USER_AGENT = "RiftboundScanner/0.1 (personal prototype; contact: github.com/nsluke)"
ALLOWED_IMAGE_HOST = "cmsassets.rgpub.io"
SAFE_ID = re.compile(r"^[a-z0-9*\-]+$")


def http_get(url, timeout=60, attempts=4):
    last = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as err:
            last = err
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"failed after {attempts} attempts: {url}: {last}")


def fetch_catalog(path, force):
    if os.path.exists(path) and not force:
        print(f"catalog present: {path}")
        return
    for source in CATALOG_SOURCES:
        try:
            raw = http_get(source)
            parsed = json.loads(raw)
            if not isinstance(parsed.get("cards"), list):
                raise ValueError("catalog has no cards array")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(raw)
            print(f"catalog: {len(parsed['cards'])} cards from {source}")
            return
        except Exception as err:  # noqa: BLE001 - try the fallback source
            print(f"catalog source failed ({source}): {err}", file=sys.stderr)
    raise SystemExit("could not fetch the catalog from any source")


def looks_like_image(blob):
    return blob.startswith(b"\x89PNG\r\n\x1a\n") or blob.startswith(b"\xff\xd8\xff")


def fetch_image(card, images_dir, force):
    card_id = card["id"]
    url = card["image"]["url"]
    if not SAFE_ID.match(card_id):
        return card_id, "skipped: unexpected id"
    host = url.split("/")[2] if url.startswith("https://") else ""
    if host != ALLOWED_IMAGE_HOST:
        return card_id, f"skipped: unexpected host {host!r}"
    out = os.path.join(images_dir, card_id.replace("*", "_star") + ".png")
    if os.path.exists(out) and os.path.getsize(out) > 0 and not force:
        return card_id, "cached"
    blob = http_get(url)
    if not looks_like_image(blob):
        return card_id, "skipped: not an image"
    tmp = out + ".part"
    with open(tmp, "wb") as f:
        f.write(blob)
    os.replace(tmp, out)
    return card_id, f"ok {len(blob)} bytes"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0, help="only fetch the first N images")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    catalog_path = os.path.join(args.repo, "data", "cards.json")
    images_dir = os.path.join(args.repo, "cache", "images")
    os.makedirs(images_dir, exist_ok=True)
    fetch_catalog(catalog_path, args.force)

    with open(catalog_path, "rb") as f:
        cards = json.load(f)["cards"]
    if args.limit:
        cards = cards[: args.limit]

    counts = {}
    started = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(fetch_image, card, images_dir, args.force) for card in cards]
        for i, future in enumerate(concurrent.futures.as_completed(futures), 1):
            try:
                card_id, status = future.result()
            except Exception as err:  # noqa: BLE001 - report and continue
                card_id, status = "?", f"error {err}"
            key = status.split(" ")[0].rstrip(":")
            counts[key] = counts.get(key, 0) + 1
            if key not in ("ok", "cached") or i % 100 == 0:
                print(f"[{i}/{len(cards)}] {card_id}: {status}", flush=True)
    print(f"done in {time.time() - started:.0f}s: {counts}")


if __name__ == "__main__":
    main()
