using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

internal static class BrowserFixtureServer
{
    public static readonly byte[] DownloadBytes=Encoding.UTF8.GetBytes("Veo browser download fixture\r\nExact UTF8 bytes: 終\r\n"+new string('x',32768));
    public static async Task RunAsync(string[] args)
    {
        var port=40972;var selected=args.FirstOrDefault(x=>x.StartsWith("--port="));if(selected is not null)port=int.Parse(selected[7..]);
        using var lifetime=new CancellationTokenSource(TimeSpan.FromMinutes(30));Console.CancelKeyPress+=(_,e)=>{e.Cancel=true;lifetime.Cancel();};
        var server=new TcpListener(IPAddress.Loopback,port);server.Start();Console.WriteLine($"Browser fixture http://127.0.0.1:{port}/ ; expected download {DownloadBytes.Length} bytes SHA256 {Convert.ToHexString(SHA256.HashData(DownloadBytes))}");
        try{while(!lifetime.IsCancellationRequested){var client=await server.AcceptTcpClientAsync(lifetime.Token);_ = HandleAsync(client,lifetime.Token);}}catch(OperationCanceledException){}finally{server.Stop();}
    }
    static async Task HandleAsync(TcpClient client,CancellationToken token)
    {
        using(client)try{
            using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(TimeSpan.FromSeconds(45));token=deadline.Token;
            await using var stream=client.GetStream();var headers=new List<byte>();var buffer=new byte[1];
            while(headers.Count<16384){var count=await stream.ReadAsync(buffer,token);if(count==0)return;headers.Add(buffer[0]);if(headers.Count>=4&&headers.TakeLast(4).SequenceEqual(new byte[]{13,10,13,10}))break;}
            var text=Encoding.ASCII.GetString(headers.ToArray());var request=text.Split('\n')[0].Split(' ');if(request.Length<2)return;var path=request[1].Split('?')[0];
            if(path=="/download"||path=="/slow"){
                var body=path=="/download"?DownloadBytes:new byte[4*1024*1024];await WriteHeader(stream,"200 OK","application/octet-stream",body.Length,"Content-Disposition: attachment; filename=\"veo-browser-fixture"+(path=="/slow"?"-slow.bin":".txt")+"\"\r\n",token);
                for(var offset=0;offset<body.Length;offset+=16384){await stream.WriteAsync(body.AsMemory(offset,Math.Min(16384,body.Length-offset)),token);if(path=="/slow")await Task.Delay(125,token);}Console.WriteLine("Completed "+path);return;
            }
            if(path=="/auth"){
                var authorized=text.Split('\n').Any(line=>line.TrimEnd('\r').Equals("Authorization: Basic "+Convert.ToBase64String(Encoding.UTF8.GetBytes("fixture-user:fixture-password")),StringComparison.OrdinalIgnoreCase));
                var body=Encoding.UTF8.GetBytes(authorized?"<h1>Authentication accepted</h1>":"Authentication required");await WriteHeader(stream,authorized?"200 OK":"401 Unauthorized","text/html; charset=utf-8",body.Length,authorized?"":"WWW-Authenticate: Basic realm=\"Veo browser fixture\"\r\n",token);await stream.WriteAsync(body,token);Console.WriteLine("Authentication challenge outcome "+authorized);return;
            }
            var html=path=="/submitted"?"<h1>Same-origin form submitted</h1>":"""
            <!doctype html><meta charset="utf-8"><title>Veo browser fixture</title>
            <h1>Veo browser fixture</h1><p>Local test data only. No real credentials.</p>
            <p><a href="/download">Download exact fixture</a> <a href="/slow">Slow download for cancellation</a> <a href="/auth">HTTP authentication</a></p>
            <p><button onclick="window.open('/popup','fixture')">Open popup</button><button onclick="console.log('fixture-console',42)">Write console</button></p>
            <form action="/submitted" method="get"><label>Username <input name="username" autocomplete="username" value="fixture-user"></label><label>Password <input type="password" name="password" autocomplete="current-password" value="fixture-password"></label><button>Submit fixture credentials</button></form>
            <script>console.log('fixture-ready',42);</script>
            """;
            if(path=="/popup")html="<title>Fixture popup</title><h1>Popup shares Veo browser profile</h1><button onclick='window.close()'>Close popup</button>";
            var bytes=Encoding.UTF8.GetBytes(html);await WriteHeader(stream,"200 OK","text/html; charset=utf-8",bytes.Length,"",token);await stream.WriteAsync(bytes,token);
        }catch(Exception error)when(error is IOException or SocketException or OperationCanceledException){Console.WriteLine("Fixture connection ended: "+error.GetType().Name);}
    }
    static Task WriteHeader(Stream stream,string status,string type,int length,string extra,CancellationToken token)=>stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Type: {type}\r\nContent-Length: {length}\r\nCache-Control: no-store\r\nConnection: close\r\n{extra}\r\n"),token).AsTask();
}
