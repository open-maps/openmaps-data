"""Writes the manifests, publishes this week's releases and deletes the ones nothing points to any more."""

import argparse
import json
import os
import subprocess
import tempfile
import urllib.request
from pathlib import Path

INDEX = "index.json"


def gh(*args):
    return subprocess.run(["gh", *args], check=True, text=True, capture_output=True).stdout


def download_url(tag, name):
    return f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/releases/download/{tag}/{name}"


def tag_of(url):
    return url.split("/")[-2]


def fetch_json(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def previous_week():
    """The last published index and its regions by continent, empty before the first run."""
    try:
        index = fetch_json(f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/releases/latest/download/{INDEX}")
    except OSError:
        return {}, {}
    regions = {}
    for continent, url in index["continents"].items():
        regions[continent] = {region["id"]: region for region in fetch_json(url)["regions"]}
    return index, regions


def fragments(tag, directory):
    """This week's per region descriptions uploaded by the build jobs."""
    subprocess.run(["gh", "release", "download", tag, "--pattern", "*.json", "--dir", str(directory)], check=False)
    found = {}
    for path in directory.glob("*.json"):
        region = json.loads(path.read_text())
        if "id" in region:
            found[region["id"]] = region
    return found


def upload(tag, name, content, *extra):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / name
        path.write_text(json.dumps(content))
        gh("release", "upload", tag, str(path), *map(str, extra), "--clobber")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("plan", type=Path)
    parser.add_argument("overview", type=Path)
    args = parser.parse_args()
    plan = json.loads((args.plan / "regions.json").read_text())
    date = plan["date"]
    previous_index, by_continent = previous_week()

    planned = {}
    for region in plan["regions"]:
        planned.setdefault(region["continent"], []).append(region["id"])

    manifest_urls = dict(previous_index.get("continents", {}))
    for continent, region_ids in sorted(planned.items()):
        tag = f"{continent}-{date}"
        regions = by_continent.setdefault(continent, {})
        with tempfile.TemporaryDirectory() as directory:
            built = fragments(tag, Path(directory))
        for region_id in region_ids:
            region = built.get(region_id)
            if region is not None:
                for kind in ("map", "routing"):
                    region[kind]["url"] = download_url(tag, region[kind]["name"])
                regions[region_id] = region
            elif region_id in regions:
                print(f"::warning::{region_id} failed, keeping its build from {regions[region_id]['osmDate']}")
            else:
                print(f"::warning::{region_id} failed and has no earlier build")
        name = f"manifest-{continent}.json"
        upload(
            tag,
            name,
            {"continent": continent, "date": date, "regions": sorted(regions.values(), key=lambda r: r["id"])},
        )
        gh("release", "edit", tag, "--draft=false", "--latest=false")
        manifest_urls[continent] = download_url(tag, name)

    world_tag = f"world-{date}"
    world = json.loads((args.overview / "world.json").read_text())
    world["map"]["url"] = download_url(world_tag, world["map"]["name"])
    index = {"date": date, "mapVersion": plan["mapVersion"], "overview": world["map"], "continents": manifest_urls}
    upload(world_tag, INDEX, index)
    gh("release", "edit", world_tag, "--draft=false", "--latest")

    referenced = {world_tag, *map(tag_of, manifest_urls.values())}
    for regions in by_continent.values():
        for region in regions.values():
            referenced.update(tag_of(region[kind]["url"]) for kind in ("map", "routing"))
    for tag in json.loads(gh("release", "list", "--limit", "1000", "--json", "tagName", "--jq", "[.[].tagName]")):
        if tag not in referenced:
            gh("release", "delete", tag, "--yes", "--cleanup-tag")


if __name__ == "__main__":
    main()
