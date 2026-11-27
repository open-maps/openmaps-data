"""Chooses the regions to build this week and writes plan/regions.json and the outlines each build cuts with."""

import argparse
import json
import math
import re
import socket
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

from shapely import make_valid
from shapely.affinity import scale
from shapely.geometry import mapping, shape
from shapely.ops import unary_union

INDEX = "https://download.geofabrik.de/index-v1.json"
PLANET_INDEX = "https://btrfs.openfreemap.com/files.txt"
PLANET_BASE = "https://btrfs.openfreemap.com/"
USER_AGENT = "openmaps-data (https://github.com/open-maps/openmaps-data)"

# Larger extracts are split into their Geofabrik subregions, keeping each build and file well within runner and release limits.
MAX_EXTRACT_BYTES = 1_500_000_000
# Routes stay possible this far into neighbouring regions.
ROUTING_MARGIN_KM = 25
# Map files overlap slightly so no tiles go missing along borders.
MAP_MARGIN_KM = 2
# A region made up of other chosen regions, such as "alps" or "us-west", is a grouping and is left out.
COVERED_SHARE = 0.9
GROUPING_MEMBERS = 2
GROUPING_SHARE = 0.5
# Batches stay small enough for one runner and its six hour limit.
BATCH_BYTES = 3_000_000_000
BATCH_REGIONS = 25
BAND_DEGREES = 5
SIZE_REQUESTS = 8
FETCH_BYTES = 4_000_000_000
KM_PER_DEGREE = 111.32


# GitHub's runners have no IPv6 route, and urllib does not fall back to IPv4 by itself.
_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, *args, **kwargs: _getaddrinfo(host, port, socket.AF_INET, *args, **kwargs)


def fetch(url, method="GET"):
    request = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(request, timeout=120)


def extract_size(url):
    with fetch(url, "HEAD") as response:
        return int(response.headers["Content-Length"])


def latest_planet():
    with fetch(PLANET_INDEX) as response:
        lines = response.read().decode().split()
    planets = sorted(line for line in lines if re.fullmatch(r"areas/planet/[^/]+/tiles\.pmtiles", line))
    path = planets[-1]
    return PLANET_BASE + path, path.split("/")[2]


def buffered(geometry, km):
    """The geometry grown by roughly [km] in every direction, measured on the ground rather than in degrees."""
    latitude = geometry.centroid.y
    squeeze = max(math.cos(math.radians(latitude)), 0.05)
    flat = scale(geometry, xfact=squeeze, yfact=1, origin=(0, 0))
    return scale(flat.buffer(km / KM_PER_DEGREE), xfact=1 / squeeze, yfact=1, origin=(0, 0))


def continent_of(region, regions):
    while regions[region]["parent"]:
        region = regions[region]["parent"]
    return region


def choose(regions, children, only):
    chosen = []

    def visit(region):
        kids = children.get(region, [])
        if kids and extract_size(regions[region]["pbf"]) > MAX_EXTRACT_BYTES:
            for kid in kids:
                visit(kid)
        else:
            chosen.append(region)

    for top in sorted(region for region, info in regions.items() if not info["parent"]):
        visit(top)

    kept = set(chosen)
    for region in sorted(chosen, key=lambda region: -regions[region]["shape"].area):
        outline = regions[region]["shape"]
        touching = [other for other in kept if other != region and regions[other]["shape"].intersects(outline)]
        if not touching:
            continue
        covered = outline.intersection(unary_union([regions[other]["shape"] for other in touching])).area
        inside = [
            other
            for other in touching
            if regions[other]["shape"].intersection(outline).area >= COVERED_SHARE * regions[other]["shape"].area
        ]
        if covered >= COVERED_SHARE * outline.area or (
            len(inside) >= GROUPING_MEMBERS and covered >= GROUPING_SHARE * outline.area
        ):
            kept.discard(region)
    kept = sorted(kept)
    if only:
        kept = [region for region in kept if region in only]
    return sorted(kept)


def sizes_of(urls):
    with ThreadPoolExecutor(max_workers=SIZE_REQUESTS) as pool:
        return dict(zip(urls, pool.map(extract_size, urls)))


