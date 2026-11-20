#!/usr/bin/env python3
"""Build data/modules.json, data/bundles.json, and README.md from the catalog.

The .mod and .bundle files use a deliberately small TOML subset:

    key = 'literal value'
    key = "escaped value"
    key = bare_value

Single-line values only. Comments start with #.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULES_DIR = ROOT / "modules"
BUNDLES_DIR = ROOT / "bundles"
DATA_DIR = ROOT / "data"
README_PATH = ROOT / "README.md"

REPO_SLUG = "tmiland/nginx-modules"

MODULE_KEYS = [
    "id", "env", "kind", "dir", "versioned_dir", "version_var", "version",
    "repo", "homepage", "url", "strip", "sha256", "ref", "submodules", "build",
    "requires", "license", "status",
]
BUNDLE_KEYS = ["id", "name", "description", "modules"]

KINDS = {"git", "archive", "zip", "file"}
STATUSES = {"active", "legacy", "candidate"}
YES_NO = {"yes", "no"}

# These are the variables nginx_installer.sh reads. The catalog must define
# each one exactly once.
VERSION_KEYS = {
    "NPS_VER",
    "HEADERMOD_VER",
    "LIBMAXMINDDB_VER",
    "GEOIP2_VER",
    "LUA_JIT_VER",
    "LUA_NGINX_VER",
    "LUA_RESTYCORE_VER",
    "LUA_RESTYLRUACHE_VER",
    "NGINX_DEV_KIT",
    "HTTPREDIS_VER",
    "NGXECHO_VER",
    "ZSTD_VER",
    "OPENSSL_VER",
    "LIBRESSL_VER",
}

KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
VAR_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
REF_RE = re.compile(r"^[0-9a-f]{40}$")


class CatalogError(Exception):
    """A malformed catalog entry."""


def parse_value(raw: str, where: str) -> str:
    value = raw.strip()
    if not value:
        raise CatalogError(f"{where}: empty value")

    if value.startswith("'"):
        match = re.fullmatch(r"'([^']*)'[ \t]*(?:#.*)?", value)
        if not match:
            raise CatalogError(f"{where}: malformed single-quoted value")
        return match.group(1)

    if value.startswith('"'):
        try:
            decoded, end = json.JSONDecoder().raw_decode(value)
        except json.JSONDecodeError as exc:
            raise CatalogError(f"{where}: malformed double-quoted value: {exc}") from exc
        if not isinstance(decoded, str):
            raise CatalogError(f"{where}: expected a string")
        rest = value[end:].strip()
        if rest and not rest.startswith("#"):
            raise CatalogError(f"{where}: trailing text after quoted value")
        return decoded

    match = re.fullmatch(r"([^ \t#]+)[ \t]*(?:#.*)?", value)
    if not match:
        raise CatalogError(f"{where}: malformed bare value")
    return match.group(1)


def parse_conf(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = KEY_RE.match(line)
        if not match:
            raise CatalogError(f"{path}:{lineno}: expected key = value")
        key, raw_value = match.group(1), match.group(2)
        if key in data:
            raise CatalogError(f"{path}:{lineno}: duplicate key '{key}'")
        data[key] = parse_value(raw_value, f"{path}:{lineno}")

    return data


def require_keys(data: dict[str, str], expected: list[str], path: Path) -> None:
    missing = [key for key in expected if key not in data]
    if missing:
        raise CatalogError(f"{path}: missing keys: {', '.join(missing)}")
    extra = [key for key in data if key not in expected]
    if extra:
        raise CatalogError(f"{path}: unknown keys: {', '.join(extra)}")


def validate_dir(value: str, where: str) -> None:
    if not value or value.startswith("/") or ".." in Path(value).parts:
        raise CatalogError(f"{where}: dir must be a safe relative path")


def load_modules() -> dict[str, dict[str, object]]:
    modules: dict[str, dict[str, object]] = {}

    for path in sorted(MODULES_DIR.glob("*.mod")):
        data = parse_conf(path)
        require_keys(data, MODULE_KEYS, path)

        module_id = data["id"]
        where = str(path)
        if module_id != path.stem:
            raise CatalogError(f"{path}: id '{module_id}' does not match filename")
        if not ID_RE.fullmatch(module_id):
            raise CatalogError(f"{path}: invalid id '{module_id}'")
        if module_id in modules:
            raise CatalogError(f"{path}: duplicate module id '{module_id}'")

        if data["kind"] not in KINDS:
            raise CatalogError(f"{where}: invalid kind '{data['kind']}'")
        if data["status"] not in STATUSES:
            raise CatalogError(f"{where}: invalid status '{data['status']}'")
        if data["versioned_dir"] not in YES_NO:
            raise CatalogError(f"{where}: versioned_dir must be yes or no")
        if data["submodules"] not in YES_NO:
            raise CatalogError(f"{where}: submodules must be yes or no")
        if not data["strip"].isdigit():
            raise CatalogError(f"{where}: strip must be a non-negative integer")
        if not data["url"].startswith(("http://", "https://")):
            raise CatalogError(f"{where}: url must be http(s)")
        if not data["version"]:
            raise CatalogError(f"{where}: version must not be empty")
        validate_dir(data["dir"], where)

        if data["version_var"] and not VAR_RE.fullmatch(data["version_var"]):
            raise CatalogError(f"{where}: invalid version_var '{data['version_var']}'")
        if data["sha256"] and not SHA_RE.fullmatch(data["sha256"]):
            raise CatalogError(f"{where}: sha256 must be 64 lowercase hex characters")

        if data["kind"] == "git":
            if not REF_RE.fullmatch(data["ref"]):
                raise CatalogError(f"{where}: git ref must be a full 40-character SHA")
            if data["versioned_dir"] != "no":
                raise CatalogError(f"{where}: git modules must use versioned_dir = 'no'")
            if (re.fullmatch(r"[0-9a-f]{7,40}", data["version"])
                    and not data["ref"].startswith(data["version"])):
                raise CatalogError(f"{where}: version is not a prefix of ref")
        else:
            if data["ref"]:
                raise CatalogError(f"{where}: ref is only valid for git modules")
            if data["submodules"] != "no":
                raise CatalogError(f"{where}: submodules is only valid for git modules")

        requires = [
            item
            for item in data["requires"].split(",")
            if item.strip()
        ]
        requires = [item.strip() for item in requires]
        if len(set(requires)) != len(requires):
            raise CatalogError(f"{where}: duplicate entry in requires")
        if module_id in requires:
            raise CatalogError(f"{where}: module cannot require itself")

        data["requires"] = requires
        modules[module_id] = data

    if not modules:
        raise CatalogError(f"{MODULES_DIR}: no .mod files found")

    # Dependency references must exist, and the graph must be acyclic.
    for module_id, data in modules.items():
        for dep in data["requires"]:
            if dep not in modules:
                raise CatalogError(
                    f"modules/{module_id}.mod: requires unknown module '{dep}'"
                )

    # Version variables are the installer's public contract.
    seen_vars: dict[str, str] = {}
    for module_id, data in modules.items():
        var = str(data["version_var"])
        if not var:
            continue
        if var not in VERSION_KEYS:
            raise CatalogError(
                f"modules/{module_id}.mod: version_var '{var}' is not an installer variable"
            )
        if var in seen_vars:
            raise CatalogError(
                f"modules/{module_id}.mod: version_var '{var}' already used by "
                f"module '{seen_vars[var]}'"
            )
        seen_vars[var] = module_id

    missing_vars = sorted(VERSION_KEYS - set(seen_vars))
    if missing_vars:
        raise CatalogError(
            "catalog does not define required version variables: "
            + ", ".join(missing_vars)
        )

    return modules


def resolve_modules(module_ids: list[str], modules: dict[str, dict[str, object]]) -> list[str]:
    """Return module ids in dependency-first order, once each."""
    resolved: list[str] = []
    state: dict[str, int] = {}

    def visit(module_id: str) -> None:
        if module_id not in modules:
            raise CatalogError(f"unknown module '{module_id}'")
        if state.get(module_id) == 2:
            return
        if state.get(module_id) == 1:
            raise CatalogError(f"dependency cycle involving '{module_id}'")
        state[module_id] = 1
        for dep in modules[module_id]["requires"]:
            visit(str(dep))
        state[module_id] = 2
        resolved.append(module_id)

    for module_id in module_ids:
        visit(module_id)

    return resolved


def load_bundles(modules: dict[str, dict[str, object]]) -> dict[str, dict[str, object]]:
    bundles: dict[str, dict[str, object]] = {}

    for path in sorted(BUNDLES_DIR.glob("*.bundle")):
        data = parse_conf(path)
        require_keys(data, BUNDLE_KEYS, path)
        bundle_id = data["id"]
        if bundle_id != path.stem:
            raise CatalogError(f"{path}: id '{bundle_id}' does not match filename")
        if not ID_RE.fullmatch(bundle_id):
            raise CatalogError(f"{path}: invalid id '{bundle_id}'")
        if bundle_id == "full":
            raise CatalogError(f"{path}: 'full' is generated automatically")
        if bundle_id in bundles:
            raise CatalogError(f"{path}: duplicate bundle id '{bundle_id}'")

        module_ids = [item.strip() for item in data["modules"].split(",") if item.strip()]
        if not module_ids:
            raise CatalogError(f"{path}: modules must not be empty")
        if len(set(module_ids)) != len(module_ids):
            raise CatalogError(f"{path}: duplicate module in bundle")
        for module_id in module_ids:
            if module_id not in modules:
                raise CatalogError(f"{path}: unknown module '{module_id}'")

        data["modules"] = module_ids
        data["resolved"] = resolve_modules(module_ids, modules)
        bundles[bundle_id] = data

    active = sorted(
        module_id
        for module_id, data in modules.items()
        if data["status"] == "active"
    )
    bundles["full"] = {
        "id": "full",
        "name": "Full",
        "description": "All active modules plus their required dependencies.",
        "modules": active,
        "resolved": resolve_modules(active, modules),
    }

    ordered = {bundle_id: bundles[bundle_id] for bundle_id in sorted(bundles)}
    ordered["full"] = ordered.pop("full")
    return ordered


def bundle_dir(data: dict[str, object]) -> str:
    directory = str(data["dir"])
    if data["versioned_dir"] == "yes":
        return f"{directory}-{data['version']}"
    return directory


def md(value: object) -> str:
    return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ")


def write_catalog(modules: dict[str, dict[str, object]],
                  bundles: dict[str, dict[str, object]]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    module_rows = []
    for module_id in sorted(modules):
        data = modules[module_id]
        module_rows.append({key: data[key] for key in MODULE_KEYS})
    (DATA_DIR / "modules.json").write_text(
        json.dumps(module_rows, indent=2) + "\n", encoding="utf-8"
    )

    bundle_rows = []
    for bundle_id in list(bundles):
        data = bundles[bundle_id]
        bundle_rows.append(
            {
                "id": data["id"],
                "name": data["name"],
                "description": data["description"],
                "modules": data["modules"],
                "resolved": data["resolved"],
            }
        )
    (DATA_DIR / "bundles.json").write_text(
        json.dumps(bundle_rows, indent=2) + "\n", encoding="utf-8"
    )

    lines: list[str] = [
        "<!-- Generated by scripts/build_catalog.py; do not edit by hand. -->",
        "",
        "# nginx-modules",
        "",
        "Source bundles for "
        f"[nginx_installer.sh](https://github.com/tmiland/nginx-installer). "
        "Version pins and source locations live here, not in the installer.",
        "",
        "This repository ships source code, patches, and metadata only. It does "
        "not ship compiled nginx, Google PageSpeed Optimization Libraries (PSOL) "
        "binaries, or MaxMind GeoIP databases.",
        "",
        "## Installer usage",
        "",
        "Download a bundle from the latest release:",
        "",
        "```bash",
        f"curl -fsSLO https://github.com/{REPO_SLUG}/releases/latest/download/nginx-modules-full.tar.gz",
        "tar -xzf nginx-modules-full.tar.gz",
        "cd nginx-modules-full",
        "```",
        "",
        "The archive root contains:",
        "",
        "```text",
        "modules/       module sources at their final directory names",
        "versions.conf  version variables consumed by nginx_installer.sh",
        "modules.conf   one module per line: id|dir|kind|build|requires|env",
        "```",
        "",
        "The installer parses `versions.conf`; do not source an untrusted copy. "
        "It contains the version variables for the modules in that archive; "
        "`legacy` and `candidate` entries are only present in bundles that "
        "include them. In `modules.conf`, `{dir}` is a placeholder for "
        "`modules/<dir>`:",
        "",
        "```bash",
        "MODULES_DIR=$PWD/modules",
        "while IFS='|' read -r id dir kind build requires env; do",
        "  [[ -z $id || $id == \\#* ]] && continue",
        '  printf \'%s\\n\' "${build//\\{dir\\}/$MODULES_DIR/$dir}"',
        "done < modules.conf",
        "```",
        "",
        "`build` is empty for libraries and patch files. Those entries need "
        "installer-side handling: build LuaJIT, libmaxminddb, ModSecurity, "
        "OpenSSL, or LibreSSL first; apply `kind = 'file'` patches to the nginx "
        "source tree.",
        "",
        "The `full` bundle contains every `active` module. Named bundles are "
        "available for smaller source sets; build one with "
        "`bash scripts/build_bundle.sh --bundle <name>`. `legacy` or "
        "`candidate` modules are only included when explicitly selected.",
        "",
        "## Updating",
        "",
        "`bash scripts/update-modules.sh --check` compares pinned refs and "
        "archive versions with upstream and exits non-zero on drift. It is "
        "read-only: update the `.mod` file, run "
        "`python3 scripts/build_catalog.py`, then rebuild/test the bundle.",
        "",
        "## Modules",
        "",
        "| Module | Upstream | Version | Env | Kind | Status | Bundle directory | Requires | License |",
        "|---|---|---|---|---|---|---|---|---|",
    ]

    for module_id in sorted(modules):
        data = modules[module_id]
        requires = ", ".join(f"`{md(dep)}`" for dep in data["requires"]) or "-"
        repo = data.get("repo") or ""
        homepage = data.get("homepage") or ""
        url = data.get("url") or ""
        if repo:
            link = repo if repo.startswith("http") else f"https://github.com/{repo}"
            upstream = f"[`{md(repo)}`]({link})"
        elif homepage:
            if homepage.startswith("https://github.com/"):
                label = homepage.removeprefix("https://github.com/").rstrip("/")
                upstream = f"[`{md(label)}`]({homepage})"
            else:
                upstream = f"[homepage]({homepage})"
        elif url:
            upstream = f"[source]({url})"
        else:
            upstream = "-"
        lines.append(
            "| `{id}` | {upstream} | `{version}` | `{env}` | `{kind}` | `{status}` | "
            "`{dir}` | {requires} | `{license}` |".format(
                id=md(module_id),
                upstream=upstream,
                version=md(data["version"]),
                env=md(data["env"]) or "-",
                kind=md(data["kind"]),
                status=md(data["status"]),
                dir=md(bundle_dir(data)),
                requires=requires,
                license=md(data["license"]),
            )
        )

    lines.extend([
        "",
        "## Bundles",
        "",
        "`resolved` lists include dependencies pulled in through `requires`.",
        "Bundle files themselves list only directly selected modules.",
        "",
        "| Bundle | Name | Description | Resolved modules |",
        "|---|---|---|---|",
    ])

    for bundle_id in list(bundles):
        data = bundles[bundle_id]
        explicit = set(data["modules"])
        resolved = ", ".join(
            f"`{md(dep)}`" + ("" if dep in explicit else " (dep)")
            for dep in data["resolved"]
        ) or "-"
        name = md(data["name"])
        if bundle_id != "full":
            name = f"[{name}](bundles/{bundle_id}.bundle)"
        else:
            name = f"{name} (auto)"
        lines.append(
            f"| `{md(bundle_id)}` | {name} | {md(data['description'])} | {resolved} |"
        )

    lines.extend([
        "",
        "## Updating pins",
        "",
        "1. Edit the relevant `modules/<id>.mod` file.",
        "2. Run `python3 scripts/build_catalog.py` to refresh the JSON catalog "
        "and this README.",
        "3. Run `bash scripts/update-modules.sh --check` to look for upstream drift.",
        "",
        "Git modules are pinned to full commit SHAs. Archive modules are pinned "
        "to tags or release versions; add a `sha256` when a stable checksum is "
        "available. Patch files always carry a checksum.",
        "",
        "## Licensing",
        "",
        "The repository metadata and scripts are MIT-licensed. Vendored module "
        "sources keep their upstream licenses and are not relicensed. See "
        "[`licenses/README.md`](licenses/README.md) and each module's `license` "
        "field.",
        "",
    ])

    README_PATH.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    try:
        modules = load_modules()
        bundles = load_bundles(modules)
        write_catalog(modules, bundles)
    except CatalogError as exc:
        print(f"build_catalog: error: {exc}", file=sys.stderr)
        return 1

    print(
        f"wrote data/modules.json ({len(modules)} modules), "
        f"data/bundles.json ({len(bundles)} bundles), README.md"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
