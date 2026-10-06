using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace HikvisionLocalPlayer
{
    internal sealed class AppServer : IDisposable
    {
        private const string StreamId = "hik_local_player";
        private static readonly string[] GridStreamIds =
        {
            "hik_grid_1", "hik_grid_2", "hik_grid_3", "hik_grid_4"
        };
        private const string ResourcePrefix = "HikvisionLocalPlayer.Resources.";
        private readonly Go2RtcController _media;
        private readonly DeviceClient _device = new DeviceClient();
        private readonly SettingsStore _settings = new SettingsStore();
        private readonly JsonSerializerOptions _jsonOptions = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        };
        private TcpListener _listener;
        private bool _stopping;

        public AppServer(Go2RtcController media)
        {
            _media = media;
        }

        public void Start()
        {
            try
            {
                _listener = new TcpListener(IPAddress.Loopback, 1985);
                _listener.Start();
                Task.Run((Func<Task>)AcceptLoopAsync);
            }
            catch (SocketException)
            {
                throw new InvalidOperationException("本机端口 1985 被占用，无法启动播放器界面。");
            }
        }

        private async Task AcceptLoopAsync()
        {
            while (!_stopping)
            {
                TcpClient client;
                try
                {
                    client = await _listener.AcceptTcpClientAsync().ConfigureAwait(false);
                }
                catch
                {
                    if (_stopping) return;
                    continue;
                }

                _ = Task.Run(() => HandleClientAsync(client));
            }
        }

        private async Task HandleClientAsync(TcpClient client)
        {
            using (client)
            {
                client.ReceiveTimeout = 15000;
                client.SendTimeout = 15000;
                Exception failure = null;
                try
                {
                    var request = await ReadRequestAsync(client.GetStream()).ConfigureAwait(false);
                    if (request == null) return;
                    await RouteAsync(client.GetStream(), request).ConfigureAwait(false);
                }
                catch (Exception error)
                {
                    failure = error;
                }

                if (failure == null) return;
                try
                {
                    await SendJsonAsync(client.GetStream(), 500, new
                    {
                        ok = false,
                        message = FriendlyMessage(failure)
                    }).ConfigureAwait(false);
                }
                catch
                {
                }
            }
        }

        private async Task RouteAsync(NetworkStream stream, HttpRequest request)
        {
            var path = request.Path.Split('?')[0];
            if (request.Method == "GET" && path == "/")
            {
                await SendResourceAsync(stream, "index.html", "text/html; charset=utf-8").ConfigureAwait(false);
                return;
            }
            if (request.Method == "GET" && path == "/app.css")
            {
                await SendResourceAsync(stream, "app.css", "text/css; charset=utf-8").ConfigureAwait(false);
                return;
            }
            if (request.Method == "GET" && path == "/app.js")
            {
                await SendResourceAsync(stream, "app.js", "application/javascript; charset=utf-8").ConfigureAwait(false);
                return;
            }
            if (request.Method == "GET" && path == "/app-icon.svg")
            {
                await SendResourceAsync(stream, "app-icon.svg", "image/svg+xml; charset=utf-8").ConfigureAwait(false);
                return;
            }
            if (request.Method == "GET" && path == "/favicon.ico")
            {
                await SendResourceAsync(stream, "app-icon.svg", "image/svg+xml; charset=utf-8").ConfigureAwait(false);
                return;
            }
            if (request.Method == "GET" && path == "/api/settings")
            {
                await SendJsonAsync(stream, 200, new { ok = true, settings = _settings.Load() }).ConfigureAwait(false);
                return;
            }
            if (request.Method == "GET" && path == "/api/health")
            {
                var healthy = await _media.IsHealthyAsync().ConfigureAwait(false);
                await SendJsonAsync(stream, healthy ? 200 : 503, new { ok = healthy }).ConfigureAwait(false);
                return;
            }
            if (request.Method == "POST" && path == "/api/shutdown")
            {
                await SendJsonAsync(stream, 200, new { ok = true }).ConfigureAwait(false);
                Program.RequestShutdown();
                return;
            }
            if (request.Method == "POST" && path == "/api/discover")
            {
                var config = ParseAndValidateConfig(request.Body, false);
                var ids = await _device.DiscoverChannelsAsync(config.Host, config.Username, config.Password).ConfigureAwait(false);
                if (ids.Count == 0)
                    throw new InvalidOperationException("无法读取录像机通道，请检查地址、用户名和密码。");

                await SendJsonAsync(stream, 200, new
                {
                    ok = true,
                    channels = ids.Select((id, index) => new { channel = index + 1, deviceId = id }).ToArray()
                }).ConfigureAwait(false);
                return;
            }
            if (request.Method == "POST" && path == "/api/connect")
            {
                await ConnectAsync(stream, request.Body).ConfigureAwait(false);
                return;
            }
            if (request.Method == "POST" && path == "/api/disconnect")
            {
                await DeleteAllStreamsAsync().ConfigureAwait(false);
                await SendJsonAsync(stream, 200, new { ok = true }).ConfigureAwait(false);
                return;
            }

            await SendJsonAsync(stream, 404, new { ok = false, message = "未找到请求的功能。" }).ConfigureAwait(false);
        }

        private async Task ConnectAsync(NetworkStream stream, string body)
        {
            var config = ParseAndValidateConfig(body, true);
            _settings.Save(config);

            var channelIds = await _device.DiscoverChannelsAsync(config.Host, config.Username, config.Password).ConfigureAwait(false);
            if (channelIds.Count == 0)
                throw new InvalidOperationException("无法读取录像机通道，请检查地址、用户名和密码。");
            if (config.Layout != "grid4" && config.Channel > channelIds.Count)
                throw new InvalidOperationException("录像机只返回了 " + channelIds.Count + " 个可用通道。");

            ConnectedPlayer[] players;
            var targetCount = 1;
            if (config.Layout == "grid4")
            {
                await _media.DeleteStreamAsync(StreamId).ConfigureAwait(false);
                var targets = channelIds.Take(4).ToArray();
                targetCount = targets.Length;
                var tasks = targets.Select((deviceId, index) => ConnectChannelAsync(
                    config,
                    index + 1,
                    deviceId,
                    GridStreamIds[index])).ToArray();
                var results = await Task.WhenAll(tasks).ConfigureAwait(false);
                players = results.Where(player => player != null).ToArray();

                for (var index = targets.Length; index < GridStreamIds.Length; index++)
                    await _media.DeleteStreamAsync(GridStreamIds[index]).ConfigureAwait(false);
            }
            else
            {
                foreach (var gridStreamId in GridStreamIds)
                    await _media.DeleteStreamAsync(gridStreamId).ConfigureAwait(false);

                var player = await ConnectChannelAsync(
                    config,
                    config.Channel,
                    channelIds[config.Channel - 1],
                    StreamId).ConfigureAwait(false);
                players = player == null ? Array.Empty<ConnectedPlayer>() : new[] { player };
            }

            if (players.Length == 0)
                throw new InvalidOperationException("所选通道均拒绝了 RTSP 预览，请确认摄像头在线，并检查录像机是否已启用 RTSP 服务。");

            await SendJsonAsync(stream, 200, new
            {
                ok = true,
                layout = config.Layout,
                players = players,
                requestedCount = targetCount,
                failedCount = targetCount - players.Length
            }).ConfigureAwait(false);
        }

        private async Task<ConnectedPlayer> ConnectChannelAsync(
            PlayerConfig config,
            int logicalChannel,
            int deviceChannelId,
            string streamId)
        {
            var activeStream = config.Stream;
            var fallbackUsed = false;
            var source = DeviceClient.BuildRtspUrl(
                config.Host, config.Username, config.Password, deviceChannelId, activeStream);
            var connected = await TryConfigureAsync(streamId, source).ConfigureAwait(false);

            if (!connected && activeStream == "sub")
            {
                activeStream = "main";
                fallbackUsed = true;
                source = DeviceClient.BuildRtspUrl(
                    config.Host, config.Username, config.Password, deviceChannelId, activeStream);
                connected = await TryConfigureAsync(streamId, source).ConfigureAwait(false);
            }

            if (!connected) return null;
            return new ConnectedPlayer
            {
                channel = logicalChannel,
                deviceChannelId = deviceChannelId,
                stream = activeStream,
                fallbackUsed = fallbackUsed,
                playerUrl = "http://127.0.0.1:1984/stream.html?src=" + streamId + "&mode=webrtc,mse"
            };
        }

        private async Task<bool> TryConfigureAsync(string streamId, string source)
        {
            try
            {
                return await _media.ConfigureAndProbeAsync(streamId, source).ConfigureAwait(false);
            }
            catch
            {
                return false;
            }
        }

        private async Task DeleteAllStreamsAsync()
        {
            await _media.DeleteStreamAsync(StreamId).ConfigureAwait(false);
            foreach (var gridStreamId in GridStreamIds)
                await _media.DeleteStreamAsync(gridStreamId).ConfigureAwait(false);
        }

        private PlayerConfig ParseAndValidateConfig(string body, bool requireChannel)
        {
            PlayerConfig config;
            try
            {
                config = JsonSerializer.Deserialize<PlayerConfig>(body, _jsonOptions);
            }
            catch
            {
                throw new InvalidOperationException("连接信息格式不正确。");
            }

            if (config == null) throw new InvalidOperationException("请填写连接信息。");
            config.Host = DeviceClient.CleanHost(config.Host);
            config.Username = (config.Username ?? "").Trim();
            config.Password = config.Password ?? "";
            config.Stream = (config.Stream ?? "sub").ToLowerInvariant();
            config.Layout = (config.Layout ?? "single").ToLowerInvariant();

            if (config.Host.Length == 0 || config.Host.Contains("/") || config.Host.Contains(" "))
                throw new InvalidOperationException("请输入正确的录像机 IP 地址，例如 192.168.1.100。");
            if (config.Username.Length == 0 || config.Password.Length == 0)
                throw new InvalidOperationException("请输入录像机用户名和密码。");
            if (requireChannel && config.Channel < 1)
                throw new InvalidOperationException("请选择要播放的通道。");
            if (config.Stream != "main" && config.Stream != "sub") config.Stream = "sub";
            if (config.Layout != "single" && config.Layout != "grid4") config.Layout = "single";
            return config;
        }

        private async Task SendResourceAsync(NetworkStream stream, string name, string contentType)
        {
            using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourcePrefix + name))
            {
                if (resource == null) throw new InvalidOperationException("界面资源缺失：" + name);
                var bytes = new byte[resource.Length];
                var read = 0;
                while (read < bytes.Length)
                {
                    var count = await resource.ReadAsync(bytes, read, bytes.Length - read).ConfigureAwait(false);
                    if (count == 0) break;
                    read += count;
                }
                await SendAsync(stream, 200, "OK", contentType, bytes).ConfigureAwait(false);
            }
        }

        private Task SendJsonAsync(NetworkStream stream, int statusCode, object value)
        {
            var json = JsonSerializer.Serialize(value, _jsonOptions);
            var description = statusCode == 200 ? "OK" : statusCode == 404 ? "Not Found" : "Error";
            return SendAsync(stream, statusCode, description, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json));
        }

        private static async Task SendAsync(NetworkStream stream, int statusCode, string description, string contentType, byte[] body)
        {
            var header = string.Format(
                "HTTP/1.1 {0} {1}\r\nContent-Type: {2}\r\nContent-Length: {3}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
                statusCode, description, contentType, body.Length);
            var headerBytes = Encoding.ASCII.GetBytes(header);
            await stream.WriteAsync(headerBytes, 0, headerBytes.Length).ConfigureAwait(false);
            await stream.WriteAsync(body, 0, body.Length).ConfigureAwait(false);
            await stream.FlushAsync().ConfigureAwait(false);
        }

        private static async Task<HttpRequest> ReadRequestAsync(NetworkStream stream)
        {
            var buffer = new byte[4096];
            var received = new MemoryStream();
            var headerEnd = -1;

            while (received.Length < 32768 && headerEnd < 0)
            {
                var count = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (count == 0) return null;
                received.Write(buffer, 0, count);
                headerEnd = FindHeaderEnd(received.GetBuffer(), (int)received.Length);
            }
            if (headerEnd < 0) throw new InvalidOperationException("请求头过大。");

            var all = received.ToArray();
            var headerText = Encoding.ASCII.GetString(all, 0, headerEnd);
            var lines = headerText.Split(new[] { "\r\n" }, StringSplitOptions.None);
            var first = lines[0].Split(' ');
            if (first.Length < 2) throw new InvalidOperationException("请求无效。");

            var contentLength = 0;
            foreach (var line in lines.Skip(1))
            {
                var separator = line.IndexOf(':');
                if (separator <= 0) continue;
                if (line.Substring(0, separator).Trim().Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                    int.TryParse(line.Substring(separator + 1).Trim(), out contentLength);
            }
            if (contentLength > 1024 * 1024) throw new InvalidOperationException("请求内容过大。");

            var bodyOffset = headerEnd + 4;
            var body = new byte[contentLength];
            var available = Math.Min(contentLength, all.Length - bodyOffset);
            if (available > 0) Buffer.BlockCopy(all, bodyOffset, body, 0, available);
            var total = available;
            while (total < contentLength)
            {
                var count = await stream.ReadAsync(body, total, contentLength - total).ConfigureAwait(false);
                if (count == 0) break;
                total += count;
            }

            return new HttpRequest
            {
                Method = first[0].ToUpperInvariant(),
                Path = first[1],
                Body = Encoding.UTF8.GetString(body, 0, total)
            };
        }

        private static int FindHeaderEnd(byte[] bytes, int length)
        {
            for (var i = 0; i <= length - 4; i++)
            {
                if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) return i;
            }
            return -1;
        }

        private static string FriendlyMessage(Exception error)
        {
            var current = error;
            while (current.InnerException != null) current = current.InnerException;
            if (current is TaskCanceledException) return "连接超时，请检查录像机地址和网络。";
            if (current is SocketException) return "无法连接录像机，请检查 IP 地址和网络。";
            return error.Message;
        }

        public void Dispose()
        {
            _stopping = true;
            _listener?.Stop();
        }

        private sealed class HttpRequest
        {
            public string Method;
            public string Path;
            public string Body;
        }

        private sealed class ConnectedPlayer
        {
            public int channel { get; set; }
            public int deviceChannelId { get; set; }
            public string stream { get; set; }
            public bool fallbackUsed { get; set; }
            public string playerUrl { get; set; }
        }
    }
}
