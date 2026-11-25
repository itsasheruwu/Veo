"use strict";
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { execFile } = require("node:child_process");
const crypto = require("node:crypto");
const { pipeline } = require("node:stream/promises");
const execute = require("node:util").promisify(execFile);
const agents = require("./VeoAgents.json");
const registryURL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";
const codex = { id: "codex", command: "codex" };
const win = process.platform === "win32";

async function readJSON(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(7000) });
  if (!response.ok) throw Error("Version service returned " + response.status);
  return response.json();
}

function version(text) {
  return String(text).match(/(?:^|[^\w.])v?(\d+\.\d+\.\d+(?:-[\w.-]+)?)(?![\w.])/)?.[1];
}

function currentVersion(installed, latest) {
  const [localCore, localPre] = installed.split(/-(.*)/s);
  const [remoteCore, remotePre] = latest.split(/-(.*)/s);
  const a = localCore.split(".").map(Number), b = remoteCore.split(".").map(Number);
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] > b[i];
  if (!localPre || !remotePre) return !localPre;
  return localPre.localeCompare(remotePre, "en", { numeric: true }) >= 0;
}

function globalPackage(binary) {
  // Match the actual global npm install tree containing the selected executable.
  let target = fs.realpathSync(binary);
  if (win && /\.cmd$/i.test(target)) {
    const entry = fs.readFileSync(target, "utf8").match(/"%dp0%[\\/]node_modules[\\/]([^"\r\n]+)"/i)?.[1];
    if (!entry) return;
    target = path.resolve(path.dirname(binary), "node_modules", entry);
  }
  const parts = target.split(path.sep);
  const index = parts.indexOf("node_modules");
  if (index < 1 || (!win && parts[index - 1] !== "lib")) return;
  const end = index + (parts[index + 1]?.startsWith("@") ? 3 : 2);
  const root = parts.slice(0, end).join(path.sep);
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
    if (pkg.name !== parts.slice(index + 1, end).join("/") || !version(pkg.version)) return;
    const prefix = parts.slice(0, win ? index : index - 1).join(path.sep);
    if (win && !prefix.toLowerCase().startsWith((process.env.APPDATA || "invalid").toLowerCase() + path.sep) &&
        path.resolve(path.dirname(binary)) !== path.resolve(prefix)) return;
    const npmCLI = [path.join(path.dirname(process.execPath), "node_modules/npm/bin/npm-cli.js"),
      path.resolve(path.dirname(process.execPath), "../lib/node_modules/npm/bin/npm-cli.js"),
      path.join(prefix, win ? "" : "lib", "node_modules/npm/bin/npm-cli.js")].find(fs.existsSync);
    if (npmCLI) return { name: pkg.name, version: pkg.version, prefix, npmCLI };
  } catch {}
}

function homebrewPackage(binary) {
  if (process.platform !== "darwin") return;
  const pathParts = fs.realpathSync(binary).split(path.sep);
  const owner = pathParts.findIndex(part => part === "Caskroom" || part === "Cellar");
  if (owner < 1) return;
  const name = pathParts[owner + 1];
  if (!/^[a-z0-9@+._-]+$/.test(name || "")) return;
  const kind = pathParts[owner] === "Cellar" ? "formula" : "cask";
  const brew = path.join(pathParts.slice(0, owner).join(path.sep), "bin", "brew");
  if (fs.existsSync(brew)) return { brew, kind, name };
}

function releaseRoot(state) {
  return path.join(path.dirname(state), ".provider-releases", path.basename(state));
}

function selectionKey(selected) {
  return win && selected === "agy_acp_server.par" ? "agy_acp_server" : selected;
}

function managedRelease(state, selected) {
  if (!state) return;
  try {
    const root = fs.realpathSync(releaseRoot(state));
    const release = JSON.parse(fs.readFileSync(path.join(root, "active.json"), "utf8"));
    if (selectionKey(release.selected) === selectionKey(selected) && release.executable.startsWith(root + path.sep) &&
        fs.statSync(release.executable).isFile()) return release;
  } catch {}
}

function within(root, relative) {
  const candidate = path.resolve(root, relative);
  if (!candidate.startsWith(root + path.sep)) throw Error("Invalid provider release path.");
  return candidate;
}

