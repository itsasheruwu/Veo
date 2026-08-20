# AGENTS.md — Veo Repository Guide

Veo is a local-first native macOS workspace for the Codex CLI. The repository contains one Mac app, one direct local app-server transport, and no hosted product or mobile companion.

Do not add a mobile companion, relay, phone pairing, subscriptions, hosted deployment, or compatibility layers for an earlier product architecture. Keep code, documentation, automation, assets, and product copy specific to Veo.

## Core guardrails

- Prefer the native Mac app, direct local `codex app-server` transport, local project folders, and normal macOS window/menu workflows.
- Be an intraprendente agent: proactively inspect local code, protocol/schema, and official sources to confirm facts before replying; do not repeatedly stop to ask for confirmation when the next verification step is safe and obvious.
- Keep repo isolation by thread/project metadata and local `cwd`.
- Do not reintroduce filtering by selected repo in sidebar/content.
- Keep cross-repo open/create flow with automatic local context switch.
- Preserve single responsibility: shared logic belongs in services/coordinators, not duplicated in views.
- Treat this repo as open source: avoid junk code, placeholder hacks, noisy one-off workarounds, and low-signal docs.
- Keep public documentation centered on Veo's current Mac app, actual source layout, direct local transport, and explicit access model.
- Do not create one-off report markdown files in the repo root (security reports, audit notes, scratch summaries, etc.) unless the user explicitly asks for a file. Keep ad-hoc analysis in the chat.
- Keep user-facing answers compact by default unless the user explicitly asks for more detail.

## macOS runtime + timeline guardrails

- `turn/started` may not include a usable `turnId`: keep the per-thread running fallback.
- If Stop is tapped and `activeTurnIdByThread` is missing, resolve via `thread/read` before interrupting.
- On process reconnect or app relaunch, rehydrate the selected thread and active turn state so Stop remains visible.
- Treat `codex app-server` stdout as newline-delimited JSON-RPC only; keep diagnostics on stderr and never mix them into protocol parsing.
- Keep assistant rows item-scoped to avoid timeline flattening/reordering.
- Merge late reasoning deltas into existing rows; do not spawn fake extra "Thinking..." rows.
- Ignore late turn-less activity events when the turn is already inactive.
- Preserve item-aware history reconciliation instead of falling back to `turnId`-only matching.

## Local runtime guardrails

- The Mac app starts the locally installed Codex CLI directly. Keep that stdio runtime as the only workspace transport.
- Discover the CLI from an explicit `CODEX_EXECUTABLE`, the GUI process `PATH`, and standard Homebrew/local install locations.
- Preserve one local runtime owner per app process and correlate JSON-RPC responses by request id.
- Keep all repositories visible in the sidebar; choosing or opening a thread changes local `cwd` automatically without filtering other repositories away.
- The workspace must remain usable without an account purchase gate or hosted companion service.
- Keep access choices explicit. Default to workspace-scoped writes, and never silently broaden a thread to full-disk access.

## Build guardrails

- Do not run Xcode tests unless the user explicitly asks. Do not decide to run them on your own.
- Markdown files inside Xcode-synced groups can still produce harmless warnings.
- The only product scheme is `Veo`, a native macOS app. Keep the project free of UIKit, widgets, phone targets, and mobile package graphs.
- For small macOS fixes, prefer inspection, a targeted `Veo` build, and launch/process verification.

## SwiftUI craft

Veo is almost entirely SwiftUI over AppKit. Most bad UI work here fails in one of four ways: designing from a description instead of the reference, building controls the pointer cannot actually hit, letting a control's width move things around it, or calling a green build "done".

### Match the reference, don't paraphrase it

