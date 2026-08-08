# Veo Privacy Notice

**Last updated:** August 6, 2026

This notice explains how Veo, a native macOS application maintained by Ash, handles information. It describes the open-source app in this repository and does not cover services independently operated by Codex providers or tools that you choose to use.

## 1. Summary

Veo is a local interface for the Codex CLI installed on your Mac. Veo does not require a Veo account and does not include a developer-operated backend, analytics, advertising, subscriptions, push notifications, or cross-app tracking.

Veo starts `codex app-server --stdio` as a local subprocess and exchanges newline-delimited JSON-RPC with it through standard input and output.

## 2. Information Veo handles locally

To provide its interface, Veo may display or process:

- project names, paths, and files you choose to open
- prompts and other input you submit
- Codex responses, reasoning, plans, commands, file changes, and tool activity
- thread identifiers, titles, timestamps, and working directories
- approval and information requests returned by Codex
- available models, reasoning options, service tiers, and collaboration modes

This information is passed between the Veo app and the local Codex subprocess so Veo can present and control the workspace.

## 3. Preferences stored by Veo

Veo uses standard macOS preferences to remember lightweight interface state, including:

- the last selected project and thread
- the selected access mode
- model, reasoning-effort, and service-tier choices
- per-thread plan-mode selections
- sidebar organization, sorting, collapse state, and manual ordering

These preferences remain on the Mac until they are changed or removed by you or by macOS.

## 4. Project files, credentials, and chat history

Veo does not bundle, request, or separately store your OpenAI credentials. Authentication is managed by the installed Codex CLI.

Project files remain in folders you control. Veo-owned chats and timeline items are stored locally under Application Support (`com.ash.Veo/Threads`). Codex configuration, credentials, and Codex CLI thread history remain in locations managed by you and the Codex CLI. Deleting Veo does not automatically delete project files or Codex CLI data because they are not stored in the app bundle.

## 5. Network and third-party processing

The Veo source in this repository does not contain its own network client or analytics SDK. However, the Codex subprocess may send prompts, file context, tool results, and related information to OpenAI or another provider according to your Codex configuration. Tools run by Codex may also access network services.

That processing is controlled by the provider, your Codex configuration, the selected project, and the access level you grant. Review the applicable provider terms and privacy policy, including the [OpenAI Privacy Policy](https://openai.com/policies/privacy-policy/) when using Codex with OpenAI.

## 6. Access levels and local actions

Veo offers read-only, workspace-write, and full-access modes. Workspace access is the default for new chats. Full access can allow Codex tools to affect files outside the selected project and should be enabled only when needed.

When you choose the corresponding actions, Veo may ask Finder to reveal a project or Terminal to open in its directory.

## 7. Retention and deletion

- Veo preferences remain until changed or removed.
- Veo-owned chats remain under Application Support until you delete them in the app or remove that data.
- Project files remain until you modify or delete them.
- Codex credentials and Codex CLI thread history follow the Codex CLI's storage and retention behavior.
- Any information sent to a configured provider follows that provider's retention practices.

To remove Veo's preferences, use macOS preference-management tools for the app's bundle identifier, `com.ash.Veo`. Remove Codex data separately only after reviewing the Codex CLI's own configuration and storage.

## 8. Security

No software can guarantee absolute security. Keep macOS, Veo, the Codex CLI, and project dependencies up to date. Review commands, approvals, access levels, and file changes before relying on or publishing results. Maintain backups of important work.

## 9. Children's privacy

Veo is a developer tool and is not directed to children under 13 or the minimum age required by applicable law. The Veo app does not operate a service that knowingly collects children's personal information.

## 10. Changes to this notice

This notice may be updated when Veo's behavior changes. The date at the top identifies the current revision.

## 11. Contact

For questions about Veo or this notice, contact Ash through the [Veo repository](https://github.com/itsasheruwu/Veo). Do not post credentials, private prompts, or other sensitive information in a public issue.
