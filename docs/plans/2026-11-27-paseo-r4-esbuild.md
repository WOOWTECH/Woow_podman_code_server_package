# Paseo R4 esbuild dependency update

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the Go 1.23.12 esbuild binaries in new managed installations while retaining exact R3 control of an already running daemon.

**Architecture:** Pin esbuild 0.28.2 through the managed npm override and publish a distinct R4 generation named with its new lock digest. Freeze R3 manifests, all 23 essential entrypoints, SDK patch files and receipts independently of the current readiness recipe. R3 and earlier generations remain control-only; installation never overwrites them.

**Tech Stack:** Node 22, npm lockfile v3, node:test, official Paseo 0.17.5 SDK and esbuild 0.28.2.

## Work

1. Capture the fresh e5622bb R3 manager and exact local R3 SDK readiness into `connectors/paseo/src/runtime-control-0175-r3.json` and an independent compressed installer fixture. The actual R3 table has 22 entrypoints plus a separately MCP-guarded agent manager: freeze these 23 core files and all five patch receipts. Test missing, empty, changed and symlinked inputs and independence from current patch recipes.
2. Add the esbuild override in `connectors/paseo/runtime-manifest/package.json`, regenerate its lock with scripts disabled, and review the dependency diff. Change `src/runtime-layout.mjs` to select only `0.17.5-r4-<new-lock-digest>` for new starts. Preserve frozen R2 verification and the current Claude root patch unchanged.
3. Add `src/esbuild-runtime.mjs` to verify official esbuild wrapper/package hashes and both generic/platform binary paths (amd64/arm64, including legitimate hardlinks). Update `tests/installer.test.mjs`, add focused R3 control and actual SDK compile tests, and update `connectors/paseo/provenance.json` with source hashes and the R4 dependency reason. Installer fixtures copy verified compiler bytes from the explicitly prepared `WOOW_PASEO_TEST_RUNTIME`, rather than vendoring native executables. Do not edit the browser harness files, README or existing public R3 acceptance/evidence documents owned by the parent.
4. Install an actual R4 SDK into a newly owned local directory outside the repository. With no daemon, accounts or inference, exercise the SDK plugin compiler's server/client/import-boundary behavior and its actual OpenCode bridge compilation function. Verify both native esbuild copies and the frozen actual R3 control path without modifying R3.
5. Run the complete Paseo and shared CLI/extension-seed Node suites (previous baseline: 314 tests) and extension suites. Include the parent's new browser contract cases and report actual counts. Verify provenance, immutable R3 bytes and unchanged parent-owned evidence; leave all changes uncommitted for parent review.

## Evidence boundary

R3 browser, model and image-upgrade evidence remains evidence of R3. R4 compilation/unit results do not claim an image build, Grype comparison, live browser acceptance or model verification. The parent synchronizes consumers and reviews before any commit.

The SDK's eager CommonJS wrapper captures top-level `const` exports before initialization. The same executable reproduction returned `undefined` on the untouched R3/esbuild 0.25.12 baseline and R4; this is a pre-existing upstream compiler limitation, outside this dependency change. Compilation contracts exercise function entrypoints, actual client TSX/SVG/async lowering, import boundaries and both real OpenCode bridge artifact builds without changing that SDK wrapper.

## Local validation, 2026-11-27

- Runtime: `0.17.5-r4-2b20ef5fac0a`; lock SHA-256 `2b20ef5fac0a45dfd756d8470222a0d3c8ee9012c7cb318d65c8bba90c469f42`. Only esbuild and its 26 platform packages changed in the lock.
- Official npm archives for esbuild and the linux-x64/linux-arm64 binaries matched their locked SHA-512 integrities. Both platform binaries carry Go 1.26.5. Actual compilation ran on amd64; arm64 verification covered archive provenance and binary hashes.
- Focused installer/R3-control/compiler suites: 251 passed, zero skipped. Complete Paseo/shared CLI/extension-seed suites, including the parent's three additional browser contracts: 360 passed, zero skipped. Extension suite: 49 passed, zero skipped.
- The actual R4 SDK is ready, and installer reuse made no npm call or SDK byte/mode/inode changes. All 46 original R3 pinned files and all five receipt IDs still verify for control only. Tests also reject every missing/empty/tampered/symlinked frozen input and remain valid when current patch IDs/readiness recipes change.
- No consumers, existing generations, live QA, accounts, model calls or parent-owned browser/acceptance files were modified by this task. All canonical edits remain uncommitted for parent review.

Test commands use an explicitly installed local R4 SDK:

```sh
export WOOW_PASEO_TEST_RUNTIME=/absolute/owned/runtime/releases/0.17.5-r4-2b20ef5fac0a
export PI_PASEO_TEST_PERSISTED_CONFIG="$WOOW_PASEO_TEST_RUNTIME/node_modules/@getpaseo/server/dist/server/server/config.js"
node --test connectors/paseo/tests/*.test.mjs tests/connectors-cli.test.mjs tests/connector-extension-seed.test.mjs
npm test --prefix extensions
```
