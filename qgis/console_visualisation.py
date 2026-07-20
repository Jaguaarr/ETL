# -*- coding: utf-8 -*-
"""
console_visualisation.py
-------------------------
A coller/executer dans la console Python de QGIS (ou Plugins > Console
Python, ou charger via le bouton "script" de la console).

Construit un projet QGIS complet a partir de la base etl_maroc (PostGIS) :
limites administratives (regions/provinces/communes, y compris les 3
provinces sahariennes reintegrees), tableau de bord communal (POI OSM,
Google Maps, mobilite, indicateurs HCP) en choropleth, heatmaps de
densite de POI, couches de mobilite, et zones bancaires BKM rattachees
par nom aux communes/provinces.

Prerequis cote base (deja executes une fois depuis le pipeline ETL, pas
necessaire de les rejouer ici) :
    - scripts/osm/sql/{bronze,silver,gold}/*.sql (osm_pois corrige, patch
      "commune la plus proche" + fusion Sahara)
    - qgis_views.sql (vw_commune_dashboard, vw_province_boundary,
      vw_region_boundary, vw_bkm_zone_geom, vw_bkm_credit_depot_geom)

A REMPLIR avant execution : le mot de passe Postgres (PG_PASSWORD
ci-dessous) -- jamais commite en clair, cf. .env du projet.
"""

from qgis.core import (
    QgsProject, QgsVectorLayer, QgsDataSourceUri, QgsLayerTreeGroup,
    QgsGraduatedSymbolRenderer, QgsClassificationJenks, QgsStyle,
    QgsHeatmapRenderer, QgsCategorizedSymbolRenderer, QgsRendererCategory,
    QgsSymbol, QgsRendererRange, QgsRectangle, QgsMarkerSymbol,
    QgsSingleSymbolRenderer, QgsPalLayerSettings, QgsTextFormat,
    QgsVectorLayerSimpleLabeling,
)
from qgis.PyQt.QtGui import QColor, QFont
import random

# =============================================================================
# 1. CONNEXION -- adapter si necessaire (valeurs par defaut = .env du repo)
# =============================================================================
PG_HOST = "localhost"
PG_PORT = "5433"
PG_DB = "etl_maroc"
PG_USER = "postgres"
PG_PASSWORD = ""  # <-- REMPLIR (mot de passe local du .env, jamais versionne)

if not PG_PASSWORD:
    raise RuntimeError(
        "PG_PASSWORD est vide : remplir la variable en haut du script "
        "(valeur de PGPASSWORD dans le .env du projet) avant de relancer."
    )


def pg_uri(schema, table, geom_col, key_col="", sql=""):
    uri = QgsDataSourceUri()
    uri.setConnection(PG_HOST, PG_PORT, PG_DB, PG_USER, PG_PASSWORD)
    uri.setDataSource(schema, table, geom_col, sql, key_col)
    return uri.uri(False)


def add_layer(schema, table, geom_col, name, key_col="", sql=""):
    layer = QgsVectorLayer(pg_uri(schema, table, geom_col, key_col, sql), name, "postgres")
    if not layer.isValid():
        print(f"[ERREUR] couche invalide : {schema}.{table} ({name})")
        return None
    QgsProject.instance().addMapLayer(layer, False)
    return layer


project = QgsProject.instance()
root = project.layerTreeRoot()

def add_group(name):
    g = root.insertGroup(0, name)
    return g


# =============================================================================
# 2. LIMITES ADMINISTRATIVES (regions / provinces / communes -- Sahara inclus)
# =============================================================================
grp_admin = add_group("1. Limites administratives")

lyr_regions = add_layer("gold", "vw_region_boundary", "geom_boundary", "Regions (dissous depuis communes)", "code")
lyr_provinces = add_layer("gold", "vw_province_boundary", "geom_boundary", "Provinces (dissous depuis communes)", "code")
lyr_communes = add_layer("gold", "vw_commune_dashboard", "geom_boundary", "Communes (limites)", "commune_code")