def batched(entries, regions, sizes):
    """Groups neighbouring regions so each build job downloads the extracts they share once."""
    groups = {}
    for entry in entries:
        groups.setdefault((entry["continent"], regions[entry["id"]]["parent"] or ""), []).append(entry)
    batches = []
    for _, members in sorted(groups.items()):
        members.sort(
            key=lambda entry: (
                round(regions[entry["id"]]["shape"].centroid.y / BAND_DEGREES),
                regions[entry["id"]]["shape"].centroid.x,
            )
        )
        current, total = [], 0
        for entry in members:
            size = sizes[entry["extracts"][0]]
            if current and (total + size > BATCH_BYTES or len(current) >= BATCH_REGIONS):
                batches.append(current)
                current, total = [], 0
            current.append(entry)
            total += size
        if current:
            batches.append(current)
    return [
        {
            "id": f"{number:03d}",
            "regions": [entry["slug"] for entry in batch],
            "extracts": sorted({url for entry in batch for url in entry["extracts"]}),
        }
        for number, batch in enumerate(batches)
    ]


def fetch_groups(sizes):
    """Splits all extracts into download jobs of similar size, each extract downloaded once."""
    groups, current, total = [], [], 0
    for url in sorted(sizes, key=sizes.get, reverse=True):
        if current and total + sizes[url] > FETCH_BYTES:
            groups.append(current)
            current, total = [], 0
        current.append(url)
        total += sizes[url]
    if current:
        groups.append(current)
    return [{"id": f"{number:03d}", "extracts": group} for number, group in enumerate(groups)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("plan"))
    parser.add_argument("--only", default="", help="comma separated Geofabrik ids to build, all when empty")
    args = parser.parse_args()
    only = {region for region in args.only.split(",") if region}

    with fetch(INDEX) as response:
        index = json.load(response)
    regions = {}
    children = {}
    for feature in index["features"]:
        properties = feature["properties"]
        if "pbf" not in properties["urls"] or not feature.get("geometry"):
            continue
        region = properties["id"]
        regions[region] = {
            "name": properties["name"],
            "parent": properties.get("parent"),
            "pbf": properties["urls"]["pbf"],
            "shape": make_valid(shape(feature["geometry"])),
        }
    for region, info in regions.items():
        if info["parent"]:
            children.setdefault(info["parent"], []).append(region)

    selected = choose(regions, children, only)
    # Neighbours come from all regions chosen for the world, so a single region built alone still gets its margin.
    world = selected if not only else choose(regions, children, set())
    planet_url, map_version = latest_planet()

    outlines = args.out / "outlines"
    outlines.mkdir(parents=True, exist_ok=True)
    entries = []
    for region in selected:
        info = regions[region]
        slug = region.replace("/", "_")
        routing_area = buffered(info["shape"], ROUTING_MARGIN_KM)
        map_area = buffered(info["shape"], MAP_MARGIN_KM)
        neighbours = [other for other in world if other != region and regions[other]["shape"].intersects(routing_area)]
        for kind, geometry in (("routing", routing_area), ("map", map_area)):
            feature = {"type": "Feature", "properties": {}, "geometry": mapping(geometry)}
            (outlines / f"{slug}.{kind}.geojson").write_text(json.dumps(feature))
        west, south, east, north = info["shape"].bounds
        entries.append(
            {
                "id": region,
                "slug": slug,
                "name": info["name"],
                "continent": continent_of(region, regions),
                "bbox": [round(value, 4) for value in (west, south, east, north)],
                "outline": mapping(info["shape"].simplify(0.01, preserve_topology=True)),
                "extracts": [info["pbf"]] + [regions[other]["pbf"] for other in neighbours],
            }
        )

    sizes = sizes_of(sorted({url for entry in entries for url in entry["extracts"]}))
    batches = batched(entries, regions, sizes)
    fetches = fetch_groups(sizes)

    plan = {
        "date": date.today().isoformat(),
        "planet": planet_url,
        "mapVersion": map_version,
        "regions": entries,
        "batches": batches,
        "fetches": fetches,
    }
    (args.out / "regions.json").write_text(json.dumps(plan))
    print(f"{len(entries)} regions in {len(batches)} batches, map version {map_version}")
    print(f"{len(fetches)} fetch jobs for {sum(sizes.values()) / 1e9:.0f} GB of extracts")


if __name__ == "__main__":
    main()
