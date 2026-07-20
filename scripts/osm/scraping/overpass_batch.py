"""
overpass_batch.py
------------------
Logique de scraping Overpass PARTAGEE entre scrape_osm_pois.py et
scrape_osm_mobility.py : une requete par PROVINCE (~75, au lieu d'une par
COMMUNE, ~1500) puis reassignation locale (point-in-polygon, sans requete
Overpass supplementaire) de chaque element a sa commune.

Pourquoi par province plutot que par commune (cf. scripts/osm/README.md
pour le detail du diagnostic de performance) :

  - Overpass `area(...)` est indexe cote serveur -> rapide meme sur une
    grande zone. Le filtre `poly:"lat lon lat lon ..."` (utilise
    precedemment, 1 fois par commune) demande un test point-dans-polygone
    contre CHAQUE element candidat, cote serveur, pour CHAQUE requete -- le
    vrai cout, pas le nombre de requetes en tant que tel.
  - ~75 requetes (1/province) au lieu de ~1500 (1/commune) : le
    throttling volontaire (fair-use Overpass) devient negligeable.
  - Reponse JSON brute mise en cache par province (raw/overpass_cache/) :
    changer les categories ou corriger l'assignation commune ne necessite
    plus de re-interroger Overpass, seulement de rejouer le
    point-in-polygon sur le cache local.

Resolution province -> `area` OSM : essai par nom (+ repli sur quelques
admin_level, les provinces marocaines n'etant pas toutes taguees au meme
niveau cote OSM). Si aucune resolution ne matche, repli automatique sur un
filtre `poly:` construit a partir de l'union des polygones communaux de
cette province (deja disponibles localement, cf. admin_boundaries_communes.csv)
-- jamais de requete par commune, meme dans ce cas degrade.

Resolution commune HCP <-> polygone : PAR GEOMETRIE, jamais par nom.
Le fichier de limites administratives (admin_boundaries_communes.csv,
produit par scrape_admin_boundaries.py) ne porte aucune cle commune avec
geo_reference.csv (source HCP) -- ses noms sont ceux de la source
GADM/OSM d'origine, avec les memes ecarts orthographiques qui rendaient le
matching par nom peu fiable ("Chefchaouen" vs "Chefchaouene", tirets,
accents...). On utilise a la place le centroide de chaque commune HCP
(colonnes centroid_lat/centroid_lon de geo_reference.csv, deja calcule et
fiable) : le polygone qui CONTIENT ce centroide est le polygone de cette
commune. Deterministe, insensible a l'orthographe, un seul echec possible
(centroide hors de tout polygone -- journalise, jamais un choix au
hasard). Cf. match_communes_to_polygons().
"""

from __future__ import annotations

import csv
import json
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from shapely.geometry import MultiPolygon, Point, Polygon, shape
from shapely.ops import unary_union

# admin_boundaries_communes.csv porte des polygones GADM parfois tres
# detailles (colonne geojson_geom) : la limite par defaut du module csv
# (131072 caracteres/champ) est depassee, provoquant un crash immediat au
# chargement (_csv.Error: field larger than field limit) avant meme la
# 1ere requete Overpass -- verifie en direct sur ce jeu de donnees.
csv.field_size_limit(2**31 - 1)
from shapely.strtree import STRtree

from osm_overpass import query_overpass

# Verifie en direct (Overpass) : les provinces marocaines sont taguees
# admin_level=5 (ex: relation 1708828 "Province de Chefchaouen"), pas 4/6/7
# comme initialement suppose -- garde 4/6/7 en repli au cas ou une province
# particuliere serait taguee differemment.
ADMIN_LEVELS_TO_TRY = ("5", "4", "6", "7")