for lyr, color, width in [
    (lyr_regions, "#1b1b1b", 0.9),
    (lyr_provinces, "#4d4d4d", 0.6),
    (lyr_communes, "#9c9c9c", 0.3),
]:
    if lyr is None:
        continue
    sym = QgsSymbol.defaultSymbol(lyr.geometryType())
    sym.symbolLayer(0).setStrokeColor(QColor(color))
    sym.symbolLayer(0).setStrokeWidth(width)
    sym.symbolLayer(0).setBrushStyle(0)  # no fill (Qt.NoBrush)
    lyr.setRenderer(QgsSingleSymbolRenderer(sym))
    grp_admin.insertLayer(0, lyr)
    root.findLayer(lyr.id()).setItemVisibilityChecked(True)

# Etiquettes des provinces -- orientation immediate a la lecture, sans
# necessiter d'un fond de carte externe (utile en presentation).
if lyr_provinces is not None:
    label_settings = QgsPalLayerSettings()
    label_settings.fieldName = "nom"
    text_format = QgsTextFormat()
    text_format.setFont(QFont("Arial", 8))
    text_format.setSize(8)
    text_format.setColor(QColor("#1b1b1b"))
    buf = text_format.buffer()
    buf.setEnabled(True)
    buf.setSize(0.8)
    buf.setColor(QColor("#ffffff"))
    text_format.setBuffer(buf)
    label_settings.setFormat(text_format)
    lyr_provinces.setLabeling(QgsVectorLayerSimpleLabeling(label_settings))
    lyr_provinces.setLabelsEnabled(True)

# Couche de transparence : quelles provinces ont deja ete scrapees (POI OSM)
# -- evite qu'une province "blanche" sur les choropleths POI soit prise
# pour un bug plutot qu'une couverture de collecte pas encore terminee.
lyr_coverage = add_layer("gold", "vw_province_boundary", "geom_boundary", "Couverture scraping POI (par province)", "code")
if lyr_coverage:
    sym_ok = QgsSymbol.defaultSymbol(lyr_coverage.geometryType())
    sym_ok.setColor(QColor(46, 204, 113, 90))
    sym_ko = QgsSymbol.defaultSymbol(lyr_coverage.geometryType())
    sym_ko.setColor(QColor(149, 165, 166, 90))
    renderer = QgsCategorizedSymbolRenderer("a_des_poi", [
        QgsRendererCategory(True, sym_ok, "Provinces scrapees (POI disponibles)"),
        QgsRendererCategory(False, sym_ko, "Provinces pas encore scrapees"),
    ])
    lyr_coverage.setRenderer(renderer)
    grp_admin.insertLayer(0, lyr_coverage)
    root.findLayer(lyr_coverage.id()).setItemVisibilityChecked(False)


# =============================================================================
# 3. TABLEAU DE BORD COMMUNAL -- choropleth multi-variables
# =============================================================================
grp_choro = add_group("2. Communes -- choropleths (densite / indicateurs)")

# Chaque entree = (nom affiche, champ, rampe de couleur QGIS, inverser)
CHOROPLETH_FIELDS = [
    ("Densite de POI OSM (POI / km2)", "poi_density_km2", "OrRd", False),
    ("Total POI OSM par commune", "poi_total", "YlOrRd", False),
    ("Lieux Google Maps par commune", "ggl_places_total", "PuBuGn", False),
    ("Elements de mobilite OSM par commune", "mobility_elements", "Blues", False),
    ("Part population < 15 ans (%)", "pct_moins_15ans", "Greens", False),
    ("Part population 60 ans et + (%)", "pct_60ans_plus", "Purples", False),
    ("Part niveau d'etudes superieur (%)", "pct_niveau_superieur", "BuGn", False),
    ("Distance moyenne route goudronnee (km)", "distance_route_goudronnee_km", "Reds", False),
]