function releaseInstaller(record, state, selected) {
  const arch = { arm64: "aarch64", x64: "x86_64" }[process.arch];
  const platform = (win ? "windows" : process.platform) + "-" + arch;
  const dist = record?.distribution;
  const binary = dist?.binary?.[platform];
  const checked = binary?.archive?.startsWith("https://") &&
    /^[a-f0-9]{64}$/i.test(binary.sha256 || "") && binary.cmd;
  const npm = dist?.npx?.package;
  const packageName = npm?.match(/^((?:@[a-z0-9_.-]+\/)?[a-z0-9_.-]+)@\d[0-9A-Za-z.+-]*$/)?.[1];
  let npmCLI;
  if (!checked && packageName) {
    npmCLI = [
      path.join(path.dirname(process.execPath), "node_modules/npm/bin/npm-cli.js"),
      path.resolve(path.dirname(process.execPath), "../lib/node_modules/npm/bin/npm-cli.js"),
    ].find(fs.existsSync);
  }
  if (!state || (!checked && !npmCLI)) return;
  return async () => {
    fs.mkdirSync(releaseRoot(state), { recursive: true });
    const root = fs.realpathSync(releaseRoot(state));
    const stage = fs.mkdtempSync(path.join(root, "release-"));
    const pending = path.join(stage, "active.json");
    try {
      let executable;
      let launchWithNode = false;
      const distribution = checked ? binary : dist.npx;
      if (checked) {
        const asset = path.join(stage, "download");
        const response = await fetch(binary.archive, { signal: AbortSignal.timeout(120000) });
        if (!response.ok || !response.body) throw Error("Provider download failed (" + response.status + ").");
        await pipeline(response.body, fs.createWriteStream(asset, { flags: "wx" }));
        const hash = crypto.createHash("sha256");
        for await (const chunk of fs.createReadStream(asset)) hash.update(chunk);
        if (hash.digest("hex") !== binary.sha256.toLowerCase()) throw Error("Provider download checksum mismatch.");
        executable = within(stage, binary.cmd);
        const fd = fs.openSync(asset, "r");
        const header = Buffer.alloc(4);
        try { fs.readSync(fd, header, 0, header.length); } finally { fs.closeSync(fd); }
        const raw = win ? header.subarray(0, 2).toString() === "MZ"
          : ["cffaedfe", "feedfacf", "cafebabe", "cafebabf"].includes(header.toString("hex"));
        if (raw) {
          fs.mkdirSync(path.dirname(executable), { recursive: true });
          fs.renameSync(asset, executable);
        } else {
          const tar = win ? path.join(process.env.SystemRoot || "C:/Windows", "System32/tar.exe") : "/usr/bin/tar";
          const unpacked = path.join(stage, "files");
          fs.mkdirSync(unpacked);
          await execute(tar, ["-xf", asset, "-C", unpacked], updateOptions);
          executable = within(unpacked, binary.cmd);
          fs.unlinkSync(asset);
        }
        executable = fs.realpathSync(executable);
        within(stage, executable);
        if (!fs.statSync(executable).isFile()) throw Error("The release executable is missing.");
        if (!win) fs.chmodSync(executable, 0o755);
      } else {
        await execute(process.execPath, [npmCLI, "install", "--prefix", stage, "--no-audit",
          "--no-fund", "--registry=https://registry.npmjs.org", npm], updateOptions);
        const packageRoot = path.join(stage, "node_modules", packageName);
        const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8"));
        const entries = typeof manifest.bin === "string" ? [manifest.bin] : Object.values(manifest.bin || {});
        const entry = manifest.bin?.[path.basename(selected)] ?? (entries.length === 1 ? entries[0] : null);
        if (!entry) throw Error("The package has no matching provider command.");
        executable = fs.realpathSync(within(packageRoot, entry));
        within(stage, executable);
        launchWithNode = /\.(?:[cm]?js)$/i.test(executable) ||
          fs.readFileSync(executable).subarray(0, 80).toString().startsWith("#!/usr/bin/env node");
      }
      fs.writeFileSync(pending, JSON.stringify({
        selected, executable, launchWithNode, version: version(record.version),
        args: distribution.args, environment: distribution.env,
      }), { mode: 0o600 });
      fs.renameSync(pending, path.join(root, "active.json"));
    } catch (error) {
      fs.rmSync(stage, { recursive: true, force: true });
      throw error;
    }
  };
}

