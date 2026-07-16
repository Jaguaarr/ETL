# prepare_osrm_data.ps1
# -----------------------
# Equivalent PowerShell de prepare_osrm_data.sh -- cf. ce fichier pour le
# detail. A lancer UNE FOIS avant : docker compose --profile osrm up -d osrm
#
# Usage : powershell -File scripts/osm/scraping/prepare_osrm_data.ps1

$ErrorActionPreference = "Stop"

$OsrmImage = "osrm/osrm-backend:v5.27.1"
$ExtractUrl = "https://download.geofabrik.de/africa/morocco-latest.osm.pbf"
$VolumeName = "etl-main_osrm_data"

Write-Output "[1/4] Verification du volume Docker '$VolumeName'..."
docker volume inspect $VolumeName *> $null
if ($LASTEXITCODE -ne 0) {
    docker volume create $VolumeName
}

Write-Output "[2/4] Telechargement de l'extrait OSM Maroc (~200 Mo, Geofabrik)..."
docker run --rm -v "${VolumeName}:/data" curlimages/curl:latest `
    -sSL -o /data/morocco-latest.osm.pbf $ExtractUrl

Write-Output "[3/4] Extraction (profil voiture) -- peut prendre plusieurs minutes..."
docker run --rm -v "${VolumeName}:/data" $OsrmImage `
    osrm-extract -p /opt/car.lua /data/morocco-latest.osm.pbf

Write-Output "[4/4] Partition + customisation (algorithme MLD)..."
docker run --rm -v "${VolumeName}:/data" $OsrmImage `
    osrm-partition /data/morocco-latest.osrm
docker run --rm -v "${VolumeName}:/data" $OsrmImage `
    osrm-customize /data/morocco-latest.osrm

Write-Output "OK -- lancer maintenant : docker compose --profile osrm up -d osrm"
