# Veo Windows

Keep the beta in `windows/`. Use native WinUI 3 and a single local Codex stdio runtime. Preserve the Mac workspace and use WebView2 for browser pages only.

- Match the Mac reference’s placement, size, spacing, and interaction with native WinUI controls. Keep Auto and Daybreak in one open Advanced menu, and verify composer pills and plus-menu behavior in the running app.
- Keep Windows business logic in services and coordinators. Preserve raw protocol fields, thread and item identity, and explicit workspace access. Reconcile uncertain sends before retrying.
- Use `scripts/build.ps1` and `scripts/run.ps1` for development and `scripts/package-beta.ps1` for the portable release. Windows test suites may run. Run Xcode tests only on explicit request.
- Record exercised behaviors in `docs/parity.md`. A successful build does not verify UI, signing, clean installation, physical ARM64, or hardware workflows.
- Use a GitHub prerelease for Windows. Keep source on the beta branch and identify packaging limitations in the release notes.
