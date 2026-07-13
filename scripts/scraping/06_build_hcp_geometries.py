#!/usr/bin/env python3
"""Prepare une couche GeoJSON officielle de communes pour PostGIS/QGIS.

La source doit etre une FeatureCollection en WGS84 contenant un identifiant
communal HCP (``Code_Commune`` par defaut). Le script ne devine jamais une
jointure par nom : une geometrie sans code HCP est rejetee dans le rapport.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

import requests


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / "datasets" / "hcp" / "boundaries" / "communes_geometry.csv"


def normalise_code(value: object) -> str:
    """Accepte RR.PPP.CC.NN. ou sa forme compacte a huit chiffres."""
    value = str(value or "").strip()
    digits = re.sub(r"\D", "", value)
    if len(digits) == 8:
        return f"{digits[:2]}.{digits[2:5]}.{digits[5:7]}.{digits[7:]}"
    return value


def ring_to_wkt(ring: list) -> str:
    if len(ring) < 4:
        raise ValueError("anneau de polygone incomplet")
    points = []
    for position in ring:
        if not isinstance(position, list) or len(position) < 2:
            raise ValueError("coordonnée GeoJSON invalide")
        points.append(f"{float(position[0]):.12g} {float(position[1]):.12g}")
    return f"({', '.join(points)})"


def geometry_to_wkt(geometry: dict) -> str:
    kind, coordinates = geometry.get("type"), geometry.get("coordinates")
    if kind == "Polygon":
        polygons = [coordinates]
    elif kind == "MultiPolygon":
        polygons = coordinates
    else:
        raise ValueError(f"géométrie {kind!r} : Polygon ou MultiPolygon attendu")
    if not isinstance(polygons, list) or not polygons:
        raise ValueError("géométrie vide")
    parts = []
    for polygon in polygons:
        if not isinstance(polygon, list) or not polygon:
            raise ValueError("polygone vide")
        parts.append(f"({', '.join(ring_to_wkt(ring) for ring in polygon)})")
    return f"MULTIPOLYGON({', '.join(parts)})"


def read_source(source: str, timeout: int) -> tuple[bytes, str]:
    parsed = urlparse(source)
    if parsed.scheme in {"http", "https"}:
        response = requests.get(source, timeout=timeout, headers={"User-Agent": "ETL-HCP/1.0"})
        response.raise_for_status()
        return response.content, source
    path = Path(source)
    return path.read_bytes(), path.resolve().as_uri()


def main() -> int:
    parser = argparse.ArgumentParser(description="Convertit des limites communales GeoJSON en CSV WKT")
    parser.add_argument("--source", required=True, help="URL HTTPS ou chemin du GeoJSON officiel")
    parser.add_argument("--code-field", default="Code_Commune", help="attribut GeoJSON contenant le code HCP")
    parser.add_argument("--out", default=str(DEFAULT_OUTPUT), help="CSV WKT de sortie")
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()

    try:
        raw, provenance = read_source(args.source, args.timeout)
        payload = json.loads(raw.decode("utf-8-sig"))
        features = payload.get("features", [])
        if payload.get("type") != "FeatureCollection" or not isinstance(features, list):
            raise ValueError("FeatureCollection GeoJSON attendue")
    except (OSError, requests.RequestException, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"[ERROR] lecture de la couche : {exc}", file=sys.stderr)
        return 1

    output = Path(args.out)
    output.parent.mkdir(parents=True, exist_ok=True)
    report = output.with_name("geometry_rejects.csv")
    sha256 = hashlib.sha256(raw).hexdigest()
    seen, valid, rejected = set(), [], []
    for index, feature in enumerate(features):
        props = feature.get("properties") or {}
        code = normalise_code(props.get(args.code_field))
        try:
            if not re.fullmatch(r"\d{2}\.\d{3}\.\d{2}\.\d{2}\.", code):
                raise ValueError(f"code HCP invalide dans l'attribut {args.code_field!r}")
            if code in seen:
                raise ValueError("code HCP duplique")
            wkt = geometry_to_wkt(feature.get("geometry") or {})
            seen.add(code)
            valid.append({"code_commune": code, "geom_wkt": wkt, "source_url": provenance,
                          "source_sha256": sha256, "source_feature_id": feature.get("id", index)})
        except (TypeError, ValueError) as exc:
            rejected.append({"feature_index": index, "code_commune": code, "reason": str(exc)})

    if not valid:
        print("[ERROR] aucune géométrie exploitable ; aucun CSV produit", file=sys.stderr)
        return 1
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(valid[0]))
        writer.writeheader()
        writer.writerows(valid)
    with report.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["feature_index", "code_commune", "reason"])
        writer.writeheader()
        writer.writerows(rejected)
    print(f"[OK] {len(valid)} géométrie(s) -> {output}")
    print(f"[INFO] {len(rejected)} rejet(s) -> {report}; source={provenance}; sha256={sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
