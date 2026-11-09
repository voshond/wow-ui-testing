"""Builds proof atlas tables for a pinned client build from wago.tools
UiTextureAtlas exports whose checksums live in clientdata/<flavor>.json.

The full table (about 17k atlases, 3.3 MB) is too large to commit, so every
table keeps only the atlas names some Lua source uses. The lib's own table,
clientdata/atlases/<flavor>-<build>.lua, covers wowmock and the spec fixtures;
hosts generate their subset with --scan and --output.

  python3 -B scripts/atlas_catalog.py --fetch --check   verify the lib's table against the pins
  python3 -B scripts/atlas_catalog.py --update          download the build's exports and repin their checksums
  python3 -B scripts/atlas_catalog.py --fetch --scan 'MyAddon/**/*.lua' --output tests/proof/atlases.lua
"""
import argparse
import csv
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from collections import defaultdict


ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".client-source/atlas-exports"
LIB_SCAN = ("wowmock/**/*.lua", "spec/fixtures/**/*.lua")
TABLES = {
    "UiTextureAtlas": {"ID", "FileDataID", "AtlasWidth", "AtlasHeight"},
    "UiTextureAtlasMember": {"ID", "CommittedName", "UiTextureAtlasID", "Width", "Height", "CommittedLeft", "CommittedRight", "CommittedTop", "CommittedBottom", "UiTextureAtlasElementID", "CommittedFlags"},
    "UiTextureAtlasElement": {"ID", "Name"},
}
TILES_VERTICALLY, TILES_HORIZONTALLY = 2, 4
LITERAL = re.compile(r"""(["'])([^"'\s\\]*-[^"'\s\\]*)\1""")
CONCATENATION = re.compile(r"""(["'])([^"'\s\\]+-)\1\s*\.\.\s*[\w.:\[\]()]+(?:\s*\.\.\s*(["'])([^"'\s\\]*)\3)?""")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def pin_path(flavor):
    return ROOT / f"clientdata/{flavor}.json"


def default_output(pin):
    return ROOT / f"clientdata/atlases/{pin['flavor']}-{pin['build']}.lua"


def pinned_source(flavor):
    pin = json.loads(pin_path(flavor).read_text())
    if pin.get("flavor") != flavor or not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", pin.get("build", "")):
        raise ValueError(f"{pin_path(flavor).name}: missing flavor or build")
    if not re.fullmatch(r"[0-9a-f]{40}", pin["wowUiSource"]["commit"]) or not re.fullmatch(r"[0-9a-f]{40}", pin["art"]["ref"]):
        raise ValueError(f"{pin_path(flavor).name}: wow-ui-source commit and art ref must be full SHAs")
    major, minor, patch, _ = map(int, pin["build"].split("."))
    if pin.get("interface") != major * 10000 + minor * 100 + patch:
        raise ValueError(f"{pin_path(flavor).name}: interface does not match the build")
    return pin


def validate_download(name, build, headers):
    responses = re.split(r"(?=HTTP/\S+ \d{3})", headers)
    final = responses[-1]
    expected = f"{name}.{build}.csv"
    disposition = re.search(r"^content-disposition:\s*(.+)$", final, re.I | re.M)
    if not disposition or f'filename="{expected}"' not in disposition[1]:
        raise ValueError(f"{name}: server did not confirm the requested build {build}")


def table_url(name, build):
    return f"https://wago.tools/db2/{name}/csv?build={build}&locale=enUS"


def parse_table(name, raw):
    reader = csv.DictReader(io.StringIO(raw.decode("utf-8-sig")))
    missing = TABLES[name] - set(reader.fieldnames or [])
    if missing:
        raise ValueError(f"{name}: missing columns {sorted(missing)}")
    rows = list(reader)
    ids = [int(row["ID"]) for row in rows]
    if not rows or len(ids) != len(set(ids)):
        raise ValueError(f"{name}: empty table or duplicate IDs")
    return rows


