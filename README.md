# truffleruby feedstock

TruffleRuby (GraalVM Community, native mode) as a tebako **runtime** —
the spec 28 §8 implementation axis's `truffleruby` flavor of the `ruby`
engine (`ruby:truffleruby`): the release ships the pair per platform,
the tebako-owned wrapper exe (`tebako-runtime-launcher`, the process
entry point) plus the env image (`.tfs`, mounted — never extracted).

- **kind:** runtime (`engine: ruby`, `implementation: truffleruby`)
- **upstream:** TruffleRuby Community 34.0.1 (oracle/truffleruby,
  graal-34.0.1) — the native-mode archives, repacked (no compilation)
- **artifacts:** `tebako-runtime-<tebako-line>-34.0.1-<platform>` +
  `.tfs` + `.sha256` sidecars + release shards, the derived
  `manifest.json` index + `SHA256SUMS.txt`, and this registry
  (`tpkg-registry.yaml`) on the repo's releases
- **platforms:** aarch64-macos, x86_64-linux-gnu, aarch64-linux-gnu —
  upstream ships NO windows and NO macos-x86_64 build; the registry
  declares the matrix declaratively
- **visibility:** `exec-cache` (spec 29 §3) with the link-unit preload
  shim granted (the jail survives the exec). The native launcher
  resolves its home exe-relative and dies materialized alone
  ("Loading libjli failed") — preload (tier 1) can never work for it;
  the home tree materializes whole into the spec 22 §6 exec cache.

Consumers' app payloads declare
`runtime_requirement: {engine: ruby, implementation: truffleruby, constraint: "~> 34"}`
on their entrypoints (or select `ruby:truffleruby` through the spec 28
grammar); the dispatcher resolves the newest compatible cached runtime
(or downloads + verifies it from this repo's release index).

The jvm-mode sibling (truffleruby on `java:graalvm`, spec 33's
runtime-on-runtime composition) is TODO.truffleruby/03 — a separate
registry entry from this same recipe's second flavor, not a new repo.