for label, field, ramp_name, invert in CHOROPLETH_FIELDS:
    lyr = add_layer("gold", "vw_commune_dashboard", "geom_boundary", label, "commune_code")
    if lyr is None:
        continue
    style = QgsStyle.defaultStyle()
    ramp = style.colorRamp(ramp_name)
    if ramp is None:
        ramp = style.colorRamp("Spectral")
    renderer = QgsGraduatedSymbolRenderer.createRenderer(
        lyr, field, 6, QgsGraduatedSymbolRenderer.Jenks if hasattr(QgsGraduatedSymbolRenderer, "Jenks") else 0,
        QgsSymbol.defaultSymbol(lyr.geometryType()), ramp,
    )
    if renderer is not None:
        renderer.setClassificationMethod(QgsClassificationJenks())
        lyr.setRenderer(renderer)
    lyr.setOpacity(0.85)
    grp_choro.insertLayer(0, lyr)
    root.findLayer(lyr.id()).setItemVisibilityChecked(False)  # une seule visible a la fois par defaut

# La 1ere (densite POI) visible par defaut
if grp_choro.children():
    grp_choro.children()[-1].setItemVisibilityChecked(True)


# =============================================================================
# 4. POINTS D'INTERET (POI) -- couches filtrees par categorie + heatmap
# =============================================================================
grp_poi = add_group("3. Points d'interet (POI)")

lyr_poi_all = add_layer("silver", "osm_pois", "geom", "POI OSM -- tous (points)", "poi_id")
if lyr_poi_all:
    grp_poi.insertLayer(0, lyr_poi_all)
    root.findLayer(lyr_poi_all.id()).setItemVisibilityChecked(False)

# Sous-couches pre-filtrees par grande categorie (filtre SQL cote serveur,
# modifiable dans Proprietes > Source > Filtre de la couche dans QGIS).
# Les 8 categories couvrent 100% de silver.osm_pois (verifie en direct).
for cat in ["amenity", "shop", "tourism", "healthcare", "leisure", "office", "craft", "historic"]:
    lyr = add_layer("silver", "osm_pois", "geom", f"POI -- {cat}", "poi_id", sql=f"category_key = '{cat}'")
    if lyr:
        grp_poi.insertLayer(0, lyr)
        root.findLayer(lyr.id()).setItemVisibilityChecked(False)

# Heatmap POI OSM (densite de points, independant du decoupage commune)
lyr_heat_osm = add_layer("silver", "osm_pois", "geom", "Heatmap -- densite POI OSM", "poi_id")
if lyr_heat_osm:
    heat = QgsHeatmapRenderer()
    heat.setRadius(18)
    heat.setRadiusUnit(1)  # QgsUnitTypes.RenderMillimeters == 1 (mm, coherent quel que soit le zoom)
    heat.setColorRamp(QgsStyle.defaultStyle().colorRamp("Inferno"))
    lyr_heat_osm.setRenderer(heat)
    grp_poi.insertLayer(0, lyr_heat_osm)
    root.findLayer(lyr_heat_osm.id()).setItemVisibilityChecked(True)

# Lieux Google Maps (points) + heatmap
lyr_ggl = add_layer("silver", "gglmaps_places", "geom", "Google Maps -- lieux (points)", "place_row_id")
if lyr_ggl:
    grp_poi.insertLayer(0, lyr_ggl)
    root.findLayer(lyr_ggl.id()).setItemVisibilityChecked(False)

lyr_heat_ggl = add_layer("silver", "gglmaps_places", "geom", "Heatmap -- densite Google Maps", "place_row_id")
if lyr_heat_ggl:
    heat2 = QgsHeatmapRenderer()
    heat2.setRadius(18)
    heat2.setRadiusUnit(1)
    heat2.setColorRamp(QgsStyle.defaultStyle().colorRamp("Viridis"))
    lyr_heat_ggl.setRenderer(heat2)
    grp_poi.insertLayer(0, lyr_heat_ggl)
    root.findLayer(lyr_heat_ggl.id()).setItemVisibilityChecked(False)


# =============================================================================
# 5. MOBILITE (routes, rail, gares, ports, aeroports -- OSM)
# =============================================================================
grp_mob = add_group("4. Mobilite (OSM)")

