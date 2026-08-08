# Veo

Veo is a native macOS workspace for working with Codex across local projects. It gives the locally installed Codex CLI a focused Mac interface for opening projects, browsing chats, following live work, answering approval requests, and controlling how much access each task receives.

Everything runs through one direct local connection:

```text
Veo.app  <── newline-delimited JSON-RPC over stdio ──>  codex app-server
   │                                                        │
   ├── projects you choose                                  ├── Codex authentication
   ├── macOS preferences                                    └── Codex thread history
   └── Finder, Terminal, menus, and windows
```

Veo does not include a hosted backend, account system, subscription, relay, phone companion, or bundled Codex credentials.

## Highlights

- Browse Codex chats from every local project in one persistent sidebar
- Start a chat in any folder and keep its working directory attached to the thread
- Stream assistant messages, reasoning, plans, commands, file changes, and tool activity
- Respond to user-input, command, file-change, permission, and MCP elicitation requests
- Choose models, reasoning effort, service tier, plan mode, and goal mode from the capabilities reported by Codex
- Switch between read-only, workspace-write, and full-access operation
- Stop active turns, including turns recovered after reconnecting or reopening the app
- Search, group, sort, collapse, and manually arrange chats
- Open the current project in Finder or Terminal
- Use the workspace from a native window, menu bar extra, app menus, and keyboard shortcuts

## Requirements

- macOS 14 or later
- Xcode 16 or later for building from source
- A locally installed and authenticated [Codex CLI](https://github.com/openai/codex)

Confirm that Codex is available before launching Veo:

```sh
codex --version
codex login status
```

If Veo cannot find the executable, set `CODEX_EXECUTABLE` to the absolute path of your Codex binary before opening the app. Veo also checks the GUI process `PATH`, standard Homebrew locations, and common local binary directories.

## Build and run

The project contains one shared scheme and one product target: `Veo` for macOS.

```sh
./script/build_and_run.sh
```

To build, launch, and confirm that the app process stays running:

```sh
./script/build_and_run.sh --verify
```

Or build manually:

```sh
xcodebuild \
  -project Veo.xcodeproj \
  -scheme Veo \
  -configuration Debug \
  -derivedDataPath /tmp/veo-derived \
  build \
  CODE_SIGNING_ALLOWED=NO

open /tmp/veo-derived/Build/Products/Debug/Veo.app
```

The helper also supports `--debug`, `--logs`, and `--telemetry` for local development.

## Getting started

1. Launch Veo and wait for the local Codex runtime indicator to become ready.
2. Choose **Open Project** and select a local folder.
3. Choose an access level. New chats default to **Workspace**, which allows writes inside the selected project.
4. Select a model and any supported reasoning or collaboration options.
5. Send a message. Veo creates a Codex thread with the selected folder as its `cwd`.

The sidebar remains cross-project: opening one project never hides chats from the others. Selecting an existing chat switches Veo back to that thread's recorded working directory.

## Access levels

| Mode | What Codex can do |
| --- | --- |
| Read only | Inspect files and state without workspace writes |
| Workspace | Write inside the selected project and approved temporary locations |
| Full access | Operate outside the selected project without filesystem sandboxing |

Full access is always an explicit choice. Review tool requests and keep important work under version control or backed up.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘N` | New chat |
| `⌘O` | Open project |
| `⇧⌘R` | Refresh chats |
| `⌘.` | Stop the active turn |
| `⌘,` | Open settings |
| `Return` | Send a message |
| `Shift-Return` | Insert a newline |

## How local data is handled

Veo stores lightweight interface preferences such as the last project, selected chat, access mode, model choices, and plan-mode selections in macOS preferences. Veo-owned chats and their timeline items are persisted locally under Application Support (`com.ash.Veo/Threads`). When the optional Codex threads sidebar section is enabled, that list still reads Codex CLI history; project files and credentials remain in locations controlled by the project, macOS, and the Codex CLI.

Veo itself has no network client or analytics SDK. The Codex subprocess may contact OpenAI or another configured provider and may run tools that access external services. Those actions follow your Codex configuration and the access granted to the thread.

See the [Privacy Notice](Legal/PRIVACY_POLICY.md) and [Terms of Use](Legal/TERMS_OF_USE.md) for more detail.

## Repository layout

```text
Veo.xcodeproj/             Xcode project and shared Veo scheme
BuildSupport/              App metadata
Veo/
  App/                     App entry point and scenes
  Models/                  Codex protocol and navigation models
  Services/                Local app-server process and JSON-RPC transport
  Stores/                  Workspace, thread, and turn coordination
  Views/                   Native macOS workspace, composer, and settings UI
script/build_and_run.sh     Local build, launch, debug, and verification helper
Legal/                     Privacy notice and terms
```

The runtime is intentionally owned once per app process. JSON-RPC responses are correlated by request ID, stdout remains protocol-only, and diagnostics stay on stderr.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before proposing a change. In particular, keep Veo Mac-native and local-first, preserve thread/project isolation, and avoid reintroducing code or documentation for the former mobile and hosted architecture.

## Project identity

Veo is an independent open-source project maintained by Ash. It is not an official OpenAI product and is not endorsed by or affiliated with OpenAI.

## License

Veo is available under the [Apache License 2.0](LICENSE).
