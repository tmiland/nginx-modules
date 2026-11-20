# Licensing

The MIT license at the repository root covers this repository's metadata,
scripts, and generated catalog.

Module sources bundled by `scripts/build_bundle.sh` are **not** relicensed.
Each module retains its upstream license. The `license` field in
`modules/<id>.mod` records the upstream license at the time of pinning; the
upstream project is authoritative.

Patch files are redistributed as-is. Their provenance (upstream repository and
commit) is recorded in the module metadata. Patch entries use
`license = 'NOASSERTION'` because a patch can contain code from more than one
upstream project.

The bundles do not include Google PageSpeed Optimization Libraries (PSOL)
binaries or MaxMind GeoIP databases. Those are obtained separately by
`nginx_installer.sh` under their own terms.