- If a recording, screenshot, or marked-up image exists, it is the spec. Read pixels off it before writing any view code.
- Extract and measure rather than eyeball: `ffmpeg -ss <t> -i ref.mov -frames:v 1 -vf "crop=W:H:X:Y" out.png` for full-resolution crops, `fps=2` plus `tile=5x5` for a contact sheet of the whole interaction, and a one-pixel `crop=W:1:X:Y -f rawvideo -pix_fmt rgb24` scan to read exact edges, run lengths, and RGB values.
- Screen recordings are 2×. Halve every measurement to get points, then sanity-check the total against the panel's measured height.
- Watch for behaviour the written brief omits — hover-only affordances, labels that swap on drag, a state that only appears at one end of a range. Those details are most of what makes a copy read as convincing.
- Collect the derived numbers in one private `enum ...Metrics` so the panel, its expanded form, and its trigger cannot drift apart.

### Controls the pointer can actually hit

- The visible row *is* the button: make the styled content the `Button`/`Menu` label. Never layer an invisible hit target over a separately drawn row.
- Never use `Color.clear`, `.opacity(0.001)`, or a bare `Spacer` as a pointer target.
- Any decorative layer drawn above a control must set `.allowsHitTesting(false)` explicitly.
- Do not stack opaque shapes over a native `Slider`/`Toggle` and rely on clicks reaching it. Build the control: opaque shapes, `.contentShape(Rectangle())`, and `DragGesture(minimumDistance: 0)` so click-to-jump and drag are the same gesture.
- Accessibility increment/decrement passing is not evidence the mouse works. Click it, drag it, and hover it in the running app.

### Stable layout and anchors

- A `.popover` anchors to its label's frame, so a label whose width tracks its text drags the popover around as values change. Give such triggers a fixed `.frame(width:)` with the content centred and any chevron pinned trailing.
- Composer chrome is a horizontal stack: a control that grows pushes its neighbours. Fixed-width beats `ViewThatFits` wherever the popover anchor or neighbouring controls matter.
- Size the fixed width to the longest realistic label (model name plus effort plus icons), not to the current one — then verify with the longest and shortest values.

### When to drop to AppKit, and how far

- Reach for AppKit only where SwiftUI genuinely cannot express it: drawing outside a popover's bounds, menu items with a secondary description line, or explicit menu placement. `NSMenu` built in a small coordinator covers all three and keeps native hit-testing, keyboard nav, and VoiceOver.
- Anchor such menus to a passthrough `NSViewRepresentable` whose view overrides `hitTest` to return `nil`, and place it in `.background(...)` so it never competes for clicks.
- Compute the menu origin in screen coordinates and clamp it to `screen.visibleFrame`; anchored off a control near the window bottom, an unclamped menu turns into a scrolling menu instead of moving up.
- Keep the bridge narrow — one anchor view plus one menu builder. Custom titlebar/overlay AppKit work has hung this app before (see the Liquid Glass note below).

### Adaptive, animated, accessible by default

- Prefer semantic styles (`.primary`, `.secondary`, `.tertiary`, `Color.primary.opacity(...)`, materials) over hardcoded greys so light and dark both work from one definition. Reserve literal colours for deliberate brand ramps and give them a light/dark variant.
- Verify both appearances: `defaults write com.ash.Veo VeoDesktop.appearanceMode light`, relaunch, compare, then set it back to what it was.
- Gate every animation on `@Environment(\.accessibilityReduceMotion)`.
- Custom controls need `.accessibilityElement()`, a label and value, and `.accessibilityAdjustableAction` for anything range-like; keyboard support via `.focusable()` and `.onKeyPress`.
- Suppress the system focus ring with `.focusEffectDisabled()` and draw a quiet one of your own, shown only once the keyboard has been used. Ash does not want loud blue system rings in Veo chrome.

### Verification

- A successful `xcodebuild` says nothing about whether the design matches or the control is clickable.
- Kill stale instances, launch the exact artifact you just built, then drive the real UI: open the surface, click every row, drag every slider, toggle every switch, and screenshot each state next to the reference crop.
- Confirm store side effects landed (the visible label *and* the persisted `defaults` key), and restore any preference or selection you changed while testing.

## Model selection

Rankings, higher = better. Cost reflects what I actually pay (OpenAI is near-free for me due to a deal), not list price. Intelligence is how hard a problem you can hand the model unsupervised. Taste covers UI/UX, code quality, API design, and copy.

