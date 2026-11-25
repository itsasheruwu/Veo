// Native clients send one JSON request, then permission choices, on stdin.
// Provider stdio is reserved for ACP. Nothing here starts a T3 service.
"use strict";
const fs = require("node:fs");
const os = require("node:os");
const crypto = require("node:crypto");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { createInterface } = require("node:readline");
// Some vendor installations expose only a .cmd launcher. Start that launcher inside
// the same sandbox, with literal arguments and shell expansions disabled.
if (process.platform === "win32" && process.argv[2] === "--windows-wrapper") {
  const values = process.argv.slice(3);
  if (
    !values.length ||
    !values.every((v) => /^[a-zA-Z0-9_.,:/@=+ \\\-]*$/.test(v))
  ) {
    process.stderr.write(
      "Choose the native executable for arguments containing shell metacharacters.",
    );
    process.exit(1);
  }
  const command = '"' + values.map((v) => '"' + v + '"').join(" ") + '"';
  const shell = path.join(
    process.env.SystemRoot || "C:\\Windows",
    "System32",
    "cmd.exe",
  );
  const wrapper = spawn(shell, ["/d", "/v:off", "/s", "/c", command], {
    stdio: "inherit",
    windowsHide: true,
    windowsVerbatimArguments: true,
  });
  wrapper.on("error", (e) => {
    process.stderr.write(e.message);
    process.exit(1);
  });
  wrapper.on("exit", (code) => process.exit(code ?? 1));
  return;
}
const catalog = require("./VeoAgents.json");
const emit = (event) => process.stdout.write(JSON.stringify(event) + "\n");
const pending = new Map();
const permissions = new Map();
let child,
  sequence = 0,
  session,
  reply = "",
  started = false,
  finished = false,
  prompting = false;
function finish(event) {
  if (finished) return;
  finished = true;
  if (child && !child.killed) child.kill();
  emit(event);
  process.stdout.write("", () => process.exit(event.error ? 1 : 0));
}
function fail(error) {
  finish({ error: String(error.message || error) });
}
process.on("SIGTERM", () => finish({ error: "Stopped." }));
process.on("uncaughtException", fail);
function executable(name) {
  const dirs = (process.env.PATH || "")
    .split(path.delimiter)
    .filter((p) => path.isAbsolute(p));
  if (process.platform !== "win32")
    dirs.push(
      "/opt/homebrew/bin",
      "/usr/local/bin",
      path.join(os.homedir(), ".local/bin"),
      path.join(os.homedir(), ".grok/bin"),
      path.join(os.homedir(), ".opencode/bin"),
    );
  const names = path.isAbsolute(name)
    ? [name]
    : dirs.flatMap((dir) =>
        (process.platform === "win32"
          ? [".exe", ".cmd", ".bat", ""]
          : [""]
        ).map((ext) => path.join(dir, name + ext)),
      );
  for (const file of names) {
    try {
      fs.accessSync(file, fs.constants.X_OK);
      if (fs.statSync(file).isFile()) return file;
    } catch {}
  }
  throw Error(
    "Install " + name + " or choose the installed ACP executable in Providers.",
  );
}
function write(message) {
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
}
function rpc(method, params, timeout = 45000) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer =
      timeout &&
      setTimeout(() => {
        pending.delete(id);
        reject(Error(method + " timed out."));
      }, timeout);
    pending.set(id, (msg) => {
      clearTimeout(timer);
      if (msg.error)
        reject(
          Object.assign(
            Error(
              msg.error.data?.details
                ? msg.error.message +
                    ": " +
                    String(msg.error.data.details).slice(0, 350)
                : msg.error.message,
            ),
            { code: msg.error.code },
          ),
        );
      else resolve(msg.result || {});
    });
    write({ id, method, params });
  });
}
function receive(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (!msg.method) {
    const cb = pending.get(msg.id);
    pending.delete(msg.id);
    cb?.(msg);
    return;
  }
  const p = msg.params || {};
  if (
    msg.method === "session/update" &&
    (!session || p.sessionId === session)
  ) {
    const update = p.update || {};
    if (
      prompting &&
      update.sessionUpdate === "agent_message_chunk" &&
      update.content?.type === "text"
    ) {
      reply += update.content.text;
      emit({ delta: update.content.text });
    }
  } else if (msg.method === "session/request_permission" && msg.id != null) {
    const option = p.options?.find((o) => o.kind === "allow_once");
    if (option && session && session === p.sessionId) {
      permissions.set(String(msg.id), { id: msg.id, option: option.optionId });
      emit({
        permission: String(msg.id),
        title: p.toolCall?.title || "Allow this provider action?",
      });
    } else write({ id: msg.id, result: { outcome: { outcome: "cancelled" } } });
  } else if (msg.id != null)
    write({
      id: msg.id,
      error: { code: -32601, message: "Client capability unavailable" },
    });
}
function selectOptions(options) {
  return (options || []).flatMap(option =>
    option.options ? selectOptions(option.options) :
      typeof option.value === "string" ? [{ id: option.value, name: option.name || option.value }] : []
  );
}

