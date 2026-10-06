using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Xml.Linq;

namespace HikvisionLocalPlayer
{
    internal sealed class DeviceClient
    {
        private sealed class ChannelEndpoint
        {
            public string Path;
            public string Node;
        }

        private sealed class AuthProbeResult : IDisposable
        {
            public HttpResponseMessage Response;
            public string LockStatus;
            public int? UnlockTime;
            public int? RetryLoginTime;

            public void Dispose()
            {
                Response?.Dispose();
            }
        }

        public async Task<List<int>> DiscoverChannelsAsync(string host, string username, string password)
        {
            // Important for older Hikvision firmware:
            // do ONE credential probe only. Repeated failed auth attempts can trigger
            // Illegal Login Lock and make a correct password appear invalid.
            using (var probe = await ProbeCredentialsAsync(host, username, password).ConfigureAwait(false))
            {
                if (!probe.Response.IsSuccessStatusCode)
                    throw new UnauthorizedAccessException(BuildAuthFailureMessage(probe));
            }

            var endpoints = new[]
            {
                new ChannelEndpoint { Path = "/ISAPI/System/Video/inputs/channels", Node = "VideoInputChannel" },
                new ChannelEndpoint { Path = "/ISAPI/ContentMgmt/InputProxy/channels", Node = "InputProxyChannel" }
            };

            var ids = new List<int>();
            var failures = new List<string>();

            // Authentication has already succeeded above, so channel requests should
            // not consume failed-login attempts.
            foreach (var endpoint in endpoints)
            {
                try
                {
                    using var response = await SendManagedCredentialsAsync(
                        "http://" + host + endpoint.Path, username, password).ConfigureAwait(false);

                    if (!response.IsSuccessStatusCode)
                    {
                        failures.Add(endpoint.Path + "：HTTP " + (int)response.StatusCode);
                        continue;
                    }

                    var content = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                    var xml = XDocument.Parse(Encoding.UTF8.GetString(content));
                    foreach (var channel in xml.Descendants().Where(x => x.Name.LocalName == endpoint.Node))
                    {
                        var idNode = channel.Elements().FirstOrDefault(x => x.Name.LocalName == "id");
                        if (idNode != null && int.TryParse(idNode.Value, out var id) && id > 0)
                            ids.Add(id);
                    }
                }
                catch (TaskCanceledException)
                {
                    failures.Add(endpoint.Path + "：连接超时");
                }
                catch (HttpRequestException error)
                {
                    failures.Add(endpoint.Path + "：网络错误 " + error.Message);
                }
                catch (Exception error)
                {
                    failures.Add(endpoint.Path + "：" + error.Message);
                }
            }

            var result = ids.Distinct().OrderBy(id => id).ToList();
            if (result.Count > 0) return result;

            if (failures.Count > 0)
                throw new InvalidOperationException("认证已通过，但无法读取录像机通道：" + string.Join("；", failures));

            throw new InvalidOperationException("认证已通过，但录像机没有返回可用通道。");
        }

        private static async Task<AuthProbeResult> ProbeCredentialsAsync(
            string host,
            string username,
            string password)
        {
            var url = "http://" + host + "/ISAPI/Security/userCheck";
            var response = await SendManagedCredentialsAsync(url, username, password).ConfigureAwait(false);

            var result = new AuthProbeResult { Response = response };
            if (response.Content == null) return result;

            try
            {
                var bytes = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                if (bytes.Length == 0) return result;

                // Replace consumed content so callers can still dispose the response normally.
                response.Content = new ByteArrayContent(bytes);
                var xml = XDocument.Parse(Encoding.UTF8.GetString(bytes));

                result.LockStatus = FindValue(xml, "lockStatus");
                if (int.TryParse(FindValue(xml, "unlockTime"), out var unlockTime))
                    result.UnlockTime = unlockTime;
                if (int.TryParse(FindValue(xml, "retryLoginTime"), out var retryLoginTime))
                    result.RetryLoginTime = retryLoginTime;
            }
            catch
            {
                // Older firmware may omit these optional diagnostic fields.
            }

            return result;
        }

