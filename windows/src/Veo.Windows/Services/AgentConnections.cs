using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Veo.Core;
using Veo.Protocol;

namespace Veo_Windows.Services;

public sealed record ProviderUpdateInfo(string State, string Detail)
{
    public string Label => State switch {
        "current" => "Up to date", "missing" => "Not installed", "install" => "Install", "installing" => "Installing…", "available" => "Update",
        "manual" => "Unavailable", "updating" => "Updating…", "retry" => "Retry", _ => "Checking…"
    };
    public bool Actionable => State is "install" or "available" or "retry";
}

public sealed record AgentDefinition(string Id, string Name, string Command, string[] Args, string Site, bool Featured);
public sealed record AgentEffort(string Id, string Name);
public sealed record AgentModel(string Id, string Name, AgentEffort[]? Efforts = null, string? DefaultEffort = null);
public sealed record AgentConnection(string Executable, string[] Args, AgentModel[] Models, string Model, HashSet<string> Hidden,
    Dictionary<string, string>? EffortChoices = null)
{
    const string GrokStandardId = "grok-4.7";
    internal const string GrokFastId = "grok-4.7-build-fast";

    bool HasGrokSpeed => Models.Any(model => model.Id == GrokStandardId) && Models.Any(model => model.Id == GrokFastId);
    public IEnumerable<AgentModel> PickerModels => HasGrokSpeed ? Models.Where(model => model.Id != GrokFastId) : Models;
    public string PickerModelId => HasGrokSpeed && Model == GrokFastId ? GrokStandardId : Model;
    public AgentModel? SelectedModel => Models.FirstOrDefault(model => model.Id == PickerModelId);
    public bool SupportsFastSpeed(string modelId) => modelId == GrokStandardId && HasGrokSpeed;
    public bool UsesFastSpeed => Model == GrokFastId && HasGrokSpeed;
    public string? SavedEffort => EffortChoices?.GetValueOrDefault(PickerModelId)
        ?? (SupportsFastSpeed(PickerModelId) ? EffortChoices?.GetValueOrDefault(GrokFastId) : null);
    public string? SelectedEffort => SavedEffort ?? SelectedModel?.DefaultEffort;

    public AgentConnection ReconcileModel()
    {
        var connection = Model == GrokFastId && !HasGrokSpeed && Models.Any(model => model.Id == GrokStandardId)
            ? this with { Model = GrokStandardId } : this;
        return connection.SelectedModel is null || Hidden.Contains(connection.PickerModelId)
            ? connection with { Model = "" } : connection;
    }

}
public sealed record AgentChoices(Dictionary<string, AgentConnection> Connections, Dictionary<string, string> Choices);

