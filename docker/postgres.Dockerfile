# Image Postgres combinant PostGIS (geometries) + pgvector (embeddings),
# aucune image officielle ne fournit les deux : on part de l'image pgvector
# (Debian) et on installe PostGIS par-dessus via les paquets apt.postgresql.org.
FROM pgvector/pgvector:pg16

RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-16-postgis-3 postgresql-16-postgis-3-scripts \
    && rm -rf /var/lib/apt/lists/*