| model | cost | intelligence | taste |
|---|---:|---:|---:|
| gpt-5.6-sol | 9 | 8 | 5 |
| sonnet-5 | 5 | 5 | 7 |
| opus-4.8 | 4 | 7 | 8 |
| fable-5 | 2 | 9 | 9 |

How to apply:

- These are defaults, not limits. You have standing permission to override them: if a cheaper model's output doesn't meet the bar, rerun or redo the work with a smarter model without asking. Judge the output, not the price tag. Escalating costs less than shipping mediocre work.
- Cost is a tie-breaker only; when axes conflict for anything that ships, intelligence > taste > cost.
- Don't let cost prevent you from using the right model for the job. Instead, take advantage of cheaper options to get more information and try things before moving the work to a more expensive option.
- Bulk/mechanical work (clear-spec implementation, data analysis, migrations): gpt-5.6-sol — it's effectively free.
- Anything user-facing (UI, copy, API design) needs taste >= 7.
- Reviews of plans/implementations: fable-5 or opus-4.8, optionally gpt-5.6-sol as an extra independent perspective.
- Never use Haiku.
- Mechanics: gpt-5.6-sol is only reachable through the Codex CLI — `codex exec` / `codex review` (my `~/.codex/config.toml` defaults to gpt-5.6-sol). Use the codex-implementation, codex-review, and codex-computer-use skills; for work they don't cover (investigation, data analysis), run `codex exec -s read-only` directly with a self-contained prompt.
- Claude models (sonnet-5, opus-4.8, fable-5) run via the Agent/Workflow model parameter.

Using gpt-5.6-sol inside workflows and subagents (when the model parameter only takes Claude models, use a wrapper):

- Spawn a thin Claude wrapper agent with `model: 'sonnet', effort: 'low'` whose prompt instructs it to write a self-contained codex prompt, run `codex exec` via Bash, and return the report (use `schema` on the wrapper to get structured output back).
- Always label these agents with a `gpt-5.6-sol:` prefix, e.g. `{label: 'gpt-5.6-sol:review-auth'}` — the workflow UI shows the wrapper's Claude model, so the label is the only indication the real worker is gpt-5.6-sol.
- Codex runs can exceed Bash's 10-minute timeout: pass an explicit timeout, or run in the background and poll for the report file.
- Parallel gpt-5.6-sol implementation agents must use `isolation: 'worktree'` so codex edits don't collide in the shared checkout.
- Workflow token budgets only count Claude tokens; codex work is free and invisible to `budget.spent()`.

## Long-running gpt-5.6-sol tasks

gpt-5.6-sol is exceptionally capable on long-running tasks. Give it substantial, multi-step work when it is a good fit; do not artificially split a coherent task merely to make it shorter.

- The quality of the result depends on the quality of the prompt. Give it a detailed, self-contained brief: the objective, relevant context, constraints, expected outputs, files or systems in scope, acceptance criteria, and the verification required.
- State important invariants and non-goals explicitly. Do not assume it can infer project-specific constraints that are not in the prompt or the repository instructions.
- For complex work, ask it to inspect the current state, implement the full solution, run proportionate verification, and report concrete results and remaining risks.
- Prefer one well-scoped, detailed prompt over a vague prompt followed by many corrective iterations.

## Local quick runbook

```bash
xcodebuild -project Veo.xcodeproj -scheme Veo -configuration Debug -derivedDataPath /tmp/veo-derived build CODE_SIGNING_ALLOWED=NO
open /tmp/veo-derived/Build/Products/Debug/Veo.app
```

## Learned User Preferences