lyr_mobility = add_layer("silver", "osm_mobility", "geom", "Mobilite -- tous elements", "mobility_id")
if lyr_mobility:
    categories = ["route", "voie_ferree", "gare", "ligne_tram", "station_tram", "port", "aeroport"]
    palette = QgsStyle.defaultStyle().colorRamp("Set1")
    cat_renderer_items = []
    for i, cat in enumerate(categories):
        sym = QgsSymbol.defaultSymbol(lyr_mobility.geometryType())
        color = palette.color(i / max(1, len(categories) - 1)) if palette else QColor(random.randint(0,255), random.randint(0,255), random.randint(0,255))
        sym.setColor(color)
        cat_renderer_items.append(QgsRendererCategory(cat, sym, cat))
    renderer = QgsCategorizedSymbolRenderer("element_category", cat_renderer_items)
    lyr_mobility.setRenderer(renderer)
    grp_mob.insertLayer(0, lyr_mobility)
    root.findLayer(lyr_mobility.id()).setItemVisibilityChecked(True)

# Sous-couche dediee reseau ferroviaire ONCF (filtre is_oncf)
lyr_oncf = add_layer("silver", "osm_mobility", "geom", "Mobilite -- reseau ONCF", "mobility_id", sql="is_oncf = true")
if lyr_oncf:
    sym = QgsSymbol.defaultSymbol(lyr_oncf.geometryType())
    sym.setColor(QColor("#c0392b"))
    lyr_oncf.setRenderer(QgsSingleSymbolRenderer(sym))
    grp_mob.insertLayer(0, lyr_oncf)
    root.findLayer(lyr_oncf.id()).setItemVisibilityChecked(False)


# =============================================================================
# 6. BANK AL-MAGHRIB (BKM) -- snapshot derniere periode, 1 ligne/zone
# =============================================================================
# NB : gold.vw_bkm_credit_depot_geom (multi-periode, plusieurs lignes par
# zone_id) a ete abandonnee comme source de couche QGIS -- le fournisseur
# postgres de QGIS exige une colonne cle UNIQUE par entite ; zone_id seul
# n'est pas unique sur cette vue (1 ligne/mois/zone), ce qui faisait
# disparaitre silencieusement la plupart des lignes a l'affichage. Les vues
# *_latest (derniere periode uniquement, cf. bkm_choropleth.sql) sont bien
# 1 ligne/zone -- cle unique garantie, tout s'affiche.
grp_bkm = add_group("5. Bank Al-Maghrib (BKM)")

# Choropleth PRINCIPALE : credits/depots par PROVINCE (rayon_action -> 20/20
# provinces rattachees, limites 100% couvertes via vw_province_boundary) --
# beaucoup plus lisible/convaincant qu'un nuage de points epars.
lyr_bkm_credits = add_layer("gold", "vw_bkm_province_latest", "geom_boundary", "BKM -- Credits bancaires par province (DH)", "code_province")
if lyr_bkm_credits:
    style = QgsStyle.defaultStyle()
    ramp = style.colorRamp("YlGnBu")
    renderer = QgsGraduatedSymbolRenderer.createRenderer(
        lyr_bkm_credits, "credits_montant", 5, 0, QgsSymbol.defaultSymbol(lyr_bkm_credits.geometryType()), ramp,
    )
    if renderer is not None:
        renderer.setClassificationMethod(QgsClassificationJenks())
        lyr_bkm_credits.setRenderer(renderer)
    lyr_bkm_credits.setOpacity(0.9)
    grp_bkm.insertLayer(0, lyr_bkm_credits)
    root.findLayer(lyr_bkm_credits.id()).setItemVisibilityChecked(True)
    print(f"[INFO] BKM credits/province : {lyr_bkm_credits.featureCount()} provinces "
          f"(periode la plus recente, cf. gold.vw_bkm_province_latest).")