function thoughtControl(options) {
  return options?.find(option => option.type === "select" &&
    (option.category === "thought_level" || option.id === "reasoning_effort"));
}

function modelOptions(s) {
  const option = s.configOptions?.find(o => o.category === "model" || o.id === "model");
  const thought = thoughtControl(s.configOptions);
  const available = s.models?.availableModels || [];
  const current = option?.currentValue || s.models?.currentModelId || "";
  const list = option ? selectOptions(option.options)
    : available.map(model => ({ id: model.modelId, name: model.name || model.modelId }));
  const models = list.filter(model => typeof model.id === "string" && model.id).map(model => {
    const meta = available.find(source => source.modelId === model.id)?._meta;
    const advertised = meta?.reasoningEfforts;
    const efforts = advertised ? selectOptions(advertised.map(effort => ({
      value: effort.value || effort.id, name: effort.label || effort.name
    }))) : model.id === current ? selectOptions(thought?.options) : [];
    const defaultEffort = advertised?.find(effort => effort.default);
    return { ...model, efforts: advertised || model.id === current ? efforts.reverse() : undefined,
      defaultEffort: defaultEffort?.value || defaultEffort?.id || (model.id === current ? thought?.currentValue : undefined) };
  });
  return { option, models, current };
}
async function run(q) {
  if (q.action === "checkProviderUpdates" || q.action === "updateProvider") {
    finish(await require("./veo-provider-updates.cjs")(q, executable));
    return;
  }
  const agent =
    catalog.find((a) => a.id === q.provider) ||
    (q.provider === "custom-acp" && { command: "", args: [] });
  if (!agent) throw Error("Unknown provider.");
  const selected = q.executable || agent.command;
  const managed = require("./veo-provider-updates.cjs").managedRelease(q.state, selected);
  let cmd = selected;
  if (cmd === agent.command)
    cmd =
      agent.platformCommands?.[process.platform + "-" + process.arch] || cmd;
  if (process.platform === "win32" && cmd === "agy_acp_server.par")
    cmd = "agy_acp_server";
  let bin = executable(managed?.executable || cmd);
  let prefix = [];
  let wrapperPath;
  if (managed?.launchWithNode) {
    prefix = [bin];
    bin = process.execPath;
  } else if (process.platform === "win32" && /\.(cmd|bat)$/i.test(bin)) {
    // Resolve standard npm shims to their package's actual entry point. No shell parses user arguments.
    const npmDir = path.join(path.dirname(bin), "node_modules");
    const wrapper = fs.readFileSync(bin, "utf8");
    const match = wrapper.match(/"%dp0%[\\/]node_modules[\\/]([^"\r\n]+)"/i);
    if (match) {
      const entry = path.resolve(npmDir, match[1]);
      if (
        !entry.startsWith(path.resolve(npmDir) + path.sep) ||
        !fs.existsSync(entry)
      )
        throw Error("Invalid provider entry point.");
      const nativeOpenCode = path.join(
        npmDir,
        "opencode-ai",
        "node_modules",
        "opencode-windows-" + process.arch,
        "bin",
        "opencode.exe",
      );
      if (agent.id === "opencode-v2" && fs.existsSync(nativeOpenCode))
        bin = nativeOpenCode;
      else {
        prefix = [entry];
        bin = process.execPath;
      }
    } else {
      wrapperPath = bin;
      prefix = [__filename, "--windows-wrapper", bin];
      bin = process.execPath;
    }
  } else if (/\.(?:c?js|mjs)$/i.test(bin)) {
    prefix = [bin];
    bin = process.execPath;
  }
  const defaultArgs = !q.args || JSON.stringify(q.args) === JSON.stringify(agent.args);
  const args = (defaultArgs ? managed?.args : undefined) ?? q.args ?? agent.args;
  if (!Array.isArray(args) || !args.every((v) => typeof v === "string"))
    throw Error("Enter one argument per line.");
  const cwd = fs.realpathSync(q.cwd);
  const env = { ...process.env, ...agent.environment, ...managed?.environment };
  const codex = executable(process.env.CODEX_EXECUTABLE || "codex");
  const fsRules = { ":root": "read" };
  if (q.access !== "readOnly") fsRules[cwd] = "write";
  // Provider state is private to this connection. Never widen a failed sandbox.
  const state = fs.realpathSync(q.state);
  fsRules[state] = "write";
  const vendorData = {
    "opencode-v2": [".local/share/opencode", ".local/state/opencode"],
    cursor: [
      ".cursor/acp-sessions",
      ".cursor/chats",
      ".cursor/projects",
      ".cursor/cli-config.json",
      ".cursor/agent-cli-state.json",
      ".local/share/cursor-agent",
      ".config/cursor",
    ],
    "grok-build": [".grok"],
    "claude-acp": [".claude/projects", ".claude/debug"],
    "pi-acp": [".pi/agent/sessions"],
    kiro: [".kiro/sessions"],
    "muse-code": [".muse"],
    fx: [".fx"],
    "antigravity-acp": [".gemini/antigravity"],
  };
  for (const rel of vendorData[q.provider] || []) {
    const dir = path.join(os.homedir(), rel);
    if (
      !fs.existsSync(dir) &&
      fs.existsSync(path.dirname(dir)) &&
      fs.realpathSync(path.dirname(dir)) === path.dirname(dir) &&
      !path.extname(dir)
    ) {
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    }
    if (fs.existsSync(dir) && fs.realpathSync(dir) === dir)
      fsRules[dir] = "write";
  }
  env.TMPDIR = env.TEMP = env.TMP = state;
  env.XDG_CACHE_HOME = path.join(state, "cache");
  if (process.platform === "win32") {
    fsRules[path.dirname(bin)] = "read";
    if (prefix.length) fsRules[path.dirname(prefix[0])] = "read";
    if (wrapperPath) fsRules[path.dirname(wrapperPath)] = "read";
  }
  const rules = Object.entries(fsRules)
    .map(([k, v]) => JSON.stringify(k) + "=" + JSON.stringify(v))
    .join(",");
  const config =
    "permissions.veo_agent={filesystem={" + rules + "},network={enabled=true}}";
  // GUI children inherit the user's restricted token on Windows. This preserves stdio
  // and access to user-installed executables with the same explicit filesystem rules.
  const platformArgs =
    process.platform === "win32" ? ["-c", 'windows.sandbox="unelevated"'] : [];
  const argv = [
    "sandbox",
    ...platformArgs,
    "-P",
    "veo_agent",
    "-c",
    config,
    "-C",
    cwd,
    "--",
    bin,
    ...prefix,
    ...args,
  ];
  child = spawn(codex, argv, {
    cwd,
    env,
    windowsHide: true,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let diagnostic = "";
  child.stderr.on("data", (b) => {
    diagnostic = (diagnostic + b).slice(-1500);
  });
  child.on("error", fail);
  child.on("exit", () => {
    if (finished) return;
    if (process.platform === "win32" && agent.id === "opencode-v2" && /EPERM.*uv_spawn/i.test(diagnostic)) {
      fail(Error("OpenCode could not start its server inside the Windows workspace sandbox. In Providers, choose an OpenCode 1.18.23 executable and reconnect."));
      return;
    }
    fail(Error(diagnostic.trim() || "Provider exited before completing the request."));
  });
  child.stdin.on("error", fail);
  createInterface({ input: child.stdout }).on("line", receive);
  const hello = await rpc("initialize", {
    protocolVersion: 2,
    clientCapabilities: {},
    clientInfo: { name: "Veo", version: "1" },
  });
  const base = { cwd, mcpServers: [] };
  const digest = (value) =>
    crypto.createHash("sha256").update(JSON.stringify(value)).digest("hex");
  const historyKey = (rows) => digest(rows.map((r) => [r.role, r.text]));
  const historyRows = q.history || [];
  const binding =
    q.thread &&
    path.join(state, "session-" + digest([q.thread, cwd, cmd, args]) + ".json");
  let previous;
  if (binding && q.action === "turn" && fs.existsSync(binding)) {
    try {
      const saved = JSON.parse(fs.readFileSync(binding, "utf8"));
      if (
        saved.history === historyKey(historyRows) &&
        (q.model || !saved.model)
      )
        previous = saved.session;
    } catch {}
  }
  let s;
  if (previous && hello.agentCapabilities?.loadSession) {
    try {
      s = await rpc("session/load", { ...base, sessionId: previous });
      session = previous;
    } catch (e) {
      if (e.code !== -32002 && !/session.*(not found|unknown)/i.test(e.message))
        throw e;
    }
  }
  if (!s) {
    try {
      s = await rpc("session/new", base);
    } catch (e) {
      const auth = hello.authMethods?.find(
        (a) => !a.type || a.type === "agent",
      );
      if (e.code !== -32000 || q.action !== "connect" || !auth) throw e;
      await rpc("authenticate", { methodId: auth.id }, 180000);
      s = await rpc("session/new", base);
    }
    session = s.sessionId;
  }
  if (!session) throw Error("Provider returned no session ID.");
  const m = modelOptions(s);
  if (q.action === "connect" || (q.action === "models" && !q.model)) {
    finish({ connected: true, models: m.models, current: m.current || "" });
    return;
  }
  let configOptions = s.configOptions;
  if (q.model && q.model !== m.current) {
    if (m.option) {
      const changed = await rpc("session/set_config_option", {
        sessionId: session,
        configId: m.option.id,
        value: q.model,
      });
      configOptions = changed.configOptions ?? configOptions;
    } else {
      const changed = await rpc("session/set_model", { sessionId: session, modelId: q.model });
      configOptions = changed.configOptions ?? configOptions;
    }
  }
  if (q.action === "models") {
    const updated = modelOptions({ ...s, configOptions,
      models: { ...s.models, currentModelId: q.model } });
    finish({ connected: true, models: updated.models, current: updated.current });
    return;
  }
  const thought = thoughtControl(configOptions);
  if (q.effort && thought && selectOptions(thought.options).some(option => option.id === q.effort)) {
    await rpc("session/set_config_option", { sessionId: session, configId: thought.id, value: q.effort });
  }
  emit({ session });
  const history = previous === session ? [] : historyRows;
  prompting = true;
  const prompt = history.length
    ? [
        {
          type: "text",
          text:
            "Prior conversation in this Veo chat:\n" + JSON.stringify(history),
        },
        { type: "text", text: q.text },
      ]
    : [{ type: "text", text: q.text }];
  const result = await rpc("session/prompt", { sessionId: session, prompt }, 0);
  if (binding && reply) {
    const scratch = binding + "." + process.pid + ".tmp";
    fs.writeFileSync(
      scratch,
      JSON.stringify({
        session,
        model: q.model,
        history: historyKey([
          ...historyRows,
          { role: "user", text: q.text },
          { role: "assistant", text: reply },
        ]),
      }),
      { mode: 0o600 },
    );
    fs.renameSync(scratch, binding);
  }
  finish({ done: true, session, text: reply, reason: result.stopReason });
}
const input = createInterface({ input: process.stdin });
input.on("line", (line) => {
  try {
    const q = JSON.parse(line);
    if (!started) {
      started = true;
      run(q).catch(fail);
      return;
    }
    const p = permissions.get(q.permission);
    if (p) {
      permissions.delete(q.permission);
      write({
        id: p.id,
        result: {
          outcome: q.allow
            ? { outcome: "selected", optionId: p.option }
            : { outcome: "cancelled" },
        },
      });
    }
  } catch (e) {
    fail(e);
  }
});
input.on("close", () => {
  if (!finished) finish({ error: "Connection closed." });
});
