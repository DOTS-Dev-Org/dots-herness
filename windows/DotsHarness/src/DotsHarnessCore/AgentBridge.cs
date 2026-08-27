using System.Collections.ObjectModel;
using System.Text.Json;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed record AgentConnection(string Provider, string Model, string Workspace);

public sealed class AgentBridge : ObservableObject
{
    private readonly RouterController _router;
    private readonly string _file;
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private CancellationTokenSource? _runCancellation;
    private AgentConnection? _connection;
    private string? _selectedId;
    private string _status = "Choose a provider and workspace.";
    private PendingApproval? _pendingApproval;
    private PendingQuestion? _pendingQuestion;
    private TaskCompletionSource<string>? _approvalAnswer;

    public ObservableCollection<Conversation> Conversations { get; } = new();
    public AgentConnection? Connection { get => _connection; private set => SetProperty(ref _connection, value); }
    public string? SelectedId { get => _selectedId; set { if (SetProperty(ref _selectedId, value)) OnPropertyChanged(nameof(Selected)); } }
    public string Status { get => _status; set => SetProperty(ref _status, value); }
    public PendingApproval? PendingApproval { get => _pendingApproval; private set => SetProperty(ref _pendingApproval, value); }
    public PendingQuestion? PendingQuestion { get => _pendingQuestion; private set => SetProperty(ref _pendingQuestion, value); }
    public Conversation? Selected => Conversations.FirstOrDefault(c => c.Id == SelectedId);

    /// <summary>
    /// No interactive approval surface is attached (background/scheduled run).
    /// <c>run_command</c> approvals resolve immediately to
    /// <see cref="AutoApproveCommands"/> instead of blocking on a dialog.
    /// </summary>
    public bool NonInteractive { get; set; }
    public bool AutoApproveCommands { get; set; }

    public AgentBridge(RouterController router, SupportPaths paths)
    {
        _router = router;
        _file = Path.Combine(paths.Root, "conversations.json");
    }

    public async Task StartAsync(string workspace)
    {
        await _router.RefreshAsync();
        Load();
        if (SelectedId is null && Conversations.FirstOrDefault() is { } first) SelectedId = first.Id;
        UpdateConnection(workspace);
    }

    public void Stop()
    {
        _runCancellation?.Cancel();
        _approvalAnswer?.TrySetResult("rejected");
        _runCancellation = null;
        Connection = null;
    }

    public Task RefreshSessionsAsync() => Task.CompletedTask;

    public void Select(string id) { if (Conversations.Any(c => c.Id == id)) SelectedId = id; }

    public void RenameConversation(string id, string title)
    {
        if (Conversations.FirstOrDefault(c => c.Id == id) is not { } conversation) return;
        conversation.Title = title;
        conversation.Blank = false;
        Save();
        OnPropertyChanged(nameof(Selected));
    }

    /// <summary>
    /// Fold in conversations written to the store by another bridge (e.g. a
    /// scheduled-task run) without disturbing the active run or selection.
    /// </summary>
    public void MergeExternalConversations()
    {
        if (!File.Exists(_file)) return;
        try
        {
            var known = Conversations.Select(c => c.Id).ToHashSet();
            var items = JsonSerializer.Deserialize<List<Conversation>>(File.ReadAllText(_file)) ?? [];
            foreach (var item in items.Where(i => !known.Contains(i.Id)))
            {
                item.Running = false;
                item.PendingPrompts.Clear();
                Conversations.Add(item);
            }
        }
        catch { }
    }

    public Task NewConversationAsync(string? cwd = null, string? preset = null)
    {
        if (Conversations.FirstOrDefault(c => c.Blank) is { } draft) { SelectedId = draft.Id; return Task.CompletedTask; }
        var conversation = new Conversation { Cwd = cwd, AgentPreset = preset };
        Conversations.Insert(0, conversation);
        SelectedId = conversation.Id;
        Save();
        return Task.CompletedTask;
    }

