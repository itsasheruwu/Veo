"""Refresh the reviewable Mac baseline inventory; never marks Windows parity done.

Run from any directory: python windows/docs/generate-source-inventory.py
The JSON records literal source evidence. Dynamic labels/defaults still require
behavioral review; extraction is not a claim that the Windows UI implements them.
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
BASELINE = "0e9b18dd345488613198ca6050b34e960e27f8b3"


def reference(path: Path, text: str, position: int) -> str:
    return f"{path.relative_to(ROOT).as_posix()}:{text.count(chr(10), 0, position) + 1}"


def swift_sources():
    for directory in (ROOT / "Veo", ROOT / "BuildSupport"):
        if directory.exists():
            yield from sorted(directory.rglob("*.swift"))


def main():
    sources = {p: p.read_text(encoding="utf-8-sig") for p in swift_sources()}
    keys = defaultdict(list)
    definitions = defaultdict(list)
    defaults = defaultdict(list)
    persistence = []
    actions = []
    symbols = {}
    for path, text in sources.items():
        for match in re.finditer(r'\b(?:let|var)\s+(\w+)\s*=\s*"(VeoDesktop\.[^"\n]+)"', text):
            owners = list(re.finditer(r'\b(?:enum|class|struct)\s+(\w+)', text[:match.start()]))
            if owners:
                symbols[owners[-1][1] + "." + match[1]] = match[2]
    for path, text in sources.items():
        for match in re.finditer(r'"(VeoDesktop\.[^"\n]+)"', text):
            keys[match[1]].append(reference(path, text, match.start()))
        constants = {}
        for match in re.finditer(r'\b(?:let|var)\s+(\w+)\s*=\s*"(VeoDesktop\.[^"\n]+)"', text):
            constants[match[1]] = match[2]
            definitions[match[2]].append(reference(path, text, match.start()))
        for index, line in enumerate(text.splitlines(), 1):
            if "forKey:" in line or "@AppStorage(" in line:
                persistence.append({"source": f"{path.relative_to(ROOT).as_posix()}:{index}", "expression": line.strip()})
            for name, key in constants.items():
                if name not in line or "static let" in line:
                    continue
                if "??" in line or re.search(rf"\b{re.escape(name)}\s*:\s*", line):
                    defaults[key].append({"source": f"{path.relative_to(ROOT).as_posix()}:{index}", "expression": line.strip()})
            for match in re.finditer(r'@AppStorage\("(VeoDesktop\.[^"]+)"\)\s+(?:private\s+)?(?:var|let)\s+\w+\s*=\s*(.+)', line):
                defaults[match[1]].append({"source": f"{path.relative_to(ROOT).as_posix()}:{index}", "expression": match[2].strip()})
            if "forKey:" in line and '"VeoDesktop.' in line and "??" in line:
                for key in re.findall(r'"(VeoDesktop\.[^"]+)"', line):
                    defaults[key].append({"source": f"{path.relative_to(ROOT).as_posix()}:{index}", "expression": line.strip()})
        for match in re.finditer(r'@AppStorage\(([^)\n]+)\)\s+(?:private\s+)?(?:var|let)\s+\w+\s*=\s*([^\n]+)', text):
            key = symbols.get(match[1], match[1].strip('"') if match[1].startswith('"VeoDesktop.') else None)
            if key:
                defaults[key].append({"source": reference(path, text, match.start()), "expression": match[2].strip()})
        for match in re.finditer(r'\b(Button|Menu|Toggle|Picker|Label)\(\s*"((?:\\.|[^"\\])*)"', text):
            if match[1] == "Label":
                continue
            actions.append({"control": match[1], "sourceLabel": match[2], "source": reference(path, text, match.start()), "windowsRoute": None, "verificationStatus": "pending"})

    preferences = []
    for key, refs in sorted(keys.items()):
        category = category_for(key, refs)
        preferences.append({
            "semanticName": key.removeprefix("VeoDesktop."),
            "sourceStorageKey": key,
            "scope": "workspace" if key.startswith("VeoDesktop.browser.restore.") else "project-map" if any(s in key for s in ("projectConfigurations", "worktreeProjects", "worktreeIdentities")) else "thread-map" if any(s in key.lower() for s in ("bythread", "threadids", "threadmemory", "threadmodes", "dynamictoolthreads", "queue")) else "application",
            "category": category,
            "source": list(dict.fromkeys(definitions[key] + refs)),
            "defaultEvidence": defaults[key],
            "defaultReviewRequired": not bool(defaults[key]),
            "windowsStorageKey": None,
            "migration": "Fresh Windows profile; no automatic macOS settings import.",
            "uiLocation": f"Settings / {category}; confirm against source references",
            "commandRoute": command_route(category),
            "verificationScenario": "Change through its real UI, perform the affected workflow, relaunch the exact artifact, and reread persisted state and behavior.",
            "verificationStatus": "pending",
        })

    command_path = ROOT / "Veo/Models/DesktopComposerCommands.swift"
    command_text = sources[command_path]
    commands = []
    for match in re.finditer(r'\.init\(name: "([^"]+)", description: "([^"]+)", action: (.*?), systemImage: "[^"]+"(, supportsInlineArguments: true)?\)', command_text):
        commands.append({"invocation": "/" + match[1], "description": match[2], "sourceAction": match[3], "inlineArguments": bool(match[4]), "source": reference(command_path, command_text, match.start()), "windowsRoute": None, "verificationScenario": "Invoke through autocomplete and direct typing; verify the source-equivalent destination or downstream result.", "verificationStatus": "pending"})

    keyboard_path = ROOT / "Veo/Models/DesktopKeyboardPreferences.swift"
    keyboard_text = sources[keyboard_path]
    shortcuts = []
    for match in re.finditer(r'\("([^"]+)", "([^"]+)", \.init\(key: "([^"]+)", modifiers: "([^"]+)"\)\)', keyboard_text):
        shortcuts.append({"id": match[1], "title": match[2], "sourceKey": match[3], "sourceModifiers": match[4], "source": reference(keyboard_path, keyboard_text, match.start()), "windowsBinding": None, "verificationStatus": "pending"})

    cap_path = ROOT / "Veo/Models/CodexAppServerCapabilities.swift"
    cap_text = sources[cap_path]
    body = cap_text.split("enum CodexAppServerCapability:", 1)[1].split("var id:", 1)[0]
    names = re.findall(r"^    case (\w+)$", body, re.M)
    experimental_body = cap_text.split("var maturity:", 1)[1].split("default:", 1)[0]
    experimental = set(re.findall(r"\.(\w+)", experimental_body))
    workflow_body = cap_text.split("var requiresAllMethods:", 1)[1].split("default:", 1)[0]
    workflows = set(re.findall(r"\.(\w+)", workflow_body))
    method_body = cap_text.split("var methods:", 1)[1].split("/// Some capabilities", 1)[0]
    methods = {}
    for match in re.finditer(r"case \.(\w+):\s*return \[(.*?)\]", method_body, re.S):
        methods[match[1]] = re.findall(r'"([^"]+)"', match[2])
    capabilities = [{"name": name, "source": reference(cap_path, cap_text, cap_text.index("case " + name)), "maturity": "experimental" if name in experimental else "stable", "requiresAllMethods": name in workflows, "methods": methods.get(name, []), "windowsSchemaAvailability": "not-yet-verified", "verificationStatus": "pending"} for name in names]

    document = {
        "schemaVersion": 1,
        "upstream": "https://github.com/itsasheruwu/Veo",
        "baselineCommit": BASELINE,
        "extraction": "Literal Swift source evidence; dynamic actions and defaults require review. Null Windows mappings mean unimplemented or unaudited, never supported.",
        "counts": {"swiftFiles": len(sources), "preferences": len(preferences), "slashCommands": len(commands), "keyboardCommands": len(shortcuts), "capabilities": len(capabilities), "uiActionSites": len(actions), "persistenceSites": len(persistence)},
        "preferences": preferences,
        "slashCommands": commands,
        "keyboardCommands": shortcuts,
        "capabilities": capabilities,
        "uiActionInventory": actions,
        "persistenceSites": persistence,
    }
    (OUT / "source-manifest.json").write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(document["counts"]))


def category_for(key, refs):
    lower = key.lower()
    if ".browser." in lower:
        return "Browser"
    if ".updates." in lower:
        return "Updates"
    if "notification" in lower:
        return "Notifications"
    if "agentcli" in lower or "terminal" in lower:
        return "Terminal"
    if "keybinding" in lower:
        return "Keyboard Shortcuts"
    if "project" in lower or "worktree" in lower:
        return "Projects"
    if any("AppearancePreferences" in r or "ComposerPreferences" in r for r in refs):
        return "Appearance"
    if any(s in lower for s in ("approval", "dynamictool", "queue", "protocol")):
        return "Runtime"
    return "General"


def command_route(category):
    return {"Appearance": "/appearance", "Browser": "/browser", "Runtime": "/runtime", "Terminal": "/terminal"}.get(category)


if __name__ == "__main__":
    main()
