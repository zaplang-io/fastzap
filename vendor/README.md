# vendor/

Third-party Zap packages fastzap depends on, vendored as path dependencies so
the offline CI toolchain image (which has no package registry or git access) can
resolve them. These are **not** fastzap's own source — do not edit them here;
change them upstream and re-vendor.

## validation

A verbatim copy of the public API source of
[zaplang-io/validation](https://github.com/zaplang-io/validation) (the
pydantic-style typed-model library, zaplang-io/zap#311): `src/validation.zap` and
`src/validation/pattern.zap`, plus a minimal `zap.toml`. fastzap declares it in
`zap.toml` as `validation = { path = "vendor/validation" }` and imports it as
`import validation`.

### Refreshing

Copy upstream `src/validation.zap` and `src/validation/` over
`vendor/validation/src/`, bump the version in `vendor/validation/zap.toml` to
match, and run `tools/run-tests.sh`. Once the Zap package registry is populated
this vendored copy should be replaced by a registry/git dependency (see
DECISIONS.md D-FZ-0005).
