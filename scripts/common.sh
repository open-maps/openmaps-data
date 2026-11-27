# shellcheck shell=bash
# Shared by the build scripts. Sourced, not run.

user_agent="openmaps-data (https://github.com/open-maps/openmaps-data)"

# The file name of a Geofabrik extract once filtered to what routing needs.
extract_name() {
  local path=${1#*download.geofabrik.de/}
  path=${path%-latest.osm.pbf}
  echo "${path//\//_}.routing.osm.pbf"
}

# Geofabrik refuses connections for a while after heavy use, so retries back off from 1 s to 10 min for up to 30 min.
download() {
  curl -4 -fsSL --retry 20 --retry-max-time 1800 --retry-all-errors -A "$user_agent" -o "$2.part" "$1" &&
  mv "$2.part" "$2"
}