lyr_bkm_depots = add_layer("gold", "vw_bkm_province_latest", "geom_boundary", "BKM -- Depots bancaires par province (DH)", "code_province")
if lyr_bkm_depots:
    ramp2 = QgsStyle.defaultStyle().colorRamp("PuBuGn")
    renderer2 = QgsGraduatedSymbolRenderer.createRenderer(
        lyr_bkm_depots, "depots_montant", 5, 0, QgsSymbol.defaultSymbol(lyr_bkm_depots.geometryType()), ramp2,
    )
    if renderer2 is not None:
        renderer2.setClassificationMethod(QgsClassificationJenks())
        lyr_bkm_depots.setRenderer(renderer2)
    lyr_bkm_depots.setOpacity(0.9)
    grp_bkm.insertLayer(0, lyr_bkm_depots)
    root.findLayer(lyr_bkm_depots.id()).setItemVisibilityChecked(False)

lyr_bkm_guichets = add_layer("gold", "vw_bkm_province_latest", "geom_boundary", "BKM -- Densite de guichets par province", "code_province")
if lyr_bkm_guichets:
    ramp3 = QgsStyle.defaultStyle().colorRamp("OrRd")
    renderer3 = QgsGraduatedSymbolRenderer.createRenderer(
        lyr_bkm_guichets, "nombre_guichets", 5, 0, QgsSymbol.defaultSymbol(lyr_bkm_guichets.geometryType()), ramp3,
    )
    if renderer3 is not None:
        renderer3.setClassificationMethod(QgsClassificationJenks())
        lyr_bkm_guichets.setRenderer(renderer3)
    lyr_bkm_guichets.setOpacity(0.9)
    grp_bkm.insertLayer(0, lyr_bkm_guichets)
    root.findLayer(lyr_bkm_guichets.id()).setItemVisibilityChecked(False)

# Couche secondaire : credits/depots par LOCALITE (commune) -- points, pour
# le detail infra-provincial la ou le rattachement par nom a reussi.
lyr_bkm_localite = add_layer("gold", "vw_bkm_localite_latest", "geom", "BKM -- Credits par localite (points)", "zone_id")
if lyr_bkm_localite:
    ramp4 = QgsStyle.defaultStyle().colorRamp("YlOrRd")
    renderer4 = QgsGraduatedSymbolRenderer.createRenderer(
        lyr_bkm_localite, "credits_montant", 5, 0, QgsMarkerSymbol.createSimple({"size": "2.5"}), ramp4,
    )
    if renderer4 is not None:
        renderer4.setClassificationMethod(QgsClassificationJenks())
        lyr_bkm_localite.setRenderer(renderer4)
    grp_bkm.insertLayer(0, lyr_bkm_localite)
    root.findLayer(lyr_bkm_localite.id()).setItemVisibilityChecked(False)
    print(f"[INFO] BKM credits/localite : {lyr_bkm_localite.featureCount()} localites "
          f"(sur 227 publiees par BAM -- le reste n'a pas de commune correspondante "
          f"par nom, cf. gold.vw_bkm_zone_geom).")


# =============================================================================
# 7. FINALISATION
# =============================================================================
canvas_extent = QgsRectangle(-17.2, 20.5, -0.9, 36.0)  # emprise Maroc + Sahara
try:
    from qgis.utils import iface
    iface.mapCanvas().setExtent(canvas_extent)
    iface.mapCanvas().refresh()
except Exception:
    pass

print("=" * 70)
print("Projet QGIS construit :")
print(f"  - {len(list(grp_admin.children()))} couche(s) limites administratives")
print(f"  - {len(list(grp_choro.children()))} choropleth(s) communaux (activer/desactiver a volonte)")
print(f"  - {len(list(grp_poi.children()))} couche(s) POI (dont 2 heatmaps)")
print(f"  - {len(list(grp_mob.children()))} couche(s) mobilite")
print(f"  - {len(list(grp_bkm.children()))} couche(s) BKM")
print("Astuce filtres : clic droit sur une couche > Filtrer... (QueryBuilder) "
      "pour affiner par categorie/periode/commune ; les sous-couches POI/mobilite "
      "sont deja pre-filtrees via 'sql=' (visible/modifiable dans Proprietes > Source).")
print("=" * 70)