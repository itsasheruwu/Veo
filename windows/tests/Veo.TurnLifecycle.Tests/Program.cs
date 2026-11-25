using System.Text.Json;
using Microsoft.Data.Sqlite;
using Veo.Core;
using Veo.Infrastructure.Storage;
using Veo.Protocol;

if(args.Contains("--turn-lifecycle-server")){await Server(args);return;}
var passed=0;
void Check(bool condition,string name){if(!condition)throw new Exception(name);passed++;Console.WriteLine("PASS "+name);}
static JsonElement J(string text)=>JsonSerializer.Deserialize<JsonElement>(text);
var root=Path.GetFullPath(Path.Combine(Path.GetTempPath(),"Veo-Turn-Lifecycle-"+Guid.NewGuid().ToString("N")));Directory.CreateDirectory(root);
try
{
    var reducer=new TimelineReducer();
    reducer.Apply("turn/started",J("""{"turn":{"id":"actual","status":"inProgress"}}"""));
    reducer.Apply("turn/completed",J("""{"turn":{"id":"actual","status":"interrupted","error":{"message":"fixture error","codexErrorInfo":{"future":7}}}}"""));
    reducer.ObserveTurnMetadata(J("""{"id":"actual","status":"inProgress"}"""));
    reducer.Apply("turn/started",J("""{"turn":{"id":"actual","status":"inProgress"}}"""));
    Check(reducer.Turns.Single().Status=="interrupted"&&reducer.Turns.Single().TerminalObserved&&!reducer.IsRunning,"late acknowledgement/start cannot reopen a terminal turn");
    Check(reducer.Items.Count==0&&J(reducer.Turns.Single().ErrorJson!).GetProperty("codexErrorInfo").GetProperty("future").GetInt32()==7,"turn closure/error metadata creates no assistant item and keeps exact error fields");
    reducer.Apply("turn/started",J("""{"turn":{"id":"unknown-outcome","status":"inProgress"}}"""));
    reducer.Apply("turn/aborted",J("""{"turn":{"id":"unknown-outcome"}}"""));
    Check(reducer.Turns.Single(t=>t.Id=="unknown-outcome")is{Status:null,TerminalObserved:true},"terminal notification without outcome retains explicit unknown status");
    var unidentified=new TimelineReducer();unidentified.Apply("turn/started",J("{}"));unidentified.Apply("turn/completed",J("{}"));unidentified.ObserveTurnMetadata(J("""{"id":"nested","status":"completed"}"""),"conflicting");
    Check(unidentified.Turns.Count==0,"missing or conflicting runtime identities create no fabricated turn row");
    reducer.Reconcile([],true,"actual",reducer.StateVersion);Check(!reducer.IsRunning,"stale history active status cannot reopen a known terminal identity");

    var database=Path.Combine(root,"migration","veo.sqlite");var error="{\"message\":\"exact interruption\",\"future\":{\"value\":8}}";
    await using(var db=new ThreadRepository(database))
    {
        await db.InitializeAsync();await db.UpsertThreadAsync(new("legacy",null,root,"Existing chat"));
        await db.SaveTimelineAsync("legacy",[new("interrupted","interrupted",null,error,0)],[new("existing-item","interrupted","commandExecution",null,"interrupted","{\"id\":\"existing-item\",\"text\":\"preserved bytes 終\"}",0,DateTimeOffset.UtcNow)]);
    }
    using(var old=new SqliteConnection("Data Source="+database+";Pooling=False")){old.Open();using var command=old.CreateCommand();command.CommandText="ALTER TABLE turns DROP COLUMN terminal_observed; PRAGMA user_version=2;";command.ExecuteNonQuery();}
    await using(var db=new ThreadRepository(database))
    {
        await db.InitializeAsync();var migrated=(await db.ReadTurnsAsync("legacy")).Single();
        Check(migrated is{Status:"interrupted",TerminalObserved:true}&&migrated.ErrorJson==error,"actual version2 migration preserves terminal outcome and exact error");
        Check((await db.ReadItemsAsync("legacy")).Single().RawJson.Contains("preserved bytes 終"),"migration preserves existing item bytes");
        await db.SaveTimelineAsync("legacy",[new("interrupted","inProgress",null,null,99)],[]);
        Check((await db.ReadTurnsAsync("legacy")).Single()is{Status:"interrupted",TerminalObserved:true,SortIndex:0},"SQLite monotonic guard rejects an older nonterminal snapshot independently of reducer");
        await db.SaveTimelineAsync("legacy",[new("unknown","inProgress",null,null,1)],[]);await db.SaveTimelineAsync("legacy",[new("unknown",null,null,null,1,true)],[]);await db.SaveTimelineAsync("legacy",[new("unknown","inProgress",null,null,1)],[]);
        Check((await db.ReadTurnsAsync("legacy")).Single(t=>t.TurnId=="unknown")is{Status:null,TerminalObserved:true},"SQLite persists unknown closure without guessing completed/interrupted");
    }
    var backup=Directory.GetFiles(Path.GetDirectoryName(database)!,Path.GetFileName(database)+".pre-v*-*.bak").Single();
    using(var db=new SqliteConnection("Data Source="+backup+";Mode=ReadOnly;Pooling=False")){db.Open();using var command=db.CreateCommand();command.CommandText="PRAGMA user_version;";Check(Convert.ToInt32(command.ExecuteScalar())==2,"online backup retains pre-migration schema version");command.CommandText="SELECT status||'|'||error_json FROM turns WHERE turn_id='interrupted';";Check((string?)command.ExecuteScalar()=="interrupted|"+error,"online backup preserves committed turn data");}

    var executable=Path.Combine(AppContext.BaseDirectory,"Veo.TurnLifecycle.Tests"+(OperatingSystem.IsWindows()?".exe":""));
    CodexRuntimeService Runtime(string scenario)=>new(new CodexRuntimeOptions{ExecutablePath=executable,AdditionalArguments=["--turn-lifecycle-server","--scenario="+scenario]});
    foreach(var scenario in new[]{"interrupted","unknown","missing"})
    {
        await using var workspace=new WorkspaceCoordinator(Path.Combine(root,scenario),_=>Runtime(scenario));await workspace.InitializeAsync();var session=await workspace.CreateAsync();
        try{await workspace.SubmitAsync(session,new("client","sleep fixture","fixture","medium",null,"Workspace","Agentic",[]));}catch(InvalidDataException)when(scenario=="missing"){}
        var turns=await workspace.Threads.ReadTurnsAsync(session.Record.VeoId);var items=await workspace.Threads.ReadItemsAsync(session.Record.VeoId);
        if(scenario=="missing")Check(turns.Count==0&&!session.Timeline.IsRunning,"real-pipe unidentified notifications stay transient with no fake turn identity");
        else{
            Check(turns.Count==1&&turns[0].TurnId=="actual-turn"&&turns[0].TerminalObserved&&turns[0].Status==(scenario=="unknown"?null:"interrupted"),"real-pipe "+scenario+" lifecycle survives late inProgress acknowledgement in SQLite");
            Check(items.Count==2&&items.All(i=>i.TurnId=="actual-turn")&&!items.Any(i=>i.Type is "agentMessage"or"assistant"),"real-pipe "+scenario+" keeps exact user/command IDs with no artificial completion marker");
        }
    }
    var resumeRoot=Path.Combine(root,"history");await using(var workspace=new WorkspaceCoordinator(resumeRoot,_=>Runtime("history"))){await workspace.InitializeAsync();var record=new PersistedThread("history","runtime",root,"History");await workspace.Threads.UpsertThreadAsync(record);var session=await workspace.LoadAsync(record);var turns=await workspace.Threads.ReadTurnsAsync(record.VeoId);Check(turns.Count==2&&turns.Single(t=>t.TurnId=="empty-failed").Status=="failed"&&turns.Single(t=>t.TurnId=="empty-failed").ErrorJson=="{\"message\":\"history fixture\"}","rehydration persists failed/error turn metadata even when the turn has no items");
        var history=new HistoryCoordinator(workspace,new HistoryRpc());var page=await history.LoadAsync(session,preferred:HistoryMode.Turns);turns=await workspace.Threads.ReadTurnsAsync(record.VeoId);Check(turns.Single(t=>t.TurnId=="history-interrupted")is{Status:"interrupted",TerminalObserved:true}&&page.TurnMetadata?.Single().Status=="interrupted","ordinary history paging retains actual interrupted status instead of hardcoding completed");}
    Console.WriteLine($"{passed} turn lifecycle checks passed.");
}
finally{if(Path.GetDirectoryName(root)==Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar)&&Path.GetFileName(root).StartsWith("Veo-Turn-Lifecycle-"))Directory.Delete(root,true);}