public sealed class AgentConnections
{
    static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<WorkspaceCoordinator, AgentConnections> Instances = new();
    static string Asset(string name) => Path.Combine(AppContext.BaseDirectory, "Assets", name);
    public static AgentConnections For(WorkspaceCoordinator workspace) => Instances.GetValue(workspace, w => new(w));
    public static IReadOnlyList<AgentDefinition> Catalog { get; } = (JsonSerializer.Deserialize<AgentDefinition[]>(File.ReadAllText(Asset("VeoAgents.json")), Json) ?? [])
        .Append(new("custom-acp", "Local ACP command", "", [], "https://agentclientprotocol.com", false)).ToArray();
    readonly WorkspaceCoordinator workspace;
    readonly string settings;
    readonly AgentChoices state;
    readonly Dictionary<string, CancellationTokenSource> active = [];
    public IReadOnlyDictionary<string, AgentConnection> Connections => state.Connections;
    AgentConnections(WorkspaceCoordinator workspace)
    {
        this.workspace = workspace;
        settings = Path.Combine(workspace.DataRoot, "Settings", "agent-connections.json");
        state = File.Exists(settings) ? JsonSerializer.Deserialize<AgentChoices>(File.ReadAllText(settings), Json) ?? new([], []) : new([], []);
    }
    void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(settings)!);
        File.WriteAllText(settings + ".tmp", JsonSerializer.Serialize(state, Json));
        File.Move(settings + ".tmp", settings, true);
    }
    readonly Dictionary<string, ProviderUpdateInfo> updates = [];
    readonly HashSet<string> updating = [];
    int checks;
    public event Action? UpdatesChanged;
    public ProviderUpdateInfo UpdateInfo(string id) => updates.GetValueOrDefault(id, new("checking", "Checking the installed version."));

    public async Task CheckUpdatesAsync()
    {
        var generation = ++checks;
        try
        {
            var result = await RunAsync(new { action = "checkProviderUpdates", executables = Connections.ToDictionary(c => c.Key, c => c.Value.Executable), stateRoot = Path.Combine(workspace.DataRoot, "AgentState") }, needsSandbox: false);
            if (generation != checks) return;
            foreach (var (id, info) in result.GetProperty("updates").Deserialize<Dictionary<string,ProviderUpdateInfo>>(Json)!)
                if (!updating.Contains(id)) updates[id] = info;
        }
        catch (Exception error)
        {
            if (generation != checks) return;
            foreach (var id in Catalog.Select(agent => agent.Id).Append("codex"))
                if (!updating.Contains(id)) updates[id] = new("retry",error.Message);
        }
        UpdatesChanged?.Invoke();
    }

    public async Task UpdateAsync(string id)
    {
        if (!updating.Add(id)) return;
        var installing = UpdateInfo(id).State == "install";
        updates[id] = installing
            ? new("installing", "Installing the provider in Veo.")
            : new("updating", "Updating the installed provider.");
        UpdatesChanged?.Invoke();
        try
        {
            await RunAsync(new { action = "updateProvider", provider = id, executables = Connections.ToDictionary(c => c.Key, c => c.Value.Executable), stateRoot = Path.Combine(workspace.DataRoot, "AgentState") }, needsSandbox: false);
        }
        finally
        {
            updating.Remove(id);
            await CheckUpdatesAsync();
        }
    }
    public string? Choice(string thread)
    {
        var id = state.Choices.GetValueOrDefault(thread, state.Choices.GetValueOrDefault("default", ""));
        return state.Connections.ContainsKey(id) ? id : null;
    }
    public void Choose(string thread, string? agent) { state.Choices[thread] = agent ?? ""; Save(); }
    public void SetModelSelection(string id, string model, bool fast, string? effort)
    {
        var connection = state.Connections[id];
        if (model.Length > 0 && !connection.PickerModels.Any(option => option.Id == model && !connection.Hidden.Contains(model)))
            return;
        var slug = fast && connection.SupportsFastSpeed(model) ? AgentConnection.GrokFastId : model;
        var choices = connection.EffortChoices;
        if (effort is not null && connection.Models.FirstOrDefault(option => option.Id == model)?.Efforts?.Any(option => option.Id == effort) == true)
        {
            choices ??= [];
            choices[model] = effort;
        }
        state.Connections[id] = connection with { Model = slug, EffortChoices = choices };
        Save();
    }
    public void Toggle(string id, string model, bool enabled)
    {
        var c = state.Connections[id];
        if (enabled) c.Hidden.Remove(model);
        else if (c.PickerModels.Count(m => !c.Hidden.Contains(m.Id)) > 1) c.Hidden.Add(model);
        if (c.Hidden.Contains(c.PickerModelId))
            state.Connections[id] = c with { Model = c.PickerModels.First(m => !c.Hidden.Contains(m.Id)).Id };
        Save();
    }
    public void Disconnect(string id) { state.Connections.Remove(id); Save(); }
    string StateDirectory(string id) => Directory.CreateDirectory(Path.Combine(workspace.DataRoot, "AgentState", id)).FullName;
    public async Task RefreshModelCatalogAsync(string id)
    {
        if (!Connections.TryGetValue(id, out var saved)) return;
        var (models, _) = await ReadModelCatalogAsync(id, saved.Executable, saved.Args, "models", saved.Model);
        if (!Connections.TryGetValue(id, out var latest) || latest.Executable != saved.Executable ||
            !latest.Args.SequenceEqual(saved.Args)) return;
        var merged = models.Select(model => model.Efforts is null
            ? latest.Models.FirstOrDefault(previous => previous.Id == model.Id && previous.Efforts is not null) ?? model
            : model).ToArray();
        state.Connections[id] = (latest with { Models = merged }).ReconcileModel();
        Save();
    }

    public async Task ConnectAsync(AgentDefinition agent, string executable, string[] args)
    {
        var (models, current) = await ReadModelCatalogAsync(agent.Id, executable, args, "connect");
        Connections.TryGetValue(agent.Id, out var saved);
        var hidden = saved?.Hidden.Intersect(models.Select(model => model.Id)).ToHashSet() ?? [];
        var choice = saved?.Model ?? current;
        state.Connections[agent.Id] = new AgentConnection(executable, args, models, choice, hidden, saved?.EffortChoices).ReconcileModel();
        Save();
    }

    async Task<(AgentModel[] Models, string Current)> ReadModelCatalogAsync(string id, string executable, string[] args, string action, string model = "")
    {
        string stateDir = StateDirectory(id);
        var result = await RunAsync(new { action, provider=id, executable, args, model, cwd=stateDir, state=stateDir, access="readOnly" });
        return (result.GetProperty("models").Deserialize<AgentModel[]>(Json) ?? [], result.GetProperty("current").GetString() ?? "");
    }
    public bool Stop(string thread)
    {
        if (!active.TryGetValue(thread, out var source)) return false;
        source.Cancel(); return true;
    }
    public async Task<string> TurnAsync(string id, ThreadSession thread, string text, string access, object history,
        Action<string> delta, Func<string,Task<bool>> permission)
    {
        var connection=state.Connections[id];
        using var source=new CancellationTokenSource();
        active.Add(thread.Record.VeoId,source);
        try
        {
            var result=await RunAsync(new { action="turn",thread=thread.Record.VeoId,provider=id,connection.Executable,connection.Args,connection.Model,
                cwd=thread.Record.Cwd,state=StateDirectory(id),text,history,effort=connection.SavedEffort,access=access=="Read only"?"readOnly":"workspace" },delta,permission,source.Token);
            return result.GetProperty("text").GetString() ?? "";
        }
        finally { active.Remove(thread.Record.VeoId); }
    }
    async Task<JsonElement> RunAsync(object request, Action<string>? delta=null, Func<string,Task<bool>>? permission=null, CancellationToken token=default, bool needsSandbox=true)
    {
        var node = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"nodejs"))
            .Where(Path.IsPathFullyQualified).Select(dir=>Path.Combine(dir,"node.exe")).FirstOrDefault(File.Exists)
            ?? throw new FileNotFoundException("Install Node.js to connect a local agent.");
        var start=new ProcessStartInfo(node) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,
            StandardInputEncoding=new UTF8Encoding(false),StandardOutputEncoding=Encoding.UTF8};
        start.ArgumentList.Add(Asset("veo-agent.cjs"));
        var executable = CodexExecutableDiscovery.Resolve(workspace.Preferences.CodexExecutable);
        if (executable is not null) start.Environment["CODEX_EXECUTABLE"] = executable;
        else if (needsSandbox) throw new FileNotFoundException("Install Codex CLI for workspace sandboxing.");
        using var proc=Process.Start(start) ?? throw new IOException("Could not start the provider connection.");
        void StopProcess() { try { if(!proc.HasExited) proc.Kill(true); } catch(InvalidOperationException) { } }
        using var registration=token.Register(StopProcess);
        try {
            await proc.StandardInput.WriteLineAsync(JsonSerializer.Serialize(request,Json));
            while(await proc.StandardOutput.ReadLineAsync(token) is { } line)
            {
                var data=JsonSerializer.Deserialize<JsonElement>(line);
                if(data.TryGetProperty("error",out var error)) throw new InvalidOperationException(error.GetString());
                if(data.TryGetProperty("delta",out var chunk)) delta?.Invoke(chunk.GetString()??"");
                if(data.TryGetProperty("permission",out var key))
                {
                    var allow=permission is not null && await permission(data.GetProperty("title").GetString()??"Provider action");
                    await proc.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { permission=key.GetString(),allow }));
                }
                if(data.TryGetProperty("done",out _) || data.TryGetProperty("connected",out _)) return data;
            }
            throw new IOException("Provider stopped before completing its request.");
        } finally { StopProcess(); }
    }
}