        private static string FindValue(XDocument xml, string localName)
        {
            return xml.Descendants()
                .FirstOrDefault(element => element.Name.LocalName == localName)
                ?.Value
                ?.Trim();
        }

        private static string BuildAuthFailureMessage(AuthProbeResult probe)
        {
            var builder = new StringBuilder();
            builder.Append("录像机身份验证失败（HTTP ")
                .Append((int)probe.Response.StatusCode)
                .Append("）。");

            if (string.Equals(probe.LockStatus, "lock", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(probe.LockStatus, "locked", StringComparison.OrdinalIgnoreCase))
            {
                builder.Append(" 当前访问端已被录像机锁定");
                if (probe.UnlockTime.HasValue && probe.UnlockTime.Value > 0)
                    builder.Append("，预计 ").Append(probe.UnlockTime.Value).Append(" 秒后解锁");
                builder.Append("。锁定期间请不要继续重试，否则部分机型会重新计算锁定时间。");
                return builder.ToString();
            }

            if (!string.IsNullOrWhiteSpace(probe.LockStatus))
                builder.Append(" lockStatus=").Append(probe.LockStatus).Append("。");

            if (probe.RetryLoginTime.HasValue)
                builder.Append(" 剩余允许尝试次数=").Append(probe.RetryLoginTime.Value).Append("。");

            if (probe.UnlockTime.HasValue && probe.UnlockTime.Value > 0)
                builder.Append(" unlockTime=").Append(probe.UnlockTime.Value).Append(" 秒。");

            builder.Append(" Windows 端同账号正常时，请优先怀疑当前 Mac 来源地址被临时限制，而不是密码错误。");
            return builder.ToString();
        }

        private static async Task<HttpResponseMessage> SendManagedCredentialsAsync(
            string url,
            string username,
            string password)
        {
            var handler = new HttpClientHandler
            {
                Credentials = new NetworkCredential(username, password),
                PreAuthenticate = false,
                UseProxy = false,
                AllowAutoRedirect = false,
                UseCookies = false
            };

            var client = new HttpClient(handler)
            {
                Timeout = TimeSpan.FromSeconds(7)
            };

            try
            {
                var response = await client.GetAsync(url).ConfigureAwait(false);
                return new OwnedHttpResponseMessage(response, client, handler);
            }
            catch
            {
                client.Dispose();
                handler.Dispose();
                throw;
            }
        }

        private sealed class OwnedHttpResponseMessage : HttpResponseMessage
        {
            private readonly HttpResponseMessage _inner;
            private readonly HttpClient _client;
            private readonly HttpClientHandler _handler;

            public OwnedHttpResponseMessage(
                HttpResponseMessage inner,
                HttpClient client,
                HttpClientHandler handler)
                : base(inner.StatusCode)
            {
                _inner = inner;
                _client = client;
                _handler = handler;

                ReasonPhrase = inner.ReasonPhrase;
                Version = inner.Version;
                RequestMessage = inner.RequestMessage;
                Content = inner.Content;

                foreach (var header in inner.Headers)
                    Headers.TryAddWithoutValidation(header.Key, header.Value);
            }

            protected override void Dispose(bool disposing)
            {
                if (disposing)
                {
                    _inner.Content = null;
                    _inner.Dispose();
                    _client.Dispose();
                    _handler.Dispose();
                }

                base.Dispose(disposing);
            }
        }

        public static string CleanHost(string value)
        {
            value = (value ?? "").Trim();
            if (value.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) value = value.Substring(7);
            if (value.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) value = value.Substring(8);
            return value.TrimEnd('/');
        }

        public static string BuildRtspUrl(string host, string username, string password, int deviceChannelId, string stream)
        {
            var trackId = deviceChannelId * 100 + (stream == "main" ? 1 : 2);
            return string.Format(
                "rtsp://{0}:{1}@{2}:554/PSIA/streaming/channels/{3}",
                Uri.EscapeDataString(username),
                Uri.EscapeDataString(password),
                host,
                trackId);
        }
    }
}