def load_geo_reference(ref_path: Path) -> tuple[list[dict], list[dict]]:
    """Charge provinces + communes depuis geo_reference.csv (source
    canonique partagee HCP/OSM/Google Maps). Sort tot avec un message
    explicite si le fichier n'existe pas (prerequis scrape_geo_reference.py)."""
    if not ref_path.exists():
        print(f"[ERROR] reference geo introuvable : {ref_path}", file=sys.stderr)
        print(
            "        -> lancer scripts/hcp/scraping/scrape_geo_reference.py d'abord "
            "(source canonique partagee par HCP/OSM/Google Maps).",
            file=sys.stderr,
        )
        sys.exit(1)
    with open(ref_path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    provinces = [r for r in rows if r.get("niveau") == "province"]
    communes = [r for r in rows if r.get("niveau") == "commune"]
    return provinces, communes


def load_communes_geometry(communes_boundaries_path: Path) -> list[dict]:
    """Charge les polygones de limites administratives communales depuis
    admin_boundaries_communes.csv (produit par scrape_admin_boundaries.py --
    colonnes osm_id, name, name_ar, admin_level, level_label, ref,
    geojson_geom ; la geometrie est stockee en JSON dans geojson_geom).

    Retourne une liste de polygones BRUTS, SANS cle de jointure vers les
    communes HCP (name/osm_id/ref ne sont pas des codes communes HCP -- ce
    sont des identifiants de la source d'origine des polygones). La
    jointure avec geo_reference.csv se fait par geometrie, cf.
    match_communes_to_polygons()."""
    if not communes_boundaries_path.exists():
        print(f"[ERROR] limites communales introuvables : {communes_boundaries_path}", file=sys.stderr)
        sys.exit(1)

    boundaries = []
    with open(communes_boundaries_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            geom_raw = row.get("geojson_geom")
            if not geom_raw:
                continue
            try:
                geometry = shape(json.loads(geom_raw))
            except (ValueError, json.JSONDecodeError):
                continue
            if geometry.is_empty:
                continue
            boundaries.append({
                "osm_id": row.get("osm_id"),
                "name": row.get("name"),
                "polygon": geometry,
            })
    return boundaries


# Au-dela de cette distance (degres, ~ lat/lon WGS84) entre le centroide
# HCP et le polygone le plus proche, on considere qu'il n'y a pas de match
# fiable (ce n'est plus un ecart d'imprecision de centroide/bord de
# polygone mais un vrai defaut de couverture -- commune absente du fichier
# de limites, par exemple) : mieux vaut journaliser l'echec que rattacher
# au hasard. ~0.05 degre ~= 5 km a la latitude du Maroc.
NEAREST_FALLBACK_MAX_DEGREES = 0.05


def match_communes_to_polygons(
    communes: list[dict], boundary_polygons: list[dict]
) -> tuple[dict[str, object], list[dict]]:
    """Associe a chaque commune HCP (geo_reference.csv) son polygone, PAR
    GEOMETRIE : le polygone qui contient le centroide HCP
    (centroid_lat/centroid_lon) est celui de cette commune. Aucun nom
    n'intervient dans ce matching -- insensible aux variantes
    orthographiques/accents qui rendaient le matching par nom peu fiable.

    Repli : si aucun polygone ne contient exactement le centroide (bord
    imprecis), on prend le polygone le plus proche s'il est a moins de
    NEAREST_FALLBACK_MAX_DEGREES, sinon aucun match (journalise, jamais un
    choix au hasard).

    Retourne (code_commune -> polygone, liste des communes non matchees
    pour investigation)."""
    polys = [b["polygon"] for b in boundary_polygons]
    matched: dict[str, object] = {}
    unmatched: list[dict] = []

    if not polys:
        return matched, list(communes)

    tree = STRtree(polys)

    for commune in communes:
        try:
            lat = float(commune["centroid_lat"])
            lon = float(commune["centroid_lon"])
        except (TypeError, ValueError, KeyError):
            unmatched.append(commune)
            continue

        point = Point(lon, lat)

        # STRtree.query filtre d'abord par boite englobante (rapide) ;
        # le containment exact est verifie ensuite, seulement sur les
        # quelques candidats retournes.
        candidate_indices = tree.query(point)
        polygon = None
        for idx in candidate_indices:
            candidate = polys[int(idx)]
            if candidate.contains(point):
                polygon = candidate
                break

        if polygon is None:
            nearest_idx = tree.nearest(point)
            if nearest_idx is not None:
                nearest_poly = polys[int(nearest_idx)]
                if point.distance(nearest_poly) <= NEAREST_FALLBACK_MAX_DEGREES:
                    polygon = nearest_poly

        if polygon is None:
            unmatched.append(commune)
            continue

        matched[commune["code_commune"]] = polygon

    return matched, unmatched


def build_province_polygons(
    provinces: list[dict], communes: list[dict], boundary_polygons: list[dict]
) -> tuple[dict[str, object], dict[str, list[dict]]]:
    """Calcule le polygone de repli de chaque province par UNION de ses
    communes membres (pas un fichier province.geojson separe, potentiellement
    desaligne sur un decoupage administratif different -- verifie en direct :
    admin_boundaries_provinces.geojson est sur l'ancien decoupage a 16
    regions/54 provinces, alors que geo_reference.csv (source canonique) est
    sur le decoupage 2015 a 12 regions/75 provinces. Unioner les communes
    (deja sur le decoupage canonique) evite ce desalignement entierement).

    La resolution commune -> polygone se fait par geometrie (centroide HCP
    contenu dans le polygone, cf. match_communes_to_polygons), jamais par
    nom.

    Retourne (province_code -> polygone union, province_code -> communes
    membres avec leur polygone individuel deja resolu)."""
    matched, unmatched = match_communes_to_polygons(communes, boundary_polygons)

    if unmatched:
        print(
            f"[WARN] {len(unmatched)}/{len(communes)} commune(s) HCP sans polygone "
            f"(centroide hors de tout polygone connu, meme en repli le plus proche) : "
            + ", ".join(c["code_commune"] for c in unmatched[:20])
            + (" ..." if len(unmatched) > 20 else ""),
            file=sys.stderr,
        )

    communes_by_province: dict[str, list[dict]] = {}
    for commune in communes:
        code_province = commune["code_province"]
        polygon = matched.get(commune["code_commune"])
        communes_by_province.setdefault(code_province, []).append(
            {**commune, "polygon": polygon}
        )

    province_polygons: dict[str, object] = {}
    for province in provinces:
        code = province["code_province"]
        members = communes_by_province.get(code, [])
        polys = [m["polygon"] for m in members if m["polygon"] is not None]
        if polys:
            province_polygons[code] = unary_union(polys)

    return province_polygons, communes_by_province


def get_polygon_coords(polygon, simplify_tolerance: float = 0.001) -> list[str]:
    """Extrait les coordonnees d'un polygone en les simplifiant (repli poly:)."""
    polygon = polygon.simplify(simplify_tolerance, preserve_topology=True)
    if isinstance(polygon, MultiPolygon):
        polygon = max(polygon.geoms, key=lambda p: p.area)
    coords = []
    for lon, lat in polygon.exterior.coords:
        coords.append(f"{lat:.6f} {lon:.6f}")
    return coords


def _category_filters(
    categories: dict, area_clause: str, element_types: tuple[str, ...] = ("node", "way", "relation")
) -> list[str]:
    """categories : {key: "*"} (toutes valeurs), {key: "value"} (valeur
    unique), ou {key: [v1, v2, ...]} (alternance -- ex: mobilite,
    highway: [motorway, trunk, primary])."""
    filters = []
    for key, value in categories.items():
        if value == "*":
            tag = f'["{key}"]'
        elif isinstance(value, list):
            alternation = "|".join(value)
            tag = f'["{key}"~"^({alternation})$"]'
        else:
            tag = f'["{key}"="{value}"]'
        for element_type in element_types:
            filters.append(f"{element_type}{tag}{area_clause};")
    return filters


# Overpass identifie une "area" derivee d'une relation par un ID decale de
# 3 600 000 000 (convention documentee Overpass QL) -- sans ce decalage,
# area(<id_relation>) resout une zone vide (0 element trouve, verifie en
# direct) au lieu de la vraie zone administrative.
OSM_RELATION_TO_AREA_OFFSET = 3_600_000_000


def build_area_query(
    relation_id: int, categories: dict, timeout: int,
    element_types: tuple[str, ...] = ("node", "way", "relation"),
    out_clause: str = "out center tags;",
) -> str:
    area_id = relation_id + OSM_RELATION_TO_AREA_OFFSET
    filters = _category_filters(categories, "(area.searchArea)", element_types)
    return f"""
[out:json][timeout:{timeout}];
area({area_id})->.searchArea;
(
  {" ".join(filters)}
);
{out_clause}
"""


def build_poly_query(
    polygon, categories: dict, timeout: int,
    element_types: tuple[str, ...] = ("node", "way", "relation"),
    out_clause: str = "out center tags;",
) -> str:
    coords = get_polygon_coords(polygon)
    poly = " ".join(coords)
    filters = _category_filters(categories, f'(poly:"{poly}")', element_types)
    return f"""
[out:json][timeout:{timeout}];
(
  {" ".join(filters)}
);
{out_clause}
"""


def hcp_ref_tag(code_province: str) -> str | None:
    """"MA-01-151" -> "01.151." : format du tag `ref:MA:HCP` porte par les
    relations administratives marocaines dans OSM (verifie en direct,
    Overpass : relation 1708828 "Province de Chefchaouen" porte
    ref:MA:HCP="01.151." pour code_province="MA-01-151"). Bien plus fiable
    qu'un matching par nom (accents/variantes/homonymie ville-province) --
    utilise en 1er, le nom en repli si le tag est absent."""
    parts = code_province.split("-")
    if len(parts) != 3:
        return None
    return f"{parts[1]}.{parts[2]}."


def resolve_province_area_id(province: dict, endpoints: list[str], http_cfg: dict) -> int | None:
    """Cherche l'ID de la relation administrative OSM correspondant a une
    province. Deux strategies, dans l'ordre :

    1. Tag `ref:MA:HCP` (cf. hcp_ref_tag) : correspondance exacte,
       deterministe, pas d'ambiguite possible.
    2. Repli par prefixe de nom, en essayant plusieurs admin_level (les
       provinces marocaines ne sont pas toutes taguees au meme niveau cote
       OSM) -- exclut les relations portant un tag `place` (villes/
       villages) : une commune-chef-lieu porte souvent le meme nom que sa
       province et le meme admin_level, mais N'EST PAS la province (verifie
       en direct : sans ce filtre, "Chefchaouen" resolvait vers la ville de
       ~481 POI au lieu de la province de ~89 communes).

    Retourne None si aucune des deux strategies ne trouve un match unique
    (jamais un choix ambigu au hasard -- repli sur `poly:` dans ce cas)."""
    ref = hcp_ref_tag(province["code_province"])
    if ref:
        query = f"""
[out:json][timeout:60];
relation["ref:MA:HCP"="{ref}"];
out ids tags 5;
"""
        try:
            result = query_overpass(query, endpoints, http_cfg)
            elements = result.get("elements", [])
            if len(elements) == 1:
                return elements[0]["id"]
        except RuntimeError:
            pass

    province_name = province["nom_province"]
    for admin_level in ADMIN_LEVELS_TO_TRY:
        query = f"""
[out:json][timeout:60];
relation["boundary"="administrative"]["admin_level"="{admin_level}"]["name"~"^{province_name}", i][!"place"];
out ids tags 5;
"""
        try:
            result = query_overpass(query, endpoints, http_cfg)
        except RuntimeError:
            continue
        elements = result.get("elements", [])
        if len(elements) == 1:
            return elements[0]["id"]
    return None


def query_province(
    province: dict,
    categories: dict,
    endpoints: list[str],
    http_cfg: dict,
    province_polygons: dict,
    cache_dir: Path,
    force_refresh: bool = False,
    element_types: tuple[str, ...] = ("node", "way", "relation"),
    out_clause: str = "out center tags;",
) -> tuple[list[dict], str]:
    """Retourne (elements Overpass, methode utilisee : 'area:<id>' ou 'poly').
    Met en cache la reponse JSON brute (raw/overpass_cache/<code>.json) --
    un re-run sans force_refresh rejoue depuis le cache local, sans requete
    Overpass."""
    code = province["code_province"]
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_file = cache_dir / f"{code}.json"

    if cache_file.exists() and not force_refresh:
        cached = json.loads(cache_file.read_text(encoding="utf-8"))
        return cached["elements"], cached["method"]

    area_id = resolve_province_area_id(province, endpoints, http_cfg)
    if area_id is not None:
        query = build_area_query(area_id, categories, http_cfg["timeout_seconds"], element_types, out_clause)
        method = f"area:{area_id}"
    else:
        polygon = province_polygons.get(code)
        if polygon is None:
            return [], "no_polygon"
        query = build_poly_query(polygon, categories, http_cfg["timeout_seconds"], element_types, out_clause)
        method = "poly"

    result = query_overpass(query, endpoints, http_cfg)
    elements = result.get("elements", [])
    cache_file.write_text(
        json.dumps({"method": method, "elements": elements}, ensure_ascii=False),
        encoding="utf-8",
    )
    return elements, method


def run_batched_scrape(
    provinces: list[dict],
    categories: dict,
    cfg: dict,
    province_polygons: dict,
    cache_dir: Path,
    max_workers: int = 3,
    force_refresh: bool = False,
    on_result=None,
    element_types: tuple[str, ...] = ("node", "way", "relation"),
    out_clause: str = "out center tags;",
) -> dict[str, list[dict]]:
    """Lance les requetes par province en parallele (jusqu'a max_workers a
    la fois -- un par miroir Overpass, cf. cfg['overpass_endpoints']).
    on_result(province, elements, method, error) est appele au fur et a
    mesure (pour affichage de progression / ecriture incrementale)."""
    endpoints = cfg["overpass_endpoints"]
    http_cfg = cfg["http"]

    results: dict[str, list[dict]] = {}
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        # Fait tourner (round-robin) l'ordre des miroirs par requete : sans
        # ca, toutes les requetes concurrentes essaient endpoints[0] en
        # premier simultanement (effet "troupeau", verifie en direct :
        # rate-limit 429 immediat sur le 1er miroir des les 2 premieres
        # provinces), annulant l'interet d'avoir plusieurs miroirs.
        futures = {
            executor.submit(
                query_province, province, categories,
                endpoints[i % len(endpoints):] + endpoints[: i % len(endpoints)],
                http_cfg, province_polygons, cache_dir, force_refresh,
                element_types, out_clause,
            ): province
            for i, province in enumerate(provinces)
        }
        for future in as_completed(futures):
            province = futures[future]
            code = province["code_province"]
            try:
                elements, method = future.result()
                results[code] = elements
                if on_result:
                    on_result(province, elements, method, None)
            except Exception as exc:  # noqa: BLE001
                results[code] = []
                if on_result:
                    on_result(province, [], "error", exc)
                else:
                    print(f"[ERROR] {province['nom_province']} ({code}) : {exc}", file=sys.stderr)

    return results


def assign_to_commune(lat: float, lon: float, province_communes: list[dict]) -> str | None:
    """Point-in-polygon LOCAL (pas de requete Overpass) : quelle commune de
    cette province contient ce point ? None si aucune (bord de polygone
    imprecis, ou commune sans polygone connu -- journalise en amont plutot
    que rattache au hasard)."""

    point = Point(lon, lat)
    for commune in province_communes:
        polygon = commune.get("polygon")
        if polygon is not None and polygon.contains(point):
            return commune["code_commune"]
    return None