async function inspect(agent, override, find, registry, state) {
  const command = agent.platformCommands?.[process.platform + "-" + process.arch] || agent.command;
  const selected = override || (agent === codex ? process.env.CODEX_EXECUTABLE : null) || agent.command;
  if (!selected) return { state: "manual", detail: "Managed by the owner of the local executable." };
  const managed = managedRelease(state, selected);
  const registryRelease = async () => (await registry())?.agents?.find(entry => entry.id === agent.id);
  const lookup = selected === agent.command ? command : selected;
  let binary;
  try { binary = find(selectionKey(lookup)); }
  catch {
    if (!managed) {
      const record = agent === codex ? null : await registryRelease();
      const latest = version(record?.version || "");
      const apply = latest && releaseInstaller(record, state, selected);
      return apply ? { state: "install", detail: "Install " + latest + " in Veo, then connect to the provider.", apply }
        : { state: "missing", detail: "No compatible in-app installer is available." };
    }
    binary = managed.executable;
  }
  const expected = path.basename(command || "").replace(/\.(exe|cmd|bat)$/i, "");
  const actual = path.basename(binary).replace(/\.(exe|cmd|bat)$/i, "");
  let standard;
  try { standard = fs.realpathSync(find(selectionKey(command))); } catch {}
  const customized = agent !== codex && override && standard !== fs.realpathSync(binary);
  const conventional = !customized && (actual === expected || (win && expected === actual + ".par"));
  if (agent !== codex && (managed || !conventional)) {
    const record = await registryRelease();
    const latest = version(record?.version || "");
    if (managed?.version && latest && currentVersion(managed.version, latest))
      return { state: "current", detail: "Installed " + managed.version };
    const apply = latest && releaseInstaller(record, state, selected);
    return apply ? { state: "available", detail: "Install " + latest + " and use it in Veo.", apply }
      : { state: "manual", detail: "There is no supported in-app release for this installation." };
  }
  const brew = homebrewPackage(binary);
  const pkg = !brew && globalPackage(binary);
  let installed = pkg?.version;
  if (!installed && !/\.(cmd|bat)$/i.test(binary)) {
    try {
      const result = await execute(binary, ["--version"], { cwd: os.homedir(), windowsHide: true, timeout: 4500, maxBuffer: 65536 });
      installed = version(result.stdout) || version(result.stderr);
    } catch {}
  }

  const name = pkg?.name || (agent === codex ? "@openai/codex" : null);
  if (agent.id === "fx" && pkg) return { state: "manual", detail: "Confirm this installation is the fx coding agent." };
  let record;
  if (brew) {
    const info = await readJSON("https://formulae.brew.sh/api/" + brew.kind + "/" + brew.name + ".json");
    record = { version: info.version || info.versions?.stable };
  } else if (agent.id === "fx") {
    const response = await fetch("https://releases.fx.sh/latest.txt", { signal: AbortSignal.timeout(7000) });
    if (!response.ok) throw Error("The fx release service is unavailable.");
    record = { version: (await response.text()).trim() };
  } else record = name ? await readJSON("https://registry.npmjs.org/" + encodeURIComponent(name) + "/latest")
    : await registryRelease();
  const latest = version(record?.version || "");
  const fallback = async () => {
    if (agent === codex) return;
    const release = await registryRelease();
    const releaseVersion = version(release?.version || "");
    const apply = releaseVersion && releaseInstaller(release, state, selected);
    if (apply) return { state: "available", detail: "Install " + releaseVersion + " and use it in Veo.", apply };
  };
  if (!installed || !latest) return await fallback() || { state: "manual", detail: "Installed " + installed + ". No comparable release version is published." };
  const detail = "Installed " + installed + " · Latest " + latest;
  const comparable = agent.id === "cursor" && /^\d{4}\./.test(installed) ? installed.split("-")[0] : installed;
  if (currentVersion(comparable, latest)) return { state: "current", detail };
  if (brew) return { state: "available", detail, apply: () => execute(brew.brew,
    ["upgrade", "--" + brew.kind, brew.name], updateOptions) };
  if (pkg) return { state: "available", detail, apply: () => execute(process.execPath,
    [pkg.npmCLI, "install", "--global", "--prefix", pkg.prefix, pkg.name + "@" + latest], updateOptions) };
  const args = { codex: ["update"], "opencode-v2": ["upgrade"], cursor: ["update"], kiro: ["update"], fx: ["upgrade"] }[agent.id];
  if (args) return { state: "available", detail, apply: () => execute(binary, args, updateOptions) };
  return await fallback() || { state: "manual", detail: detail + ". No supported in-app installer was found." };
}
const updateOptions = { cwd: os.homedir(), windowsHide: true, timeout: 180000, maxBuffer: 512 * 1024 };

async function providerUpdates(request, find) {
  let pending;
  const registry = () => pending ??= readJSON(registryURL);
  const options = [codex, ...agents];
  const result = {};
  if (request.action === "updateProvider") {
    const agent = options.find(agent => agent.id === request.provider);
    if (!agent) throw Error("Unknown provider.");
    const check = await inspect(agent, request.executables?.[agent.id], find, registry, request.stateRoot && path.join(request.stateRoot, agent.id));
    if (check.apply) {
      const updating = check.apply();
      updating.child?.stdin?.end();
      await updating;
      // Codex standalone may switch its current release directory. The native
      // caller re-resolves the executable when checking after the update.
    } else if (check.state !== "current") {
      throw Error(check.detail);
    }
    return { done: true, updates: { [agent.id]: { state: check.state, detail: check.detail } } };
  }
  await Promise.all(options.map(async agent => {
    try {
      const { state, detail } = await inspect(agent, request.executables?.[agent.id], find, registry, request.stateRoot && path.join(request.stateRoot, agent.id));
      result[agent.id] = { state, detail };
    } catch { result[agent.id] = { state: "retry", detail: "Could not check the latest release. Try again." }; }
  }));
  result["custom-acp"] = { state: "manual", detail: "Managed by the owner of the local executable." };
  return { done: true, updates: result };
}

module.exports = Object.assign(providerUpdates, { managedRelease });