def download(pin):
    tables, records, compressed = {}, {}, {}
    for name in TABLES:
        url = table_url(name, pin["build"])
        with tempfile.TemporaryDirectory() as directory:
            headers = Path(directory) / "headers"
            raw = subprocess.check_output(["curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "90", "--dump-header", str(headers), url])
            validate_download(name, pin["build"], headers.read_text())
        tables[name] = parse_table(name, raw)
        compressed[name] = gzip.compress(raw, mtime=0)
        records[name] = {"url": url, "filename": f"{name}.{pin['build']}.csv", "sha256": digest(raw), "rows": len(tables[name])}
        print(f"Fetched {name}: {len(tables[name])} records", file=sys.stderr)
    return tables, {"format": 1, "tables": records}, compressed


def read_manifest(pin):
    manifest = pin.get("atlasExports") or {}
    if manifest.get("format") != 1 or set(manifest.get("tables", {})) != set(TABLES):
        raise ValueError("atlas export pins are missing or outdated; run --update")
    for name in TABLES:
        record = manifest["tables"][name]
        if record["url"] != table_url(name, pin["build"]) or record.get("filename") != f"{name}.{pin['build']}.csv":
            raise ValueError(f"{name}: source does not match the pinned build")
        if not re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) or record["rows"] <= 0:
            raise ValueError(f"{name}: invalid checksum or row count")
    return manifest


def read_cache(pin, cache):
    manifest = read_manifest(pin)
    tables = {}
    for name in TABLES:
        record = manifest["tables"][name]
        raw = gzip.decompress((cache / pin["build"] / f"{name}.csv.gz").read_bytes())
        if digest(raw) != record["sha256"]:
            raise ValueError(f"{name}: checksum mismatch")
        tables[name] = parse_table(name, raw)
        if len(tables[name]) != record["rows"]:
            raise ValueError(f"{name}: row count mismatch")
    return tables


def write_cache(pin, cache, compressed):
    directory = cache / pin["build"]
    directory.mkdir(parents=True, exist_ok=True)
    for name, content in compressed.items():
        (directory / f"{name}.csv.gz").write_bytes(content)


def source_files(patterns, root):
    files = set()
    for pattern in patterns:
        files.update(path for path in root.glob(pattern) if path.is_file())
    if not files:
        raise ValueError(f"--scan matched no files: {' '.join(patterns)}")
    return sorted(files)


def atlas_uses(patterns, root):
    literals, concatenations = set(), set()
    for path in source_files(patterns, root):
        text = path.read_text(encoding="utf-8")
        if not re.search("atlas", text, re.I):
            continue
        literals.update(match[2].lower() for match in LITERAL.finditer(text))
        for match in CONCATENATION.finditer(text):
            concatenations.add(re.escape(match[2].lower()) + r"[a-z]+" + re.escape((match[4] or "").lower()))
    return literals, re.compile("|".join(sorted(concatenations))) if concatenations else None


def preferred_member(members):
    def rank(member):
        name = member["CommittedName"].lower()
        return (name.endswith("-2x"), not name.endswith("-c60"), int(member["ID"]))
    return min(members, key=rank)


def compile_atlases(tables, wanted):
    atlases = {row["ID"]: row for row in tables["UiTextureAtlas"]}
    members = defaultdict(list)
    for row in tables["UiTextureAtlasMember"]:
        members[row["UiTextureAtlasElementID"]].append(row)
    literals, pattern = wanted
    selected = {}
    for element in tables["UiTextureAtlasElement"]:
        name = element["Name"]
        lower = name.lower()
        if not members[element["ID"]]:
            continue
        if lower not in literals and not (pattern and pattern.fullmatch(lower)):
            continue
        member = preferred_member(members[element["ID"]])
        atlas = atlases[member["UiTextureAtlasID"]]
        width, height = int(atlas["AtlasWidth"]), int(atlas["AtlasHeight"])
        flags = int(member["CommittedFlags"])
        selected[name] = {
            "file": int(atlas["FileDataID"]),
            "width": int(member["Width"]),
            "height": int(member["Height"]),
            "left": int(member["CommittedLeft"]) / width,
            "right": int(member["CommittedRight"]) / width,
            "top": int(member["CommittedTop"]) / height,
            "bottom": int(member["CommittedBottom"]) / height,
            "tilesH": bool(flags & TILES_HORIZONTALLY),
            "tilesV": bool(flags & TILES_VERTICALLY),
        }
    if not selected:
        raise ValueError("no wanted atlas was found in the client tables")
    return selected


def lua_atlases(atlases, build):
    lines = ["return {", f'\tbuild = "{build}",', "\tatlases = {"]
    for name in sorted(atlases, key=str.lower):
        info = atlases[name]
        fields = [f'file = {info["file"]}', f'width = {info["width"]}', f'height = {info["height"]}']
        fields += [f"{key} = {info[key]:.12g}" for key in ("left", "right", "top", "bottom")]
        fields += [f'{key} = {"true" if info[key] else "false"}' for key in ("tilesH", "tilesV")]
        lines.append(f'\t\t["{name}"] = {{ ' + ", ".join(fields) + " },")
    return "\n".join(lines + ["\t},", "}", ""])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--flavor", default="forever")
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--check-pin", action="store_true")
    parser.add_argument("--cache", type=Path, default=CACHE)
    parser.add_argument("--scan", nargs="+", metavar="GLOB", help="host Lua files (globs, from --root) whose atlas names to keep")
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="where --scan globs start (default: current directory)")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.update and (args.check or args.fetch or args.check_pin):
        parser.error("--update cannot be combined with validation or --fetch")
    if args.check_pin and (args.check or args.fetch):
        parser.error("--check-pin cannot be combined with --check or --fetch")
    if bool(args.scan) != bool(args.output):
        parser.error("--scan and --output go together (without both, the lib's own table is built)")
    if args.update and args.scan:
        parser.error("--update rebuilds the lib's own table; run --scan separately")
    cache = args.cache.resolve()
    pin = pinned_source(args.flavor)
    output = (args.output or default_output(pin)).resolve()
    if args.check_pin:
        read_manifest(pin)
        if f'build = "{pin["build"]}"' not in output.read_text():
            raise ValueError("generated atlas table build does not match the pin")
        print(f'{args.flavor} {pin["build"]}: atlas table pin verified')
        return
    if args.update:
        tables, manifest, compressed = download(pin)
        write_cache(pin, cache, compressed)
        pin["atlasExports"] = manifest
        pin_path(args.flavor).write_text(canonical(pin))
    elif args.fetch:
        manifest = read_manifest(pin)
        tables, fetched, compressed = download(pin)
        if fetched != manifest:
            raise ValueError("downloaded tables do not match the pinned checksums; review with --update")
        write_cache(pin, cache, compressed)
    else:
        tables = read_cache(pin, cache)
    wanted = atlas_uses(args.scan, args.root.resolve()) if args.scan else atlas_uses(LIB_SCAN, ROOT)
    atlases = compile_atlases(tables, wanted)
    text = lua_atlases(atlases, pin["build"])
    if args.check:
        if not output.exists() or output.read_text() != text:
            raise ValueError(f"stale generated artifact: {output}")
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text)
    print(f'{args.flavor} {pin["build"]}: {len(atlases)} atlases')


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
