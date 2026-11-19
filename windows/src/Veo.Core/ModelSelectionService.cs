using System.Text.Json;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Projects;
using Veo.Protocol;

namespace Veo.Core;

public sealed class ModelSelectionService
{
    readonly WorkspaceCoordinator workspace;
    readonly SemaphoreSlim gate = new(1, 1);
    readonly object sync = new();
    readonly Func<string, CancellationToken, Task<IReadOnlyDictionary<string, ModelContextLimits>>> contexts;
    readonly Func<string, CancellationToken, Task<string>> projectIdentity;
    readonly ProjectPreferencesService? projectPreferences;
    NativeModelDescriptor[] catalog = [];
    IReadOnlyDictionary<string, ModelContextLimits> contextLimits = new Dictionary<string, ModelContextLimits>();
    ModelSelectionPreferences preferences = new();
    readonly Dictionary<string, ModelContextChoice> pendingContextRollback = new(StringComparer.Ordinal);
    CodexRuntimeService? catalogRuntime;
    long catalogGeneration = -1;
    long accountRevision;
    long catalogAccountRevision;
    bool loaded;
    public bool MultiAgentEnabled { get; private set; }
    public string? ContextWarning { get; private set; }
    public event Action? Changed;
    public ModelSelectionService(WorkspaceCoordinator workspace,
        Func<string, CancellationToken, Task<IReadOnlyDictionary<string, ModelContextLimits>>>? contexts = null,
        Func<string, CancellationToken, Task<string>>? projectIdentity = null, ProjectPreferencesService? projectPreferences = null)
    {
        this.workspace = workspace;
        this.contexts = contexts ?? BundledModelCatalog.ReadAsync;
        this.projectIdentity = projectIdentity ?? ProjectIdentityAsync;
        workspace.RuntimeEventReceived += message =>
        {
            if (message.Method == "account/updated") Interlocked.Increment(ref accountRevision);
        };
        this.projectPreferences = projectPreferences;
    }
    public bool CatalogNeedsRefresh
    {
        get
        {
            lock (sync)
                return catalog.Length == 0 || !ReferenceEquals(catalogRuntime, workspace.Runtime)
                    || catalogGeneration != workspace.Runtime.Generation
                    || catalogAccountRevision != Interlocked.Read(ref accountRevision);
        }
    }

    public async Task<ModelProviderTools?> ReadProviderToolsAsync(CancellationToken cancellation = default)
    {
        const string method = "modelProvider/capabilities/read";
        var runtime = workspace.Runtime;
        if (runtime.Capabilities.Availability(method) == CapabilityAvailability.Unavailable) return null;
        var generation = runtime.Generation;
        var result = await runtime.RequestAsync(method, new { }, cancellation);
        return ReferenceEquals(runtime, workspace.Runtime) && generation == runtime.Generation && result.ValueKind == JsonValueKind.Object
            ? new(IntegrationCoordinator.Bool(result, "webSearch"), IntegrationCoordinator.Bool(result, "imageGeneration"))
            : null;
    }

    public IReadOnlyList<NativeModelDescriptor> Catalog { get { lock (sync) return catalog.ToArray(); } }
    public IReadOnlyList<NativeModelDescriptor> Visible
    {
        get
        {
            lock (sync) return catalog.Where(model =>
                (preferences.IncludeGPT56Models || !model.IsGPT56) && !preferences.DisabledModels.Contains(model.Id)).ToArray();
        }
    }
    public IReadOnlyList<NativeModelDescriptor> Selectable => Visible.Where(model => !model.IsStandaloneDaybreak).ToArray();
    public bool IncludeGPT56Models { get { lock (sync) return preferences.IncludeGPT56Models; } }
    public bool CanDisableGPT56Models => Selectable.Any(model => !model.IsGPT56);

    public bool RequiresGPT56OptIn(string? model, string routingMode) =>
        !IncludeGPT56Models && (routingMode == "Family56" || Find(model)?.IsGPT56 == true);

