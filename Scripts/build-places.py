#!/usr/bin/env python3
"""Builds Resources/Places/places.deflate, the offline place-name index.

Fieldnote names a meeting's location (suburb or town, state, country) without a
network request by looking up the nearest place in this file. The source is
GeoNames (https://www.geonames.org, CC-BY 4.0): every populated place with 500+
people, plus the state and country tables.

GeoNames publishes daily dumps with no versioned URL, so the generated file is
committed rather than fetched at build time. Re-run this deliberately to refresh it:

    Scripts/build-places.py <dir with cities500.txt, admin1CodesASCII.txt, countryInfo.txt>

Download those three from https://download.geonames.org/export/dump/ (unzip
cities500.zip).

Format, before raw-deflate compression (zlib, no header, which is what Apple's
NSData.decompressed(using: .zlib) reads), UTF-8, tab-separated:

    R <tab> region name <tab> country name       one per state, in index order
    <lat> <tab> <lon> <tab> <name> <tab> <region index>   one per place

Coordinates are rounded to 3 decimal places (about 100 m), plenty to pick a town.
"""
import os
import sys
import zlib

src = sys.argv[1] if len(sys.argv) > 1 else "."
out = os.path.join(os.path.dirname(__file__), "..", "Resources", "Places", "places.deflate")

countries = {}
with open(os.path.join(src, "countryInfo.txt"), encoding="utf-8") as f:
    for line in f:
        if line.startswith("#"):
            continue
        cols = line.rstrip("\n").split("\t")
        countries[cols[0]] = cols[4]

admin1 = {}
with open(os.path.join(src, "admin1CodesASCII.txt"), encoding="utf-8") as f:
    for line in f:
        code, name, _, _ = line.rstrip("\n").split("\t")
        admin1[code] = name

regions, region_index, places = [], {}, []
with open(os.path.join(src, "cities500.txt"), encoding="utf-8") as f:
    for line in f:
        cols = line.rstrip("\n").split("\t")
        name, lat, lon, cc, a1 = cols[1], float(cols[4]), float(cols[5]), cols[8], cols[10]
        key = (admin1.get(f"{cc}.{a1}", ""), countries.get(cc, cc))
        if key not in region_index:
            region_index[key] = len(regions)
            regions.append(key)
        places.append(f"{lat:.3f}\t{lon:.3f}\t{name}\t{region_index[key]}")

text = "".join(f"R\t{r}\t{c}\n" for r, c in regions) + "\n".join(places) + "\n"
raw = text.encode("utf-8")
compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
packed = compressor.compress(raw) + compressor.flush()
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "wb") as f:
    f.write(packed)
print(f"{len(places)} places, {len(regions)} regions: {len(raw) / 1e6:.1f} MB raw, {len(packed) / 1e6:.1f} MB packed -> {os.path.normpath(out)}")
