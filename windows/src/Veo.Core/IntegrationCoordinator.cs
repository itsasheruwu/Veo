using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Veo.Protocol;

namespace Veo.Core;

/// <summary>Typed runtime-owned integration workflows. Mutations are explicit, serialized and followed by inventory readback.</summary>
public sealed class IntegrationCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly SemaphoreSlim mutations = new(1, 1);
    readonly ConcurrentDictionary<string, IntegrationSnapshot> snapshots = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, ExternalImportItem[]> imports = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, ExternalImportProgress> progress = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, IntegrationOAuthSession> oauth = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, (bool IncludeHome, string? Source)> detections = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, string> activeImports = new(StringComparer.Ordinal);
    bool disposed;
    public event Action? Changed;
    public event Action<Uri>? Navigate;
    public string? LastMessage { get; private set; }
    public IntegrationCoordinator(WorkspaceCoordinator workspace) { this.workspace = workspace; workspace.RuntimeEventReceived += OnEvent; }
    public IntegrationSnapshot Snapshot(IntegrationContext context) => snapshots.GetValueOrDefault(context.Key) ?? IntegrationSnapshot.Empty;
    public IReadOnlyList<ExternalImportItem> ImportItems(IntegrationContext context) => imports.GetValueOrDefault(context.Key) ?? [];
    public ExternalImportProgress? ImportProgress(string id) => progress.GetValueOrDefault(id);
    public IntegrationOAuthSession? OAuth(string name) => oauth.GetValueOrDefault(name);
    public bool Available(string method) => workspace.Runtime.Capabilities.Availability(method) != CapabilityAvailability.Unavailable;
    async Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken cancellation, int seconds = 30)
    { using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromSeconds(seconds)); return await workspace.Runtime.RequestAsync(method, parameters, timeout.Token); }

    public async Task<IntegrationSnapshot> RefreshAsync(IntegrationContext context, CancellationToken cancellation = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var issues = new ConcurrentBag<IntegrationIssue>();
        async Task<T> Read<T>(string method, Func<Task<T>> read, T empty)
        {
            try { return await read(); }
            catch (Exception exception) when (exception is not OperationCanceledException || !cancellation.IsCancellationRequested)
            { issues.Add(new(method, DiagnosticRedactor.Redact(exception.Message), exception is NotSupportedException || exception is CodexRpcException { Code: -32601 })); return empty; }
        }
        var skillTask = Read("skills/list", () => ReadSkillsAsync(context, false, cancellation), Array.Empty<SkillIntegration>());
        var pluginsTask = Read("plugin/list", () => ReadPluginsAsync(context, false, cancellation), Array.Empty<MarketplaceIntegration>());
        var appsTask = Read("app/list", () => ReadAppsAsync(context, cancellation), Array.Empty<AppIntegration>());
        var mcpTask = Read("mcpServerStatus/list", () => ReadMcpAsync(context, cancellation), Array.Empty<McpServerIntegration>());
        await Task.WhenAll(skillTask, pluginsTask, appsTask, mcpTask);
        var snapshot = new IntegrationSnapshot(await skillTask, await pluginsTask, await appsTask, await mcpTask, issues.ToArray()); snapshots[context.Key] = snapshot; Changed?.Invoke(); return snapshot;
    }
    async Task<SkillIntegration[]> ReadSkillsAsync(IntegrationContext context, bool force, CancellationToken cancellation)
    {
        if (context.Cwd is null) return [];
        var response = await RequestAsync("skills/list", new { cwds = new[] { context.Cwd }, forceReload = force }, cancellation);
        return Rows(response, "data").Where(entry => entry.Str("cwd") == context.Cwd).SelectMany(entry => Rows(entry, "skills")).Where(item => item.Str("name") is not null).Select(item =>
        {
            var metadata = item.TryObjectProperty("interface", out var value) ? value : default;
            return new SkillIntegration(item.Str("path") ?? item.Str("name")!, item.Str("name")!, metadata.Str("displayName") ?? item.Str("name")!, metadata.Str("shortDescription") ?? item.Str("description") ?? "", item.Str("path"), item.Str("scope") ?? "unknown", Bool(item, "enabled", true), item.Clone());
        }).DistinctBy(x => x.Id, StringComparer.Ordinal).ToArray();
    }
    public async Task<SkillIntegration[]> RefreshSkillsAsync(IntegrationContext context, CancellationToken cancellation = default)
    { var skills = await ReadSkillsAsync(context, false, cancellation); snapshots[context.Key] = Snapshot(context) with { Skills = skills }; Changed?.Invoke(); return skills; }
    public async Task<IReadOnlyList<PluginIntegration>> RefreshMentionablePluginsAsync(IntegrationContext context, CancellationToken cancellation = default)
    {
        if (workspace.Runtime.Capabilities.Availability("plugin/list") == CapabilityAvailability.Unavailable) return [];
        var current = await ReadPluginsAsync(context, false, cancellation);
        snapshots[context.Key] = Snapshot(context) with { Marketplaces = current };
        return current.SelectMany(marketplace => marketplace.Plugins).ToArray();
    }

    async Task<MarketplaceIntegration[]> ReadPluginsAsync(IntegrationContext context, bool force, CancellationToken cancellation)
    {
        var response = await RequestAsync("plugin/list", new { cwds = context.Cwd is null ? Array.Empty<string>() : new[] { context.Cwd }, forceRefetch = force }, cancellation);
        var loadErrors = Rows(response, "marketplaceLoadErrors");
        if (loadErrors.Length > 0) LastMessage = string.Join("\n", loadErrors.Select(x => x.Str("message") ?? x.Str("marketplaceName") ?? "Marketplace could not load."));
        return Rows(response, "marketplaces").Where(x => x.Str("name") is not null).Select(market => new MarketplaceIntegration(market.Str("name")!, market.Str("path"), market.TryObjectProperty("interface", out var i) ? i.Str("displayName") ?? market.Str("name")! : market.Str("name")!, Rows(market, "plugins").Select(plugin => ParsePlugin(plugin, market.Str("path"), market.Str("name"))).OfType<PluginIntegration>().ToArray())).ToArray();
    }
    static PluginIntegration? ParsePlugin(JsonElement plugin, string? path, string? market)
    {
        if (plugin.Str("id") is not { } id || plugin.Str("name") is not { } name) return null;
        var metadata = plugin.TryObjectProperty("interface", out var value) ? value : default;
        return new(id, name, metadata.Str("displayName") ?? name, metadata.Str("shortDescription") ?? plugin.Str("description") ?? "", Bool(plugin, "installed"), Bool(plugin, "enabled"), plugin.Str("availability") ?? "AVAILABLE", plugin.Str("installPolicy") ?? "NOT_AVAILABLE", new(name, path, market), plugin.Clone());
    }
    async Task<AppIntegration[]> ReadAppsAsync(IntegrationContext context, CancellationToken cancellation)
    {
        var listed = await PagesAsync("app/list", new() { ["threadId"] = context.RuntimeThreadId, ["forceRefetch"] = false }, cancellation);
        JsonElement[] installed = [];
        if (Available("app/installed"))
            try { installed = Rows(await RequestAsync("app/installed", new { threadId = context.RuntimeThreadId, forceRefresh = false }, cancellation), "apps"); }
            catch (CodexRpcException) { }
        return listed.Where(x => x.Str("id") is not null).Select(app =>
        {
            var own = installed.FirstOrDefault(x => x.Str("id") == app.Str("id"));
            return new AppIntegration(app.Str("id")!, app.Str("name") ?? app.Str("id")!, app.Str("description") ?? "", own.ValueKind == JsonValueKind.Object ? Bool(own, "enabled") : Bool(app, "isEnabled", true), Bool(app, "isAccessible"), own.ValueKind == JsonValueKind.Object ? Bool(own, "callable") : null, SecureUri(app.Str("installUrl")), app.Clone());
        }).DistinctBy(x => x.Id, StringComparer.Ordinal).ToArray();
    }
    async Task<McpServerIntegration[]> ReadMcpAsync(IntegrationContext context, CancellationToken cancellation)
    {
        var data = await PagesAsync("mcpServerStatus/list", new() { ["threadId"] = context.RuntimeThreadId, ["detail"] = "full" }, cancellation);
        return data.Where(x => x.Str("name") is not null).Select(server => new McpServerIntegration(server.Str("name")!, server.Str("authStatus") ?? "unknown", server.Str("runtimeStatus") ?? (server.TryObjectProperty("runtimeStatus", out var state) ? state.Str("type") ?? "unknown" : "unknown"), server.Str("toolsError"),
            server.TryObjectProperty("tools", out var tools) ? tools.EnumerateObject().Select(property => property.Value).Where(tool => tool.Str("name") is not null).Select(tool => new McpToolIntegration(tool.Str("name")!, tool.Str("title") ?? tool.Str("name")!, tool.Str("description") ?? "", NativeSchemaForm.Parse(tool.TryGetProperty("inputSchema", out var schema) ? schema : default), tool.Clone())).ToArray() : [],
            Rows(server, "resources").Where(resource => resource.Str("uri") is not null).Select(resource => new McpResourceIntegration(resource.Str("uri")!, resource.Str("title") ?? resource.Str("name") ?? resource.Str("uri")!, resource.Str("mimeType"), resource.Str("description"))).ToArray(),
            Rows(server, "resourceTemplates").Where(template => template.Str("uriTemplate") is not null).Select(template => new McpTemplateIntegration(template.Str("uriTemplate")!, template.Str("title") ?? template.Str("name") ?? "Resource template", template.Str("description"))).ToArray(), server.Clone())).DistinctBy(x => x.Name, StringComparer.Ordinal).ToArray();
    }
    async Task<JsonElement[]> PagesAsync(string method, Dictionary<string, object?> parameters, CancellationToken cancellation)
    {
        var result = new List<JsonElement>(); var seen = new HashSet<string>(StringComparer.Ordinal); string? cursor = null;
        do
        {
            var page = new Dictionary<string, object?>(parameters) { ["limit"] = 100 }; if (cursor is not null) page["cursor"] = cursor;
            var response = await RequestAsync(method, page, cancellation); result.AddRange(Rows(response, "data")); cursor = response.Str("nextCursor");
            if (!string.IsNullOrEmpty(cursor) && !seen.Add(cursor)) throw new InvalidDataException($"{method} repeated a pagination cursor.");
        } while (!string.IsNullOrEmpty(cursor));
        return result.ToArray();
    }
    public async Task SetSkillEnabledAsync(IntegrationContext context, SkillIntegration skill, bool enabled, CancellationToken cancellation = default)
    {
        await mutations.WaitAsync(cancellation);
        try
        {
            if (context.Cwd is null || !Snapshot(context).Skills.Any(x => x.Id == skill.Id)) throw new InvalidOperationException("Select the originating project and refresh its skills.");
            var parameters = new Dictionary<string, object?> { ["enabled"] = enabled, ["name"] = skill.Name }; if (skill.Path is not null) parameters["path"] = skill.Path;
            await RequestAsync("skills/config/write", parameters, cancellation); var skills = await ReadSkillsAsync(context, true, cancellation);
            if (skills.FirstOrDefault(x => x.Id == skill.Id)?.Enabled != enabled) throw new IOException("Codex did not confirm the skill's requested enabled state.");
            snapshots[context.Key] = Snapshot(context) with { Skills = skills }; LastMessage = skill.Title + (enabled ? " enabled." : " disabled.");
        }
        finally { mutations.Release(); Changed?.Invoke(); }
    }
    public async Task<JsonElement> ReadPluginAsync(PluginIntegration plugin, CancellationToken cancellation = default)
    { var result = await RequestAsync("plugin/read", plugin.Selector.Parameters(), cancellation); return result.GetProperty("plugin").Clone(); }
    public async Task SetPluginInstalledAsync(IntegrationContext context, PluginIntegration plugin, bool installed, CancellationToken cancellation = default)
    {
        await mutations.WaitAsync(cancellation);
        try
        {
            if (installed && !plugin.CanInstall) throw new InvalidOperationException("This plugin is not available for installation under current policy.");
            if (!installed && !plugin.Installed) throw new InvalidOperationException("The plugin is not installed.");
            if (installed) await RequestAsync("plugin/install", plugin.Selector.Parameters(), cancellation, 120);
            else await RequestAsync("plugin/uninstall", new { pluginId = plugin.Id }, cancellation, 120);
            var current = await ReadPluginsAsync(context, true, cancellation); snapshots[context.Key] = Snapshot(context) with { Marketplaces = current };
            var found = current.SelectMany(x => x.Plugins).FirstOrDefault(x => x.Id == plugin.Id);
            if (installed && found?.Installed != true || !installed && found?.Installed == true) throw new IOException("Codex did not confirm the plugin's installation state.");
            LastMessage = plugin.Title + (installed ? " installed. Connect any apps listed in its details before using them." : " uninstalled.");
        }
        finally { mutations.Release(); Changed?.Invoke(); }
    }
    public async Task<PluginIntegration[]> SearchPluginsAsync(IntegrationContext context, string term, CancellationToken cancellation = default)
    {
        if (string.IsNullOrWhiteSpace(term)) return [];
        var data = await PagesAsync("plugin/search", new() { ["searchTerm"] = term.Trim(), ["scope"] = "workspace", ["cwds"] = context.Cwd is null ? Array.Empty<string>() : new[] { context.Cwd } }, cancellation);
        return data.Where(row => row.TryObjectProperty("plugin", out _)).Select(row => ParsePlugin(row.GetProperty("plugin"), row.Str("marketplacePath"), row.Str("marketplaceName"))).OfType<PluginIntegration>().DistinctBy(x => x.Id + "|" + x.Selector.MarketplaceName, StringComparer.Ordinal).ToArray();
    }
    public async Task ChangeMarketplaceAsync(IntegrationContext context, string operation, string value, CancellationToken cancellation = default)
    {
        if (string.IsNullOrWhiteSpace(value)) throw new InvalidOperationException("Specify a marketplace source or name.");
        await mutations.WaitAsync(cancellation);
        try
        {
            if (operation is not ("add" or "remove" or "upgrade")) throw new ArgumentException("Unknown marketplace operation.", nameof(operation));
            var result = await RequestAsync("marketplace/" + operation, operation == "add" ? new { source = value.Trim() } : (object)new { marketplaceName = value }, cancellation, 120);
            if (Rows(result, "errors").Length > 0) throw new IOException(string.Join("\n", Rows(result, "errors").Select(x => x.Str("message") ?? "Marketplace update failed.")));
            var current = await ReadPluginsAsync(context, true, cancellation); snapshots[context.Key] = Snapshot(context) with { Marketplaces = current };
            var name = operation == "add" ? result.Str("marketplaceName") ?? value : value;
            if (operation == "add" && !current.Any(x => x.Name == name) || operation == "remove" && current.Any(x => x.Name == name)) throw new IOException("Marketplace inventory did not confirm the requested change.");
            LastMessage = operation == "upgrade" ? "Marketplace update completed and inventory was refreshed." : operation == "add" ? "Marketplace added." : "Marketplace removed.";
        }
        finally { mutations.Release(); Changed?.Invoke(); }
    }
    public async Task<AppIntegration[]> ReadAppDetailsAsync(IntegrationContext context, IReadOnlyList<string> ids, CancellationToken cancellation = default)
    {
        if (ids.Count is < 1 or > 100) throw new ArgumentException("Choose between one and 100 apps.", nameof(ids));
        var response = await RequestAsync("app/read", new { appIds = ids, includeTools = true, threadId = context.RuntimeThreadId }, cancellation);
        return Rows(response, "apps").Select(app =>
        {
            var previous = Snapshot(context).Apps.FirstOrDefault(x => x.Id == app.Str("id"));
            return new AppIntegration(app.Str("id")!, app.Str("name") ?? app.Str("id")!, app.Str("description") ?? "", previous?.Enabled ?? false, previous?.Accessible ?? false, previous?.Callable, SecureUri(app.Str("installUrl")), app.Clone());
        }).ToArray();
    }
    public void OpenAppConnection(AppIntegration app)
    {
        if (!app.Enabled || app.Accessible || app.InstallUrl is null) throw new InvalidOperationException("This app did not supply an available secure connection URL.");
        Navigate?.Invoke(app.InstallUrl); LastMessage = "Complete the connection in Veo's browser, then refresh Apps to verify it.";
    }
    public async Task StartMcpOAuthAsync(IntegrationContext context, string name, CancellationToken cancellation = default)
    {
        var response = await RequestAsync("mcpServer/oauth/login", new { name, threadId = context.RuntimeThreadId, timeoutSecs = 300 }, cancellation);
        var url = SecureUri(response.Str("authorizationUrl")) ?? throw new InvalidDataException("The MCP server did not provide a secure authorization URL.");
        oauth[name] = new(name, response.Str("loginId"), url, "Awaiting user"); Navigate?.Invoke(url); Changed?.Invoke();
    }
    public async Task ReloadMcpAsync(IntegrationContext context, CancellationToken cancellation = default)
    {
        await RequestAsync("config/mcpServer/reload", null, cancellation); var servers = await ReadMcpAsync(context, cancellation); snapshots[context.Key] = Snapshot(context) with { McpServers = servers }; LastMessage = "MCP configuration reloaded."; Changed?.Invoke();
    }
    public async Task<IntegrationResourceContent[]> ReadResourceAsync(IntegrationContext context, string server, string uri, CancellationToken cancellation = default)
    {
        if (!Snapshot(context).McpServers.Any(x => x.Name == server)) throw new InvalidOperationException("Refresh this server in the originating workspace before reading a resource.");
        var response = await RequestAsync("mcpServer/resource/read", new { server, uri, threadId = context.RuntimeThreadId }, cancellation);
        return Rows(response, "contents").Select(content => new IntegrationResourceContent(content.Str("uri") ?? uri, content.Str("mimeType"), content.Str("text"), content.Str("blob") is { } blob ? Convert.FromBase64String(blob) : null)).ToArray();
    }
    public async Task<IntegrationToolResult> CallToolAsync(IntegrationContext context, string server, McpToolIntegration tool, IReadOnlyDictionary<string, string> values, CancellationToken cancellation = default)
    {
        if (context.RuntimeThreadId is null) throw new InvalidOperationException("Open a loaded runtime chat before calling an integration tool.");
        if (!Snapshot(context).McpServers.Any(x => x.Name == server && x.Tools.Any(t => t.Name == tool.Name))) throw new InvalidOperationException("The tool is not present in the current workspace inventory.");
        var arguments = tool.Form.Validate(values);
        var response = await RequestAsync("mcpServer/tool/call", new { server, threadId = context.RuntimeThreadId, tool = tool.Name, arguments }, cancellation, 120);
        var text = Rows(response, "content").Where(x => x.Str("type") == "text" && x.Str("text") is not null).Select(x => x.Str("text")!).ToArray();
        return new(Bool(response, "isError"), text, response.TryGetProperty("structuredContent", out var structured) ? structured.Clone() : null, Rows(response, "content"));
    }
    public async Task<ExternalImportItem[]> DetectExternalAsync(IntegrationContext context, bool includeHome = false, string? migrationSource = null, CancellationToken cancellation = default)
    {
        var response = await RequestAsync("externalAgentConfig/detect", new { includeHome, cwds = context.Cwd is null ? Array.Empty<string>() : new[] { context.Cwd }, migrationSource }, cancellation, 60);
        var found = Rows(response, "items").Where(item => item.Str("itemType") is not null).Select(item =>
        {
            var details = item.TryObjectProperty("details", out var value) ? value : default;
            var counts = details.ValueKind == JsonValueKind.Object ? details.EnumerateObject().Where(x => x.Value.ValueKind == JsonValueKind.Array).Select(x => x.Name + ": " + x.Value.GetArrayLength()).ToArray() : [];
            return new ExternalImportItem(Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(item.GetRawText()))), item.Str("itemType")!, item.Str("description") ?? item.Str("itemType")!, item.Str("cwd"), counts, item.Clone());
        }).ToArray(); imports[context.Key] = found; detections[context.Key] = (includeHome, migrationSource); Changed?.Invoke(); return found;
    }
    public async Task<string> ImportExternalAsync(IntegrationContext context, IReadOnlyCollection<string> ids, string? migrationSource = null, CancellationToken cancellation = default)
    {
        await mutations.WaitAsync(cancellation);
        try
        {
            if (activeImports.TryGetValue(context.Key, out var active) && progress.GetValueOrDefault(active)?.Complete != true) throw new InvalidOperationException("An import is still active or its outcome needs runtime reconciliation.");
            if (!detections.TryGetValue(context.Key, out var detection) || migrationSource != detection.Source) throw new InvalidOperationException("Refresh detection using the same migration source before importing.");
            var selected = ImportItems(context).Where(x => ids.Contains(x.Id)).ToArray();
            if (selected.Length == 0 || selected.Length != ids.Count) throw new InvalidOperationException("Select current detected artifacts before importing.");
            if (!detection.IncludeHome && selected.Any(x => string.IsNullOrWhiteSpace(x.Cwd))) throw new InvalidOperationException("Home-scoped artifacts require an explicit home-settings scan.");
            var response = await RequestAsync("externalAgentConfig/import", new { migrationItems = selected.Select(x => x.Raw).ToArray(), migrationSource, source = "veo-windows" }, cancellation, 120);
            var id = response.Str("importId") ?? throw new InvalidDataException("Codex did not return an import identity.");
            activeImports[context.Key] = id; progress.TryAdd(id, new(id, false, 0, 0, [])); LastMessage = "Import started. Completion will be confirmed by the runtime."; Changed?.Invoke(); return id;
        }
        finally { mutations.Release(); }
    }
    public async Task RespondElicitationAsync(RuntimeEvent request, IReadOnlyDictionary<string, string>? values, string action, CancellationToken cancellation = default)
    {
        if (request.Method != "mcpServer/elicitation/request" || action is not ("accept" or "decline" or "cancel")) throw new InvalidOperationException("Invalid elicitation response.");
        if (!workspace.PendingRequests.Any(x => x.Generation == request.Generation && x.Id?.GetRawText() == request.Id?.GetRawText())) throw new InvalidOperationException("This request is no longer pending.");
        if (action != "accept") { await workspace.RespondAsync(request, new { action }); return; }
        var mode = request.Parameters.Str("mode");
        if (mode == "url")
        {
            _ = SecureUri(request.Parameters.Str("url")) ?? throw new InvalidOperationException("The MCP URL is not secure.");
            await workspace.RespondAsync(request, new { action });
        }
        else if (mode == "form")
        {
            var form = NativeSchemaForm.Parse(request.Parameters.GetProperty("requestedSchema")); var content = form.Validate(values ?? new Dictionary<string, string>());
            await workspace.RespondAsync(request, new { action, content });
        }
        else throw new NotSupportedException("This elicitation mode has no supported native Windows form. Decline it explicitly.");
    }
    public void OpenElicitationUrl(RuntimeEvent request)
    { var uri = SecureUri(request.Parameters.Str("url")) ?? throw new InvalidOperationException("The MCP URL is not secure."); Navigate?.Invoke(uri); }
    void OnEvent(RuntimeEvent message)
    {
        var p = message.Parameters;
        if (message.Method is "externalAgentConfig/import/progress" or "externalAgentConfig/import/completed" && p.Str("importId") is { } id)
        {
            var results = Rows(p, "itemTypeResults"); var errors = results.SelectMany(x => Rows(x, "failures")).Select(x => DiagnosticRedactor.Redact(x.Str("message") ?? "Artifact import failed.")).ToArray();
            progress.AddOrUpdate(id, new ExternalImportProgress(id, message.Method.EndsWith("completed", StringComparison.Ordinal), results.Sum(x => Rows(x, "successes").Length), results.Sum(x => Rows(x, "failures").Length), errors), (_, previous) => previous.Complete ? previous : new(id, message.Method.EndsWith("completed", StringComparison.Ordinal), results.Sum(x => Rows(x, "successes").Length), results.Sum(x => Rows(x, "failures").Length), errors)); Changed?.Invoke();
        }
        if (message.Method == "mcpServer/oauthLogin/completed")
        {
            var name = p.Str("name") ?? p.Str("serverName");
            if (name is not null && oauth.TryGetValue(name, out var current) && (p.Str("loginId") is not { } login || current.LoginId is null || current.LoginId == login))
            { oauth[name] = current with { State = Bool(p, "success") ? "Authorization completed — refresh status" : "Failed", Error = p.Str("error") is { } error ? DiagnosticRedactor.Redact(error) : null }; Changed?.Invoke(); }
        }
    }
    public static JsonElement[] Rows(JsonElement element, string key) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Array ? value.EnumerateArray().Select(x => x.Clone()).ToArray() : [];
    public static bool Bool(JsonElement element, string key, bool fallback = false) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : fallback;
    public static Uri? SecureUri(string? value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == "https" && uri.UserInfo.Length == 0 ? uri : null;
    public ValueTask DisposeAsync() { disposed = true; workspace.RuntimeEventReceived -= OnEvent; return ValueTask.CompletedTask; }
}