    public async Task SendAsync(string text, PromptMode mode = PromptMode.Queue)
    {
        var prompt = text.Trim();
        if (prompt.Length == 0) return;
        if (mode == PromptMode.Steer) _runCancellation?.Cancel();
        await _sendGate.WaitAsync();
        try
        {
            if (!_router.HasActiveRoute) { Status = "Connect a provider before starting a chat."; return; }
            if (SelectedId is null) await NewConversationAsync();
            var conversation = Selected;
            if (conversation is null) return;
            conversation.PendingPrompts.Add(new PendingPrompt { Text = prompt, Mode = mode, Placement = mode == PromptMode.Steer ? PromptPlacement.Steering : PromptPlacement.Queued });
            conversation.Messages.Add(new ChatMessage { Kind = ChatKind.User, Text = prompt });
            conversation.PendingPrompts.Clear();
            conversation.Title = conversation.Blank ? SessionProjector.TitleFor(prompt) : conversation.Title;
            conversation.Blank = false;
            conversation.Running = true;
            Save();
            OnPropertyChanged(nameof(Selected));

            using var run = new CancellationTokenSource();
            _runCancellation = run;
            var messages = new List<NativeMessage> { new("system", $"You are a native coding assistant. Work only inside this workspace: {conversation.Cwd ?? Environment.CurrentDirectory}") };
            messages.AddRange(conversation.Messages.Where(m => m.Kind is ChatKind.User or ChatKind.Assistant).Select(m => new NativeMessage(m.Kind == ChatKind.User ? "user" : "assistant", m.Text)));
            var toolSteps = 0;
            while (true)
            {
                var response = await _router.CompleteAsync(messages, NativeWorkspaceTools.Definitions, ct: run.Token);
                messages.Add(new NativeMessage("assistant", response.Message.Content, ToolCalls: response.Message.ToolCalls));
                if (response.Message.ToolCalls is not { Count: > 0 })
                {
                    conversation.Messages.Add(new ChatMessage { Kind = ChatKind.Assistant, Text = response.Message.Content });
                    break;
                }
                if (++toolSteps > 8) throw new NativeProviderException("The tool step limit was reached.");
                foreach (var call in response.Message.ToolCalls)
                {
                    conversation.Messages.Add(new ChatMessage { Kind = ChatKind.Tool, Text = $"→ {call.Name}" });
                    if (call.Name == "run_command" && !await RequestApprovalAsync(call, conversation.Id, conversation.Cwd ?? Environment.CurrentDirectory, run.Token))
                    {
                        messages.Add(new NativeMessage("tool", "The user rejected this command.", call.Id));
                        continue;
                    }
                    var result = await NativeWorkspaceTools.ExecuteAsync(call, conversation.Cwd ?? Environment.CurrentDirectory, run.Token);
                    conversation.Messages.Add(new ChatMessage { Kind = ChatKind.Tool, Text = $"✓ {call.Name}\n{ToolPreview(result)}" });
                    messages.Add(new NativeMessage("tool", result, call.Id));
                }
            }
            conversation.Running = false;
            Status = $"{_router.CurrentProvider} · {_router.CurrentModel}";
            Save();
            OnPropertyChanged(nameof(Selected));
        }
        catch (OperationCanceledException) { if (Selected is { } conversation) conversation.Running = false; }
        catch (Exception ex)
        {
            if (Selected is { } conversation) { conversation.Messages.Add(new ChatMessage { Kind = ChatKind.System, Text = ex.Message }); conversation.Running = false; Save(); }
            Status = ex.Message;
            OnPropertyChanged(nameof(Selected));
        }
        finally { _runCancellation = null; _sendGate.Release(); }
    }

    public Task CancelAsync() { _runCancellation?.Cancel(); _approvalAnswer?.TrySetResult("rejected"); return Task.CompletedTask; }
    public Task AnswerApprovalAsync(string answer) { _approvalAnswer?.TrySetResult(answer); return Task.CompletedTask; }
    public Task AnswerQuestionAsync(string _) { PendingQuestion = null; return Task.CompletedTask; }

    private void UpdateConnection(string workspace)
    {
        Connection = _router.HasActiveRoute ? new AgentConnection(_router.CurrentProvider, _router.CurrentModel, workspace) : null;
        Status = Connection is null ? "Connect a provider before starting a chat." : $"{Connection.Provider} · {Connection.Model}";
        OnPropertyChanged(nameof(Selected));
    }

    private void Load()
    {
        Conversations.Clear();
        if (!File.Exists(_file)) return;
        try
        {
            var items = JsonSerializer.Deserialize<List<Conversation>>(File.ReadAllText(_file)) ?? [];
            foreach (var item in items) { item.Running = false; item.PendingPrompts.Clear(); Conversations.Add(item); }
        }
        catch { }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            // Merge by id so a second bridge (scheduled-task run) writing the same
            // file never drops conversations it does not hold in memory.
            var mine = Conversations.ToList();
            var ids = mine.Select(c => c.Id).ToHashSet();
            var merged = mine;
            if (File.Exists(_file))
            {
                try
                {
                    var existing = JsonSerializer.Deserialize<List<Conversation>>(File.ReadAllText(_file)) ?? [];
                    merged = existing.Where(c => !ids.Contains(c.Id)).Concat(mine).ToList();
                }
                catch { }
            }
            File.WriteAllText(_file, JsonSerializer.Serialize(merged, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    private async Task<bool> RequestApprovalAsync(NativeToolCall call, string conversationId, string workspace, CancellationToken ct)
    {
        if (NonInteractive) return AutoApproveCommands;

        var answer = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        _approvalAnswer = answer;
        PendingApproval = new PendingApproval(Guid.NewGuid().ToString(), conversationId, call.Id, call.Name, $"Run this command in {workspace}?");
        try { return string.Equals(await answer.Task.WaitAsync(ct), "allowed-once", StringComparison.OrdinalIgnoreCase); }
        finally { _approvalAnswer = null; PendingApproval = null; }
    }

    private static string ToolPreview(string value) => value.Length <= 700 ? value : value[..700] + "…";
}
