using System.Security.Cryptography;
using System.Text;
using Veo.Platform.Windows.Browser;

if(args.Contains("--serve")){await BrowserFixtureServer.RunAsync(args);return;}
var root=Path.Combine(Path.GetTempPath(),"veo-browser-tests-"+Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
var count=0;
void Check(bool value,string name){if(!value)throw new Exception(name);Console.WriteLine("PASS "+name);count++;}
async Task Reject(Func<Task> action,string name){try{await action();}catch(Exception e)when(e is UnauthorizedAccessException or InvalidDataException or ArgumentException or InvalidOperationException){Check(true,name);return;}throw new Exception("Accepted: "+name);}
try {
Check(BrowserOrigin.Same("https://EXAMPLE.com/a","https://example.com:443/b"),"normalized origin uses default port");
Check(!BrowserOrigin.Same("https://example.com","http://example.com")&&!BrowserOrigin.Same("https://example.com","https://example.com:444")&&!BrowserOrigin.Same("https://example.com","https://example.com.evil.test"),"scheme, port and host remain exact");
Check(!BrowserOrigin.IsWeb("https://user:pass@example.com")&&!BrowserOrigin.IsWeb("file:///c:/secret")&&!BrowserOrigin.IsWeb("javascript:alert(1)"),"embedded credentials and nonweb URIs rejected");
Check(Veo.Core.BrowserSearch.Resolve("localhost:4321/index","Google").AbsoluteUri=="http://localhost:4321/index"&&Veo.Core.BrowserSearch.Resolve("127.0.0.1:4321","Google").Scheme=="http"&&Veo.Core.BrowserSearch.Resolve("[::1]:4321","Google").Scheme=="http","bare loopback addresses use HTTP");
Check(Veo.Core.BrowserSearch.Resolve("example.com/path","Google").Scheme=="https"&&Veo.Core.BrowserSearch.Resolve("hello world","ChatGPT").Query.Contains("temporary-chat=true"),"web address and ChatGPT temporary search resolution");
await Reject(()=>Task.FromResult(Veo.Core.BrowserSearch.Resolve("https://user:secret@example.com","Google")),"address rejects embedded credentials");
Check(BrowserConsoleMessages.ParseDevTools("{\"type\":\"log\",\"args\":[{\"value\":\"fixture\"},{\"value\":42},{\"description\":\"Object\"}]}")=="log: fixture 42 Object","DevTools console scalar and object values parse");
Check(BrowserConsoleMessages.ParseDevTools(new string('x',65537)).Length<100&&BrowserConsoleMessages.ParseDevTools(System.Text.Json.JsonSerializer.Serialize(new{type="log",args=new[]{new{value=new string('x',10000)}}})).Length<=4097,"console input and output bounded before UI retention");
await Reject(()=>Task.FromResult(BrowserConsoleMessages.ParseDevTools("{\"args\":false}")),"malformed console event rejected");
var store=new BrowserStateStore(root);await store.LoadAsync();var workspace=Path.Combine(root,"project");Directory.CreateDirectory(workspace);
var first=new NativeBrowserTab(Guid.NewGuid().ToString("N"),"https://example.com","One");var second=new NativeBrowserTab(Guid.NewGuid().ToString("N"),"https://example.org","Two");
await store.SaveWorkspaceAsync(workspace,new([second,first],first.Id,"Mobile"),true);var fresh=new BrowserStateStore(root);await fresh.LoadAsync();var restored=fresh.Restore(workspace,true)!;
Check(restored.Tabs[0].Id==second.Id&&restored.SelectedId==first.Id&&restored.Viewport=="Mobile","tab identity, order, selection and viewport persist");
Check(fresh.Restore(workspace,false)is null&&fresh.Restore(Path.Combine(root,"other"),true)is null,"restore opt-in and workspace isolation");
await fresh.SaveWorkspaceAsync(workspace,new([first],first.Id),false);var off=new BrowserStateStore(root);await off.LoadAsync();Check(off.Restore(workspace,true)is null,"turning restore off removes persisted workspace state");
var names=new[]{"../bad:name?.txt","CON","aux.txt","LPT1.txt","..","  ","report.txt:evil","a\\b/file.txt"};Check(names.All(x=>BrowserDownloadDestination.SafeFilename(x).IndexOfAny(Path.GetInvalidFileNameChars())<0)&&BrowserDownloadDestination.SafeFilename("CON")=="Download-CON","download filenames neutralize separators, devices and streams");
var a=BrowserDownloadDestination.Reserve("report.txt",workspace);var b=BrowserDownloadDestination.Reserve("report.txt",workspace);Check(a!=b&&File.Exists(a)&&File.Exists(b),"download collision reserves distinct real destinations");
var expected=Encoding.UTF8.GetBytes("Exact download bytes\r\n\0終");await File.WriteAllBytesAsync(a,expected);var verified=await BrowserDownloadDestination.VerifyAsync(a);Check(verified.Length==expected.Length&&verified.Sha256==Convert.ToHexString(SHA256.HashData(expected)),"completed download actual bytes read and SHA256 verified");
var html=Path.Combine(workspace,"index.html");await File.WriteAllTextAsync(html,"<h1>Preview</h1>");Check(Encoding.UTF8.GetString(await SafePreviewFiles.ReadAsync(workspace,html))=="<h1>Preview</h1>","local HTML bytes read through approved handle boundary");
Check(SafePreviewFiles.ResolveRequest(workspace,new("https://fixture.veo-preview.invalid/index.html"),"fixture.veo-preview.invalid")==html,"synthetic preview origin resolves relative resource");
await Reject(()=>Task.FromResult(SafePreviewFiles.ResolveRequest(workspace,new("https://fixture.veo-preview.invalid/%2e%2e%5csecret.txt"),"fixture.veo-preview.invalid")),"encoded slash traversal rejected");
await Reject(()=>Task.FromResult(SafePreviewFiles.ResolveRequest(workspace,new("https://other.invalid/index.html"),"fixture.veo-preview.invalid")),"unrelated preview origin rejected");
var outside=Path.Combine(root,"outside.html");await File.WriteAllTextAsync(outside,"secret");await Reject(()=>SafePreviewFiles.ReadAsync(workspace,outside),"outside workspace handle rejected");
var tooBig=Path.Combine(workspace,"large.html");using(var file=File.Create(tooBig))file.SetLength(SafePreviewFiles.MaximumBytes+1);await Reject(()=>SafePreviewFiles.ReadAsync(workspace,tooBig),"oversized preview rejected before allocation");
await Reject(()=>SafePreviewFiles.ReadAsync(workspace,html+":extra.html"),"alternate file streams rejected");
var unsupported=Path.Combine(workspace,"secret.db");await File.WriteAllTextAsync(unsupported,"secret");await Reject(()=>SafePreviewFiles.ReadAsync(workspace,unsupported),"unapproved MIME rejected");
var link=Path.Combine(workspace,"escape");var externalDir=Path.Combine(root,"external");Directory.CreateDirectory(externalDir);await File.WriteAllTextAsync(Path.Combine(externalDir,"linked.html"),"secret");
var start=new System.Diagnostics.ProcessStartInfo("cmd.exe"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};start.ArgumentList.Add("/c");start.ArgumentList.Add("mklink");start.ArgumentList.Add("/J");start.ArgumentList.Add(link);start.ArgumentList.Add(externalDir);using(var process=System.Diagnostics.Process.Start(start)!){await process.WaitForExitAsync();if(process.ExitCode!=0)throw new Exception(await process.StandardError.ReadToEndAsync());}
try{await Reject(()=>SafePreviewFiles.ReadAsync(workspace,Path.Combine(link,"linked.html")),"junction escape rejected by final opened handle");}finally{Directory.Delete(link);}
var vault=new BrowserCredentialStore(root);var origin=new Uri("https://credentials.example:444/a");
await Reject(()=>vault.SaveAsync(origin,"fixture-user","disposable-secret",false),"credential save refuses missing explicit confirmation");
if(args.Contains("--credentials")){
await vault.SaveAsync(origin,"fixture-user","disposable-secret",true);await vault.SaveAsync(origin,"fixture-user","realm-secret",true,"Http","realm-one");
var ids=await vault.ListAsync(origin);var http=await vault.ListAsync(origin,"Http","realm-one");
try{Check(ids.Count==1&&vault.Read(ids[0],origin)?.Secret=="disposable-secret","exact current-user form credential roundtrip");Check(http.Count==1&&vault.Read(http[0],origin)?.Secret=="realm-secret"&&(await vault.ListAsync(origin,"Http","realm-two")).Count==0,"HTTP realm remains separate from form and other realm");Check((await vault.ListAsync(new("https://credentials.example:445"))).Count==0,"credential different port not enumerated");await Reject(()=>Task.FromResult(vault.Read(ids[0],new("https://evil.example"))),"credential release refuses another origin");var index=await File.ReadAllTextAsync(Path.Combine(root,"Browser","credential-identities.json"));Check(!index.Contains("disposable-secret")&&!index.Contains("realm-secret"),"metadata index contains no secret");}finally{foreach(var id in ids.Concat(http))await vault.DeleteAsync(id);}Check((await vault.ListAsync(origin)).Count==0&&(await vault.ListAsync(origin,"Http","realm-one")).Count==0,"disposable credentials removed and absence reread");}
Console.WriteLine($"{count} browser checks passed.");
} finally { var full=Path.GetFullPath(root);if(Path.GetDirectoryName(full)==Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar)&&Path.GetFileName(full).StartsWith("veo-browser-tests-"))Directory.Delete(full,true); }