- Treat screenshot markup and scribbles as the source of truth for UI placement; implement the marked moves literally.
- When relocating controls, move them to the requested place at their original size — do not shrink, restyle, or substitute a different control treatment for the relocation.
- Prefer main-pane actions (New chat, Reveal project, Inspector) on the real top-trailing window toolbar with system Liquid Glass — not the leading/sidebar side, not a content inset below the title bar, and not a custom glass overlay.
- When removing icons, avatars, or spacers, reclaim the freed space by shifting remaining content — do not leave empty gutters.
- Prefer leaner Veo chrome: remove redundant decorative elements the user marks (sidebar brand/header blocks, non-functional fake controls, assistant sparkles avatars) and keep sidebar content denser under the traffic lights.
- Prefer the workspace terminal as a Codex-style bottom panel with a real interactive shell (PTY), not a modal sheet or a separate "type a command" field.
- Prefer Codex-chats loading as a progress bar only — no "Loading Codex chats..." label.
- When sidebar organization is by project, group Codex threads under project headers the same way as Veo threads.
- Prefer a text shimmer on in-progress Thinking labels and on thread titles while a turn is active (respect Reduce Motion).
- Prefer custom Veo accent on folder icons and the selected chat-row highlight; keep project folder names neutral/secondary without accent tint.
- Prefer Terminal settings for Agent CLIs (optional yolo/full-access for Claude and Codex); when Agent CLIs is off, gate `claude`/`codex` in the docked terminal behind an allow prompt rather than running them silently.
- Prefer the in-app browser start page to sit on the real right-sidebar material (Solid/Mica/Liquid Glass) rather than an opaque main-canvas fill; keep the address bar and start-page search as separate drafts; avoid the system blue focus ring on the address bar (use Veo’s own quiet chrome).

## Learned Workspace Facts

- Most Veo desktop chrome (sidebar, welcome/empty state, composer shell, timeline rows, docked terminal panel) lives in `Veo/Views/DesktopWorkspaceView.swift`, with `ComposerTextView.swift`, `DesktopModelMenu.swift`, `DesktopInteractiveTerminalView.swift` / `DesktopTerminalView.swift`, and `DesktopShimmerText.swift` as related pieces.
- The Veo window uses a hidden title bar with traffic lights over the sidebar; avoid large top spacers that leave a dead band above New Chat/Search.
- Custom titlebar Liquid Glass overlays can hang Veo via an AppKit key-view/focus loop; put glass toolbar actions on the real window toolbar instead.
- Veo owns the default chat catalog and timeline in SQLite (`Veo/Services/VeoThreadStore.swift` under Application Support `com.ash.Veo/Threads`); Codex app-server is the turn runtime via a private `codexThreadId`. Optional Codex CLI history appears in a separate sidebar section when `VeoDesktop.showCodexThreads` is on (Settings + sidebar options; OFF by default); when sidebar organization is by project, Codex threads group under project headers like Veo threads.
- The docked terminal uses SwiftTerm plus a local PTY (`DesktopLocalTerminalSession`); keep PTY winsize synced to the SwiftUI viewport so TUI CLIs like `codex` and `claude` render correctly.
- Appearance (Sync/Light/Dark, accent color, sidebar Solid/Mica/Liquid Glass) is driven by `DesktopAppearancePreferences`; apply custom accent via the `veoAccent` environment because `Color.accentColor` alone does not reliably carry Veo's tint on macOS.
- Terminal Agent CLI / yolo preferences live in `DesktopTerminalPreferences` and Settings → Terminal.
- The composer model picker has two appearances (`DesktopModelPickerAppearance`, Settings → Appearance): `native` is the studio popover, `sliderAdvanced` is the ChatGPT/Codex-style panel — a compact effort slider that expands into Model/Effort/Speed rows, with submenus popped as `NSMenu` to the right. Both live in `DesktopModelMenu.swift` and share the live catalog and `DesktopCodexStore` selection methods; the slider trigger is fixed-width on purpose so the popover anchor cannot move.
- The in-app browser lives in `DesktopBrowserPanelView` / `DesktopBrowserModel`, with Keychain save/fill and passkeys in `DesktopBrowserKeychain`. Settings → Browser (`DesktopBrowserPreferences`) holds search engine (Google default), restore tabs, desktop site, JavaScript, fraud warning, AutoFill, and passkeys. WKWebView should identify as current Safari and request desktop layout so sites don’t look dated.
- ChatGPT Account sign-in must open in Veo’s WKWebView (shared cookie store), not Safari. ChatGPT as a search engine uses `chatgpt.com` with temporary chat and web search (`temporary-chat=true`, `hints=search`).
