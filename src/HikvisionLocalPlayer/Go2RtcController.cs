using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace HikvisionLocalPlayer
{
    internal sealed class Go2RtcController : IDisposable
    {
        private const string ResourcePrefix = "HikvisionLocalPlayer.Resources.";
        private const string ApiBase = "http://127.0.0.1:1984";
        private readonly HttpClient _client;
        private readonly string _runtimeDirectory;
        private Process _process;
        private bool _ownsProcess;

        public Go2RtcController()
        {
            _runtimeDirectory = AppPaths.RuntimeDirectory;
            _client = new HttpClient(new HttpClientHandler { UseProxy = false });
            _client.Timeout = TimeSpan.FromSeconds(12);
        }

        public void Start()
        {
            if (IsHealthyAsync().GetAwaiter().GetResult()) return;

            Directory.CreateDirectory(_runtimeDirectory);
            var executable = Path.Combine(_runtimeDirectory, "go2rtc");
            var config = Path.Combine(_runtimeDirectory, "go2rtc.yaml");
            ExtractIfChanged("go2rtc", executable);
            ExtractIfChanged("go2rtc-LICENSE", Path.Combine(_runtimeDirectory, "go2rtc-LICENSE"));
            EnsureExecutable(executable);
            WriteConfig(config);

            var startInfo = new ProcessStartInfo
            {
                FileName = executable,
                WorkingDirectory = _runtimeDirectory,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            startInfo.ArgumentList.Add("-config");
            startInfo.ArgumentList.Add(config);

            _process = Process.Start(startInfo);
            if (_process == null) throw new InvalidOperationException("播放引擎启动失败。");
            _ownsProcess = true;

            for (var attempt = 0; attempt < 50; attempt++)
            {
                if (_process.HasExited)
                    throw new InvalidOperationException("播放引擎意外退出，可能是本机端口 1984 被占用。");
                if (IsHealthyAsync().GetAwaiter().GetResult()) return;
                Thread.Sleep(150);
            }

            throw new TimeoutException("播放引擎启动超时。");
        }

        public async Task<bool> IsHealthyAsync()
        {
            try
            {
                using var response = await _client.GetAsync(ApiBase + "/api").ConfigureAwait(false);
                return response.IsSuccessStatusCode;
            }
            catch
            {
                return false;
            }
        }

        public async Task<bool> ConfigureAndProbeAsync(string streamId, string sourceUrl)
        {
            var patchUrl = ApiBase + "/api/streams?name=" + Uri.EscapeDataString(streamId)
                + "&src=" + Uri.EscapeDataString(sourceUrl);
            using var patchRequest = new HttpRequestMessage(new HttpMethod("PATCH"), patchUrl);
            using var patch = await _client.SendAsync(patchRequest).ConfigureAwait(false);
            if (!patch.IsSuccessStatusCode) return false;

            var probeUrl = ApiBase + "/api/streams?src=" + Uri.EscapeDataString(streamId)
                + "&video=all&audio=all";
            using var probe = await _client.GetAsync(probeUrl).ConfigureAwait(false);
            return probe.IsSuccessStatusCode;
        }

        public async Task DeleteStreamAsync(string streamId)
        {
            try
            {
                var url = ApiBase + "/api/streams?src=" + Uri.EscapeDataString(streamId);
                using var request = new HttpRequestMessage(HttpMethod.Delete, url);
                using var response = await _client.SendAsync(request).ConfigureAwait(false);
            }
            catch
            {
            }
        }

        private static void WriteConfig(string path)
        {
            var config =
                "api:\n" +
                "  listen: \"127.0.0.1:1984\"\n" +
                "  origin: \"*\"\n\n" +
                "rtsp:\n" +
                "  listen: \"127.0.0.1:8554\"\n\n" +
                "webrtc:\n" +
                "  listen: \"127.0.0.1:8555\"\n" +
                "  candidates:\n" +
                "    - \"127.0.0.1:8555\"\n\n" +
                "log:\n" +
                "  format: text\n" +
                "  level: warn\n\n" +
                "streams: {}\n";
            File.WriteAllText(path, config, new UTF8Encoding(false));
        }

        private static void ExtractIfChanged(string resourceName, string destination)
        {
            using (var source = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourcePrefix + resourceName))
            {
                if (source == null) throw new InvalidOperationException("内置资源缺失：" + resourceName);

                byte[] sourceHash;
                using (var sha = SHA256.Create()) sourceHash = sha.ComputeHash(source);
                source.Position = 0;

                if (File.Exists(destination))
                {
                    byte[] existingHash;
                    using (var file = File.OpenRead(destination))
                    using (var sha = SHA256.Create()) existingHash = sha.ComputeHash(file);
                    if (CryptographicOperations.FixedTimeEquals(sourceHash, existingHash)) return;
                }

                var temporary = destination + ".new";
                using (var output = File.Create(temporary)) source.CopyTo(output);
                File.Move(temporary, destination, true);
            }
        }

        private static void EnsureExecutable(string path)
        {
            File.SetUnixFileMode(
                path,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
                UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
                UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
        }

        public void Dispose()
        {
            DeleteStreamAsync("hik_local_player").GetAwaiter().GetResult();
            for (var index = 1; index <= 4; index++)
                DeleteStreamAsync("hik_grid_" + index).GetAwaiter().GetResult();

            if (_ownsProcess && _process != null)
            {
                try
                {
                    if (!_process.HasExited)
                    {
                        _process.Kill(true);
                        _process.WaitForExit(2000);
                    }
                }
                catch
                {
                }
            }

            _process?.Dispose();
            _client.Dispose();
        }
    }
}
