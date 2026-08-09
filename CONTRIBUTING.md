# Contributing to Veo

Thanks for helping improve Veo. This repository contains a single native macOS app that connects directly to the Codex CLI installed on the same Mac.

## Before you start

- Use macOS 14 or later and Xcode 16 or later.
- Install and authenticate the Codex CLI.
- Read [AGENTS.md](AGENTS.md) for the repository's runtime invariants and implementation guardrails.
- Keep unrelated local changes intact. The repository is often developed with an in-progress working tree.

Veo is local-first. Contributions must not add a hosted control plane, remote relay, phone companion, account or purchase gate, bundled credentials, analytics, or hardcoded production service.

## Build the app

For the normal local build and launch flow:

```sh
./script/build_and_run.sh
```

For a build followed by process verification:

```sh
./script/build_and_run.sh --verify
```

The equivalent build command is:

```sh
xcodebuild \
  -project Veo.xcodeproj \
  -scheme Veo \
  -configuration Debug \
  -derivedDataPath /tmp/veo-derived \
  build \
  CODE_SIGNING_ALLOWED=NO
```

The only shared scheme is `Veo`. Do not add iOS, widget, menu-bar helper, or mobile package graphs. The existing `MenuBarExtra` belongs to the Mac app process.

## Understand the boundaries

### Runtime

- `CodexAppServerClient` owns one local `codex app-server --stdio` subprocess.
- App-server stdout is newline-delimited JSON-RPC only. Send diagnostics to stderr.
- Correlate every response by request ID and keep one runtime owner per app process.
- Resolve Codex from `CODEX_EXECUTABLE`, the GUI `PATH`, Homebrew, or common local install paths.

### Threads and projects

- A thread's recorded local `cwd` is authoritative.
- Keep every repository visible in the sidebar; selecting a project must not filter away other repositories.
- Opening or creating a cross-project thread must switch local context automatically.
- Default new threads to workspace-scoped writes. Broader access must remain explicit.

### Timeline and turns

- `turn/started` can arrive without a usable turn ID, so preserve the per-thread running fallback.
- Recover the active turn through `thread/read` before interrupting when needed.
- Rehydrate the selected thread and running state after reconnect or relaunch.
- Keep assistant output item-scoped and merge late deltas into their original items.
- Preserve item-aware history reconciliation, structured request UI, and plan/reasoning structure.

## Code organization

- Put shared runtime and state logic in `Services/` or `Stores/`.
- Keep protocol and presentation models in `Models/`.
- Keep views focused on layout, interaction, and rendering.
- Prefer SwiftUI and native macOS windows, menus, sidebars, inspectors, settings, keyboard shortcuts, and accessibility APIs.
- Use semantic system colors and preserve the app's dark desktop presentation.
- Avoid duplicated coordinators, placeholder code, one-off compatibility layers, and dead predecessor terminology.

## Documentation

Documentation must describe the current Veo app, its direct local transport, and the actual repository layout. Do not add instructions for mobile pairing, relays, subscriptions, hosted deployment, or production domains.

When behavior changes, update the README, legal notice, contributor guidance, or agent guidance in the same change when relevant. Agent guidance lives in `AGENTS.md` (`CLAUDE.md` just references it).

## Validation

Use verification proportional to the change:

- Documentation-only changes: check links, commands, formatting, and stale terms.
- Small Swift changes: inspect the affected path, run a targeted `Veo` build, launch the built app, and verify the process.
- Runtime or UI changes: also exercise the affected workflow in the packaged app when practical.

Do not run Xcode tests unless the task explicitly requires them. A successful build alone does not prove thread recovery, JSON-RPC behavior, or UI state.

Before handing off a change, run:

```sh
git diff --check
```

## Pull requests

Keep pull requests narrow and explain:

- what user-visible or runtime behavior changed
- which project and thread invariants were considered
- how the change was verified
- any behavior that still needs live verification

Never include credentials, private project paths, generated build products, local Codex state, or personal environment files.

## License

By contributing, you agree that your contributions may be distributed under the repository's [Apache License 2.0](LICENSE).