static async Task Server(string[] args)
{
    var scenario=args.Single(a=>a.StartsWith("--scenario="))[11..];
    async Task Write(object value){await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value));await Console.Out.FlushAsync();}
    while(await Console.In.ReadLineAsync()is{}line){using var document=JsonDocument.Parse(line);var request=document.RootElement;if(!request.TryGetProperty("id",out var id))continue;var method=request.Str("method");
        switch(method){
            case "initialize":await Write(new{id=id.Clone(),result=new{userAgent="fixture"}});break;
            case "model/list":await Write(new{id=id.Clone(),result=new{data=new[]{new{id="fixture",model="fixture",displayName="Fixture"}}}});break;
            case "account/read":await Write(new{id=id.Clone(),result=new{account=(object?)null}});break;
            case "thread/start":await Write(new{id=id.Clone(),result=new{thread=new{id="runtime"}}});break;
            case "thread/resume":await Write(new{id=id.Clone(),result=new{thread=new{id="runtime",status="idle",turns=new[]{new{id="empty-failed",status="failed",error=(object?)new{message="history fixture"},items=Array.Empty<object>()},new{id="empty-interrupted",status="interrupted",error=(object?)null,items=Array.Empty<object>()}}}}});break;
            case "turn/start":
                if(scenario=="missing"){await Write(new{method="turn/started",@params=new{threadId="runtime",turn=new{status="inProgress"}}});await Write(new{method="turn/aborted",@params=new{threadId="runtime"}});await Write(new{id=id.Clone(),result=new{turn=new{id=(string?)null}}});break;}
                var client=request.GetProperty("params").Str("clientUserMessageId");var user=new{id="actual-user",type="userMessage",clientUserMessageId=client,text="sleep fixture"};var command=new{id="actual-command",type="commandExecution",status="interrupted",command="fixture sleep"};
                await Write(new{method="turn/started",@params=new{threadId="runtime",turn=new{id="actual-turn",status="inProgress"}}});await Write(new{method="item/completed",@params=new{threadId="runtime",turnId="actual-turn",item=user}});await Write(new{method="item/completed",@params=new{threadId="runtime",turnId="actual-turn",item=command}});
                if(scenario=="unknown")await Write(new{method="turn/aborted",@params=new{threadId="runtime",turn=new{id="actual-turn"}}});else await Write(new{method="turn/completed",@params=new{threadId="runtime",turn=new{id="actual-turn",status="interrupted",items=new object[]{user,command}}}});
                await Task.Delay(100);await Write(new{id=id.Clone(),result=new{turn=new{id="actual-turn",status="inProgress"}}});break;
            default:await Write(new{id=id.Clone(),result=new{}});break;
        }
    }
}
sealed class HistoryRpc:ICoordinatorRpc
{
    public long Generation=>1;public bool Supports(string method)=>true;
    public Task<JsonElement> RequestAsync(string method,object? parameters,CancellationToken token=default)=>Task.FromResult(JsonSerializer.SerializeToElement(new{data=new[]{new{id="history-interrupted",status="interrupted",items=Array.Empty<object>()}},nextCursor=(string?)null}));
}
