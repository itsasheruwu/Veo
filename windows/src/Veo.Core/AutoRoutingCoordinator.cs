using System.Collections.Concurrent;
using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

public sealed record LockedAutoRoute(ModelSelectionChoice Choice, string FirstClientId, bool UsedFallback, string? Issue);
public sealed record ContextApplyResult(string Status, string Message);

public sealed class AutoRoutingCoordinator : IAsyncDisposable
{
    readonly WorkspaceCoordinator workspace;
    readonly ModelSelectionService models;
    readonly IFirstPromptRouter? jev;
    readonly IUtilityInference inference;
    readonly VisionFallbackService vision;
    readonly UtilityInferenceService? ownedInference;
    readonly Func<RuntimeEvent, bool>? previousInterceptor;
    readonly Func<RuntimeEvent, bool>? installedInterceptor;
    readonly ConcurrentDictionary<string, SemaphoreSlim> gates = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, LockedAutoRoute> locked = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, FamilyRouteRun> workflows = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, string> contextSignatures = new(StringComparer.Ordinal);
    readonly ConcurrentDictionary<string, string> notices = new(StringComparer.Ordinal);
    bool disposed;
    public event Action? Changed;
    public AutoRoutingCoordinator(WorkspaceCoordinator workspace, ModelSelectionService models, IFirstPromptRouter? jev = null, IUtilityInference? inference = null)
    {
        this.workspace = workspace; this.models = models; this.jev = jev;
        this.inference = inference ?? (ownedInference = new UtilityInferenceService(workspace));
        vision = new(this.inference);
        if (ownedInference is not null)
        {
            previousInterceptor = workspace.TryHandleRuntimeEvent;
            installedInterceptor = message => previousInterceptor?.Invoke(message) == true || ownedInference.TryHandle(message);
            workspace.TryHandleRuntimeEvent = installedInterceptor;
        }
        workspace.RuntimeEventApplied += OnEvent;
    }
    public LockedAutoRoute? LockedRoute(ThreadSession session) => locked.GetValueOrDefault(session.Record.VeoId);
    public FamilyRouteRun? Workflow(ThreadSession session) => workflows.GetValueOrDefault(session.Record.VeoId);
    public string? Notice(ThreadSession session) => notices.GetValueOrDefault(session.Record.VeoId) ?? LockedRoute(session)?.Issue;
    public async Task ObserveAsync(ThreadSession session)
    {
        var id = session.Record.VeoId;
        if (!locked.ContainsKey(id) && await workspace.Threads.ReadStateAsync(id, "first-prompt-route") is { } route && JsonSerializer.Deserialize<LockedAutoRoute>(route) is { } value) locked[id] = value;
        if (!workflows.ContainsKey(id) && await workspace.Threads.ReadStateAsync(id, "family-latest") is { } raw && JsonSerializer.Deserialize<FamilyRouteRun>(raw) is { } run) workflows[id] = run;
    }
    public async Task<ComposerSnapshot> PrepareAsync(ThreadSession session, ComposerSnapshot payload, CancellationToken cancellation = default)
    {
        var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync(cancellation);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            var imageInputs = payload.StructuredAttachments?.Where(x => x.Kind is ComposerAttachmentKind.LocalImage or ComposerAttachmentKind.Image).ToArray();
            var hasImages = imageInputs is null ? payload.Attachments.Length > 0 : imageInputs.Length > 0;
            if (models.Catalog.Count == 0) await models.RefreshAsync(cancellation);
            await ObserveAsync(session);
            if (payload.Daybreak is not null &&
                (payload.RoutingMode != "Direct" || locked.ContainsKey(session.Record.VeoId)))
                throw new InvalidOperationException("Daybreak selection requires a direct Codex model and cannot change a locked Auto route.");
            if (locked.TryGetValue(session.Record.VeoId, out var existing))
                payload = Apply(payload, existing.Choice);
            else if (payload.RoutingMode == "FirstPrompt")
            {
                if (session.Record.CodexThreadId is not null)
                {
                    notices[session.Record.VeoId] = "First-prompt Auto did not reroute this existing runtime session.";
                    return payload with { Model = null, Effort = null, Tier = null, ContextTokens = null };
                }
                var policy = payload.RouterPolicy ?? throw new InvalidOperationException("Choose an explicit Auto routing policy before sending.");
                if (!policy.OptedIn) throw new InvalidOperationException("Enable the selected Auto router explicitly before sharing the first prompt.");
                var candidates = FirstPromptRouting.Candidates(models.Visible, policy, hasImages);
                var selected = FirstPromptRouting.Fallback(candidates); var fallback = false; string? issue = null;
                if (candidates.Count > 1)
                {
                    try
                    {
                        var router = Router(policy, session.Record.Cwd);
                        var choice = await router.ChooseAsync(payload.Text, candidates, cancellation);
                        selected = candidates.FirstOrDefault(x => x.Id == choice) ?? throw new InvalidDataException("The router selected an unknown route.");
                    }
                    catch (Exception exception) when (exception is not OperationCanceledException || !cancellation.IsCancellationRequested)
                    { fallback = true; issue = DiagnosticRedactor.Redact(exception is OperationCanceledException ? "The router timed out." : exception.Message); }
                }
                cancellation.ThrowIfCancellationRequested();
                if (!models.Visible.Any(x => x.Id == selected.Model.Id))
                { selected = FirstPromptRouting.Fallback(FirstPromptRouting.Candidates(models.Visible, policy, hasImages)); fallback = true; issue = "The model catalog changed while routing. A compatible enabled fallback was selected."; }
                var choiceSnapshot = new ModelSelectionChoice(selected.Model.Id, selected.Model.Model, selected.Effort, selected.Tier, models.Limits(selected.Model.Id)?.Suggested, "FirstPrompt", policy);
                var route = new LockedAutoRoute(choiceSnapshot, payload.ClientId, fallback, issue);
                await workspace.Threads.SaveStateAsync(session.Record.VeoId, "first-prompt-route", JsonSerializer.Serialize(route)); locked[session.Record.VeoId] = route;
                payload = Apply(payload, choiceSnapshot);
                notices[session.Record.VeoId] = "Auto chose " + selected.Model.Name + " · " + new ModelReasoning(selected.Effort, "").Title + (issue is null ? "" : ". Fallback: " + issue);
            }
            else if (payload.RoutingMode is "Family56" or "Family6")
            {
                var plan = payload.FamilyPlan ?? FamilyAutoRouting.Resolve(models.Visible, payload.RoutingMode == "Family56" ? "5.6" : "6", models.MultiAgentEnabled);
                payload = payload with { Model = plan.Parent.Model, CatalogModelId = plan.Parent.ModelId, Effort = plan.Parent.Effort, Tier = null, ContextTokens = payload.ContextTokens ?? models.Limits(plan.Parent.ModelId)?.Suggested, FamilyPlan = plan };
                var run = new FamilyRouteRun(payload.ClientId, null, plan, AutoWorkflowReducer.Derive([], payload.ClientId, null, plan, false), DateTimeOffset.UtcNow);
                await SaveWorkflowAsync(session.Record.VeoId, run);
            }
            else if (payload.RoutingMode != "Direct") throw new InvalidOperationException("Unknown model routing mode.");
            if (payload.Model is not null)
            {
                var chosen = models.Find(payload.CatalogModelId) ?? models.Find(payload.Model) ?? throw new InvalidOperationException("The selected model is absent from the current live catalog. Refresh or choose an available model.");
                if (payload.Effort is not null && chosen.Efforts.Length > 0 && chosen.Efforts.All(x => x.Id != payload.Effort)) throw new InvalidOperationException("The queued reasoning effort is no longer advertised by this model. Review the message settings before retrying.");
                if (payload.Tier is not null && chosen.Tiers.All(x => x.Id != payload.Tier)) throw new InvalidOperationException("The queued service tier is no longer advertised by this model. Review the message settings before retrying.");
                if (payload.ContextTokens is { } tokens && (models.Limits(chosen.Id) is not { } limits || tokens <= 0 || tokens > limits.Maximum)) throw new InvalidOperationException("The requested context is outside this model's verified limits.");
            }
            if (payload.VisionFallback is { } preparedVision)
            {
                var selectedPaths = imageInputs is null ? payload.Attachments : imageInputs.Where(x => x.Kind == ComposerAttachmentKind.LocalImage).Select(x => x.Source).ToArray();
                if (imageInputs?.Any(x => x.Kind == ComposerAttachmentKind.Image) == true || !selectedPaths.Select(Path.GetFullPath).SequenceEqual(preparedVision.Images.Select(x => Path.GetFullPath(x.Path)), OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal)) throw new InvalidOperationException("The selected images differ from their prepared descriptions. Attach the intended images again before sending.");
                await VisionFallbackService.ValidateIdentityAsync(preparedVision, cancellation);
            }
            else if (hasImages && (models.Find(payload.CatalogModelId) ?? models.Find(payload.Model)) is { SupportsImages: false })
            {
                if (imageInputs?.Any(x => x.Kind == ComposerAttachmentKind.Image) == true) throw new NotSupportedException("This model cannot accept URL images. Choose an image-capable model; local image descriptions do not process remote images.");
                var policy = payload.RouterPolicy ?? new();
                if (!policy.VisionOptedIn) throw new InvalidOperationException("This model does not accept images. Enable image descriptions explicitly or choose an image-capable model.");
                var utility = UtilityModel(policy);
                payload = payload with { VisionFallback = await vision.DescribeAsync(session, payload, utility, [Path.Combine(workspace.DataRoot, "Attachments")], true, cancellation) };
            }
            if (session.Record.CodexThreadId is not null) await ConfigureContextAsync(session, payload, cancellation);
            return payload;
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    IFirstPromptRouter Router(AutoRouterPolicy policy, string cwd)
    {
        if (policy.Provider == "Jev") return jev ?? throw new InvalidOperationException("Jev credentials are not configured. Add a key in Settings.");
        if (policy.Provider != "Utility") throw new InvalidOperationException("Unknown Auto router provider.");
        return new UtilityFirstPromptRouter(inference, UtilityModel(policy), cwd);
    }
    NativeModelDescriptor UtilityModel(AutoRouterPolicy policy)
    {
        var eligible = models.Visible.Where(x => x.Efforts.Any(e => e.Id.Equals("low", StringComparison.OrdinalIgnoreCase))).ToArray();
        return eligible.FirstOrDefault(x => x.Id == policy.UtilityModelId)
            ?? eligible.FirstOrDefault(x => x.Names.Any(n => NativeModelDescriptor.Normalize(n).Contains("gpt-5.6-luna", StringComparison.Ordinal)))
            ?? throw new InvalidOperationException("Choose an available Utility model with Low reasoning in Settings.");
    }
    static ComposerSnapshot Apply(ComposerSnapshot payload, ModelSelectionChoice choice) => payload with { Model = choice.Model, CatalogModelId = choice.ModelId, Effort = choice.Effort, Tier = choice.Tier, ContextTokens = choice.ContextTokens, RoutingMode = choice.RoutingMode, RouterPolicy = choice.RouterPolicy, FamilyPlan = choice.FamilyPlan };
    public async Task<ContextApplyResult> ConfigureContextAsync(ThreadSession session, ComposerSnapshot payload, CancellationToken cancellation = default)
    {
        if (session.Timeline.IsRunning) return new("NextTurnOnly", "Context changes apply after the active turn finishes.");
        if (session.Record.CodexThreadId is not { } id) return new("NewThread", "Context will be configured when the runtime thread is created.");
        var key = workspace.Runtime.Generation + ":" + id; var signature = payload.ContextTokens?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "runtime-default";
        if (contextSignatures.TryGetValue(key, out var previous) && previous == signature) return new("Applied", "The requested context is already configured.");
        var model = models.Find(payload.CatalogModelId) ?? models.Find(payload.Model); var unsubscribed = false;
        var parameters = new Dictionary<string, object?> { ["threadId"] = id, ["cwd"] = session.Record.Cwd, ["sandbox"] = payload.Access switch { "Read only" => "read-only", "Full access" => "danger-full-access", _ => "workspace-write" }, ["approvalPolicy"] = "on-request", ["excludeTurns"] = true };
        if (payload.Model is not null) parameters["model"] = payload.Model;
        if (payload.Tier is not null) parameters["serviceTier"] = payload.Tier;
        if (payload.ContextTokens is not null) parameters["config"] = new { model_context_window = payload.ContextTokens };
        try
        {
            await workspace.Runtime.RequestAsync("thread/unsubscribe", new { threadId = id }, cancellation); unsubscribed = true;
            await workspace.Runtime.RequestAsync("thread/resume", parameters, cancellation); contextSignatures[key] = signature;
            if (model is not null) models.ConfirmContext(model.Id);
            return new("Applied", "Context was configured for the next turn.");
        }
        catch
        {
            if (unsubscribed)
            {
                if (long.TryParse(previous, out var prior)) parameters["config"] = new { model_context_window = prior }; else parameters.Remove("config");
                try { await workspace.Runtime.RequestAsync("thread/resume", parameters, cancellation); if (previous is not null) contextSignatures[key] = previous; } catch (Exception exception) when (exception is IOException or CodexRpcException or NotSupportedException or OperationCanceledException) { }
            }
            if (model is not null) await models.RollbackContextAsync(model.Id);
            throw;
        }
    }
    async void OnEvent(ThreadSession session, RuntimeEvent message)
    {
        if (disposed || !workflows.TryGetValue(session.Record.VeoId, out var run)) return;
        var gate = gates.GetOrAdd(session.Record.VeoId, _ => new(1, 1)); await gate.WaitAsync();
        try
        {
            if (disposed) return;
            run = workflows[session.Record.VeoId];
            var turn = message.Parameters.Str("turnId") ?? (message.Parameters.TryObjectProperty("turn", out var t) ? t.Str("id") : null) ?? run.TurnId;
            if (run.TurnId is not null && turn is not null && run.TurnId != turn) return;
            await SaveWorkflowAsync(session.Record.VeoId, run with { TurnId = turn, State = AutoWorkflowReducer.Derive(session.Timeline.Items, run.ClientId, turn, run.Plan, session.Timeline.IsRunning), UpdatedAt = DateTimeOffset.UtcNow });
        }
        catch (Exception exception) { notices[session.Record.VeoId] = DiagnosticRedactor.Redact(exception.Message); }
        finally { gate.Release(); Changed?.Invoke(); }
    }
    async Task SaveWorkflowAsync(string threadId, FamilyRouteRun run)
    {
        await workspace.Threads.SaveStateAsync(threadId, "family-run-" + run.ClientId, JsonSerializer.Serialize(run));
        await workspace.Threads.SaveStateAsync(threadId, "family-latest", JsonSerializer.Serialize(run)); workflows[threadId] = run;
    }
    public async ValueTask DisposeAsync()
    {
        disposed = true; workspace.RuntimeEventApplied -= OnEvent;
        if (installedInterceptor is not null && workspace.TryHandleRuntimeEvent == installedInterceptor) workspace.TryHandleRuntimeEvent = previousInterceptor;
        if (ownedInference is not null) await ownedInference.DisposeAsync();
        foreach (var gate in gates.Values) { await gate.WaitAsync(); gate.Release(); }
    }
}