    public AutoRouterPolicy RouterPolicy { get { lock (sync) return preferences.Router; } }
    public bool SupportsDaybreakBlue => workspace.SupportsDaybreakSelection;
    public bool SupportsStandardCyberAccess => workspace.SupportsDaybreakSelection;
    public async Task<bool?> ReadConfiguredDaybreakAsync(string? cwd, CancellationToken cancellation = default)
    {
        if (!workspace.SupportsDaybreakSelection ||
            workspace.Runtime.Capabilities.Availability("config/read") != CapabilityAvailability.Available) return null;
        var runtime = workspace.Runtime;
        var generation = runtime.Generation;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            var response = await runtime.RequestAsync("config/read", new { cwd, includeLayers = false }, deadline.Token);
            if (runtime != workspace.Runtime || generation != runtime.Generation ||
                !response.TryObjectProperty("config", out var config) || !config.TryGetProperty("daybreak", out var value))
                return null;
            return value.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null };
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or CodexRpcException or NotSupportedException ||
            (error is OperationCanceledException && !cancellation.IsCancellationRequested))
        { return null; }
    }
    public NativeModelDescriptor? Find(string? idOrModel)
    {
        var models = Catalog;
        return models.FirstOrDefault(model => model.Id == idOrModel) ?? models.FirstOrDefault(model => model.Model == idOrModel);
    }
    public ModelContextLimits? Limits(string modelId) { lock (sync) return contextLimits.GetValueOrDefault(modelId); }
    public ModelContextChoice ContextChoice(string modelId) { lock (sync) return preferences.Contexts.GetValueOrDefault(modelId) ?? new(); }
    public async Task InitializeAsync()
    {
        await gate.WaitAsync();
        try { await LoadCoreAsync(); }
        finally { gate.Release(); }
    }
    async Task LoadCoreAsync()
    {
        if (loaded) return;
        var raw = await workspace.Threads.ReadStateAsync("model-selection", "preferences");
        if (raw is not null) preferences = JsonSerializer.Deserialize<ModelSelectionPreferences>(raw) ?? new();
        loaded = true;
    }
    public async Task RefreshAsync(CancellationToken cancellation = default)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            await LoadCoreAsync();
            var runtime = workspace.Runtime;
            var generation = runtime.Generation;
            var revision = Interlocked.Read(ref accountRevision);
            var models = new List<NativeModelDescriptor>(); var cursors = new HashSet<string>(StringComparer.Ordinal); string? cursor = null;
            do
            {
                var request = new Dictionary<string, object?> { ["limit"] = 100, ["includeHidden"] = false };
                if (cursor is not null) request["cursor"] = cursor;
                var response = await runtime.RequestAsync("model/list", request, cancellation);
                if (!response.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Codex returned no model catalog rows.");
                models.AddRange(data.EnumerateArray().Where(x => !x.TryGetProperty("hidden", out var hidden) || hidden.ValueKind != JsonValueKind.True).Select(NativeModelDescriptor.Parse).OfType<NativeModelDescriptor>());
                cursor = response.Str("nextCursor");
                if (cursor is not null && !cursors.Add(cursor)) throw new InvalidDataException("Codex repeated a model catalog cursor.");
            } while (!string.IsNullOrEmpty(cursor));
            var unique = models.DistinctBy(x => x.Id, StringComparer.Ordinal).ToArray();
            if (unique.Length == 0) throw new InvalidOperationException("No models are available from the selected runtime.");
            IReadOnlyDictionary<string, ModelContextLimits> bundled = new Dictionary<string, ModelContextLimits>();
            ContextWarning = null;
            try { if (workspace.Runtime.ExecutablePath is { } executable) bundled = await contexts(executable, cancellation); }
            catch (Exception exception) when (exception is not OperationCanceledException || !cancellation.IsCancellationRequested) { ContextWarning = "Custom context is unavailable: " + DiagnosticRedactor.Redact(exception.Message); }
            var limits = new Dictionary<string, ModelContextLimits>(StringComparer.Ordinal);
            foreach (var model in unique)
                if (!model.IsExternal && (bundled.TryGetValue(model.Model, out var value) || bundled.TryGetValue(model.Id, out value))) limits[model.Id] = value;
            // Only actual live model IDs enter the picker; bundled entries supply limits, never availability.
            if (!ReferenceEquals(workspace.Runtime, runtime) || generation != runtime.Generation)
                throw new InvalidOperationException("The runtime reconnected while models were loading.");
            workspace.RememberDaybreakModels(unique, generation);
            lock (sync)
            {
                catalog = unique;
                contextLimits = limits;
                catalogRuntime = runtime;
                catalogGeneration = generation;
                catalogAccountRevision = revision;
            }
            MultiAgentEnabled = false;
            try
            {
                var features = await workspace.Runtime.RequestAsync("experimentalFeature/list", new { limit = 100 }, cancellation);
                MultiAgentEnabled = features.TryGetProperty("data", out var data) && data.EnumerateArray().Any(x => x.Str("name") == "multi_agent" && x.TryGetProperty("enabled", out var enabled) && enabled.ValueKind == JsonValueKind.True);
            }
            catch (CodexRpcException) { /* Family routes truthfully fall back to one worker when negotiation fails. */ }
            catch (NotSupportedException) { }
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    public ModelSelectionChoice Validate(ModelSelectionChoice choice, bool autoContext = false)
    {
        var model = Find(choice.ModelId) ?? Find(choice.Model) ?? throw new InvalidOperationException("That model is absent from the live runtime catalog.");
        var effort = model.Efforts.Any(x => x.Id == choice.Effort) ? choice.Effort : model.DefaultEffort;
        var tier = choice.Tier is null || model.Tiers.Any(x => x.Id == choice.Tier) ? choice.Tier : model.DefaultTier;
        var limits = Limits(model.Id);
        var tokens = autoContext ? limits?.Suggested : choice.ContextTokens;
        if (tokens is not null && (limits is null || tokens <= 0 || tokens > limits.Maximum)) throw new InvalidOperationException("The requested context exceeds verified limits for this model.");
        return choice with { ModelId = model.Id, Model = model.Model, Effort = effort, Tier = tier, ContextTokens = tokens ?? limits?.Suggested };
    }
    public async Task<ModelSelectionChoice> ResolveAsync(ThreadSession session)
    {
        await InitializeAsync();
        var key = await projectIdentity(session.Record.Cwd, CancellationToken.None);
        ModelSelectionChoice? choice;
        lock (sync) choice = preferences.Projects.GetValueOrDefault(key);
        if (choice is null && projectPreferences is not null && session.Record.WorkspaceKind == "project")
        {
            var configuration = await projectPreferences.ConfigurationAsync(session.Record.Cwd);
            if (Visible.FirstOrDefault(item => item.Id == configuration.ModelId || item.Model == configuration.ModelId) is { } configured)
                choice = new(configured.Id, configured.Model, configuration.ReasoningEffort ?? configured.DefaultEffort, configured.DefaultTier);
        }
        lock (sync) choice ??= preferences.Global;
        var visible = Visible;
        var selectable = visible.Where(item => !item.IsStandaloneDaybreak).ToArray();
        var model = choice is null ? null : visible.FirstOrDefault(item => item.Id == choice.ModelId);
        model ??= selectable.FirstOrDefault(item => item.IsDefault) ?? selectable.FirstOrDefault();
        model ??= visible.FirstOrDefault(item => item.IsDefault) ?? visible.FirstOrDefault();
        if (model is null) throw new InvalidOperationException("Enable at least one available model.");
        if (choice is { } previous && RequiresGPT56OptIn(previous.ModelId, previous.RoutingMode))
            choice = new(model.Id, model.Model, model.DefaultEffort, model.DefaultTier, RouterPolicy: previous.RouterPolicy);
        choice ??= new(model.Id, model.Model, model.DefaultEffort, model.DefaultTier);
        if (choice.ModelId != model.Id) choice = choice with { Daybreak = null };
        var context = ContextChoice(model.Id);
        return Validate(choice with { ModelId = model.Id, Model = model.Model, ContextTokens = context.Kind == "Default" ? Limits(model.Id)?.Suggested : context.Tokens }, choice.RoutingMode != "Direct");
    }
    public async Task SaveSelectionAsync(ThreadSession session, ModelSelectionChoice choice, string scope = "Global")
    {
        choice = Validate(choice, choice.RoutingMode != "Direct");
        if (!Visible.Any(x => x.Id == choice.ModelId)) throw new InvalidOperationException("Enable this model before making it a default.");
        await gate.WaitAsync();
        try
        {
            await LoadCoreAsync();
            if (scope == "Project")
            {
                var key = await projectIdentity(session.Record.Cwd, CancellationToken.None);
                lock (sync) preferences = preferences with { Projects = new(preferences.Projects, StringComparer.Ordinal) { [key] = choice } };
            }
            else if (scope == "Global") { lock (sync) preferences = preferences with { Global = choice }; }
            else throw new ArgumentException("Choose Global or Project.", nameof(scope));
            await SaveCoreAsync();
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    public async Task ResetProjectAsync(ThreadSession session)
    {
        var key = await projectIdentity(session.Record.Cwd, CancellationToken.None); await gate.WaitAsync();
        try { var projects = new Dictionary<string, ModelSelectionChoice>(preferences.Projects, StringComparer.Ordinal); projects.Remove(key); lock (sync) preferences = preferences with { Projects = projects }; await SaveCoreAsync(); }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    public async Task SetIncludeGPT56ModelsAsync(bool enabled)
    {
        await gate.WaitAsync();
        try
        {
            await LoadCoreAsync();
            if (!enabled && !CanDisableGPT56Models)
                throw new InvalidOperationException("Keep at least one available model enabled.");
            lock (sync) preferences = preferences with { IncludeGPT56Models = enabled };
            await SaveCoreAsync();
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }

    public async Task SetEnabledAsync(string modelId, bool enabled)
    {
        await gate.WaitAsync();
        try
        {
            var model = Find(modelId) ?? throw new InvalidOperationException("Unknown live model.");
            if (!enabled && !model.IsStandaloneDaybreak && !Selectable.Any(item => item.Id != modelId))
                throw new InvalidOperationException("At least one selectable model must remain enabled.");
            var disabled = new HashSet<string>(preferences.DisabledModels, StringComparer.Ordinal);
            if (enabled) disabled.Remove(modelId); else disabled.Add(modelId);
            lock (sync) preferences = preferences with { DisabledModels = disabled };
            await SaveCoreAsync();
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    public async Task SetContextAsync(string modelId, ModelContextChoice choice)
    {
        var limits = Limits(modelId);
        if (choice.Kind != "Default" && (limits is null || choice.Tokens is null || choice.Tokens <= 0 || choice.Tokens > limits.Maximum)) throw new InvalidOperationException("Choose a positive token limit within the model's verified maximum.");
        await gate.WaitAsync();
        try
        {
            var values = new Dictionary<string, ModelContextChoice>(preferences.Contexts, StringComparer.Ordinal);
            if (!pendingContextRollback.ContainsKey(modelId)) pendingContextRollback[modelId] = values.GetValueOrDefault(modelId) ?? new();
            if (choice.Kind == "Default") values.Remove(modelId); else values[modelId] = choice;
            lock (sync) preferences = preferences with { Contexts = values }; await SaveCoreAsync();
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    public async Task SetRouterPolicyAsync(AutoRouterPolicy policy)
    {
        if (policy.Provider is not ("Utility" or "Jev")) throw new ArgumentException("Unknown router.", nameof(policy));
        await gate.WaitAsync(); try { lock (sync) preferences = preferences with { Router = policy }; await SaveCoreAsync(); } finally { gate.Release(); Changed?.Invoke(); }
    }
    public void ConfirmContext(string modelId) { lock (sync) pendingContextRollback.Remove(modelId); }
    public async Task RollbackContextAsync(string modelId)
    {
        await gate.WaitAsync();
        try
        {
            ModelContextChoice? previous; lock (sync) pendingContextRollback.Remove(modelId, out previous);
            if (previous is null) return;
            var contexts = new Dictionary<string, ModelContextChoice>(preferences.Contexts, StringComparer.Ordinal);
            if (previous.Kind == "Default") contexts.Remove(modelId); else contexts[modelId] = previous;
            lock (sync) preferences = preferences with { Contexts = contexts }; await SaveCoreAsync();
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    Task SaveCoreAsync() => workspace.Threads.SaveStateAsync("model-selection", "preferences", JsonSerializer.Serialize(preferences));
    public static async Task<string> ProjectIdentityAsync(string cwd, CancellationToken cancellation)
    {
        var canonical = new WorkspacePathPolicy(cwd).RootPath;
        var directory = new DirectoryInfo(canonical);
        while (directory is not null)
        {
            cancellation.ThrowIfCancellationRequested(); var dotGit = Path.Combine(directory.FullName, ".git"); string? git = null;
            if (Directory.Exists(dotGit)) git = dotGit;
            else if (File.Exists(dotGit))
            {
                if (new FileInfo(dotGit).Length > 16384) throw new InvalidDataException("The worktree Git pointer is too large.");
                var pointer = await File.ReadAllTextAsync(dotGit, cancellation);
                if (pointer.StartsWith("gitdir: ", StringComparison.Ordinal)) git = Path.GetFullPath(pointer[8..].Trim(), directory.FullName);
            }
            if (git is not null)
            {
                var common = Path.Combine(git, "commondir");
                if (File.Exists(common))
                { if (new FileInfo(common).Length > 16384) throw new InvalidDataException("The common Git pointer is too large."); git = Path.GetFullPath((await File.ReadAllTextAsync(common, cancellation)).Trim(), git); }
                git = new WorkspacePathPolicy(git).RootPath;
                return "git:" + git + "|" + Directory.GetCreationTimeUtc(git).Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
            directory = directory.Parent;
        }
        return "folder:" + canonical;
    }
}
