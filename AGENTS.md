# Veo repository guide

Veo is a local-first workspace for the Codex CLI. The stable Mac app lives in `Veo/` and `Veo.xcodeproj`. The native WinUI beta lives in `windows/` on the Windows beta branch. `docs/` is the public site. Keep the apps native and use one locally installed `codex app-server` per app process. Veo has no hosted workspace, relay, purchase gate, or mobile companion.

## Runtime and data

- Discover Codex from `CODEX_EXECUTABLE`, the GUI process PATH, and standard install locations. Keep stdout newline-delimited JSON-RPC, diagnostics on stderr, and responses correlated by request ID.
- Use thread and project metadata to isolate local `cwd`. Keep every project visible in the sidebar and switch working directories automatically when a chat opens. Default to workspace-scoped writes. A sandbox failure must never grant full access.
- Keep per-thread running state when `turn/started` omits an ID. Resolve the active ID with `thread/read` before Stop when needed. Rehydrate the selected chat and running state after reconnect or relaunch.
- Preserve item identity and chronology in the timeline. Merge late reasoning into the existing item and ignore late turn-less activity after completion. Do not replay a send with an uncertain outcome.
- Veo owns its chat catalog and timeline in SQLite, with private Codex thread IDs for runtime access. Optional Codex CLI chats stay in their own sidebar section, off by default, and group by project when selected.
- Keep shared logic in services or coordinators. Verify capability-dependent behavior against the selected runtime and its live catalog.

## UI and parity

- Treat supplied screenshots, recordings, and markup as the layout spec. Measure the reference at its display scale. Match placement, size, spacing, and behavior. On Windows use native WinUI controls and appearance, including ToggleSwitch.
- Use the visible control as the hit target. Decorative layers must pass input through. Preserve keyboard navigation, accessible labels and values, quiet focus cues, light and dark appearance, and reduced motion.
- Size picker anchors for the longest supported label so selections do not move the popover or neighboring controls. Keep Advanced open when Auto or Daybreak changes. Refresh options and switch availability in place.
- Keep Plan, Debug, and Goal beside Send. The plus menu keeps mode and Goal changes in place and shows Saved Prompts inside the popover.
- Put main-pane actions on the real top-trailing Mac toolbar with system Liquid Glass. Avoid custom title-bar overlays, which can hang AppKit focus. Keep the sidebar compact and reclaim space when removing controls.
- Prefer SwiftUI. Keep AppKit menu bridges narrow, use a passthrough anchor, and clamp placement to the visible screen. Use semantic styles and the `veoAccent` environment for the selected chat and folder icons.
- Keep the terminal docked with a real PTY and its size synced to the viewport. When Agent CLIs is off, require an allow prompt for `claude` and `codex`. Load Codex chats with a progress bar and shimmer active titles and Thinking labels when motion is allowed.
- Keep browser address and start-page search drafts separate. Use the sidebar material, quiet focus styling, and the app’s WKWebView session for ChatGPT sign-in.

## Build and release

- Mac changes use the `Veo` scheme. Run Xcode tests only when the user explicitly requests them. For routine work use `script/build_and_run.sh`. Use `script/package_release.sh` for universal Mac release artifacts.
- Launch the exact build you verified. Exercise changed controls with the pointer and keyboard, compare light and dark as relevant, verify persisted effects, and restore test preferences.
- `main:/docs` feeds GitHub Pages. Keep the changelog, download links, version, and checksums aligned with the published artifacts. Keep Windows releases marked prerelease so the Mac updater can use GitHub’s latest stable release.
- Windows build and verification details live in `windows/AGENTS.md` and `windows/README.md`. Record actual acceptance in `windows/docs/parity.md`.
- Keep ad-hoc reports in the chat. Preserve unrelated changes when committing, building, or releasing.

## Code map

- Mac workspace chrome is in `Veo/Views/DesktopWorkspaceView.swift`. Composer menu and picker code live in `DesktopComposerOptionsView.swift` and `DesktopModelMenu.swift`. The store and capability handling live in `Veo/Stores/DesktopCodexStore.swift`.
- Mac SQLite storage is in `Veo/Services/VeoThreadStore.swift`. Appearance, terminal, and browser defaults live in their `Desktop…Preferences` types. Browser credentials and passkeys use `DesktopBrowserKeychain`.
