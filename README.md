# openmaps-data

Weekly offline map and routing data for [OpenMaps](https://github.com/SeineEloquenz/openmaps), built on GitHub Actions and published as releases.

Each region comes as two files:

- `REGION.pmtiles`, the map from zoom 8 to 14, cut from the weekly planet of [OpenFreeMap](https://openfreemap.org) in the OpenMapTiles schema.
- `REGION.valhalla.tar.zst`, a [Valhalla](https://github.com/valhalla/valhalla) routing graph for cars, bikes and walking. It reaches 25 km into neighbouring regions, so routes across borders work.

`world.pmtiles` holds the whole world up to zoom 7.

The app reads `index.json` from the latest release, which links one manifest per continent. Each manifest lists the regions with their outline, sizes, SHA-256 checksums and the date of their OpenStreetMap data.

## How a run works

1. `scripts/plan.py` chooses about 420 regions from the [Geofabrik](https://download.geofabrik.de) extracts. It splits extracts over 1.5 GB into their subregions and leaves out groupings such as "alps".
2. Fetch jobs download each Geofabrik extract once, keep what routing needs and store it in a temporary release.
3. Build jobs take batches of neighbouring regions. They build each routing graph from its region plus the margin, and cut its map from the planet.
4. `scripts/publish.py` writes the manifests and publishes the releases. A region that failed keeps its previous build. Releases nothing links to any more are deleted.

To build only some regions, start the workflow by hand with their Geofabrik ids, such as `luxembourg,baden-wuerttemberg`.

## Local runs

```sh
nix develop
python3 scripts/plan.py --out plan --only luxembourg
scripts/timezones.sh plan
```

## Licences

Map data © OpenStreetMap contributors, available under the [Open Database License](https://opendatacommons.org/licenses/odbl/). Map tiles follow the [OpenMapTiles](https://openmaptiles.org) schema, © OpenMapTiles. The scripts are under the GNU AGPL 3.0.
