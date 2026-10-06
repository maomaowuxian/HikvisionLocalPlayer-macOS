using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace HikvisionLocalPlayer
{
    internal sealed class SettingsStore
    {
        private const string KeychainService = "io.github.maomaowuxian.hikvisionlocalplayer";
        private readonly string _settingsPath;

        public SettingsStore()
        {
            Directory.CreateDirectory(AppPaths.ApplicationSupportDirectory);
            _settingsPath = Path.Combine(AppPaths.ApplicationSupportDirectory, "settings.dat");
        }

        public PlayerConfig Load()
        {
            var result = PlayerConfig.Defaults();
            if (!File.Exists(_settingsPath)) return result;

            try
            {
                var values = ReadValues();
                result.Host = Decode(values, "host", result.Host);
                result.Username = Decode(values, "username", result.Username);
                result.Stream = Decode(values, "stream", result.Stream);
                result.Layout = Decode(values, "layout", result.Layout);

                if (values.TryGetValue("channel", out var channelText) &&
                    int.TryParse(channelText, out var channel) && channel > 0)
                    result.Channel = channel;

                if (values.TryGetValue("remember", out var rememberText) &&
                    bool.TryParse(rememberText, out var remember))
                    result.RememberPassword = remember;

                if (result.RememberPassword)
                {
                    var account = Decode(values, "keychainAccount", BuildKeychainAccount(result));
                    result.Password = Keychain.Read(account);
                }
            }
            catch
            {
                return PlayerConfig.Defaults();
            }

            return result;
        }

        public void Save(PlayerConfig config)
        {
            var oldValues = ReadValues();
            var oldAccount = Decode(oldValues, "keychainAccount", "");
            var newAccount = BuildKeychainAccount(config);

            if (config.RememberPassword && !string.IsNullOrEmpty(config.Password))
            {
                if (!string.IsNullOrEmpty(oldAccount) &&
                    !string.Equals(oldAccount, newAccount, StringComparison.Ordinal))
                    Keychain.Delete(oldAccount);

                Keychain.Write(newAccount, config.Password);
            }
            else
            {
                if (!string.IsNullOrEmpty(oldAccount)) Keychain.Delete(oldAccount);
                Keychain.Delete(newAccount);
            }

            var lines = new[]
            {
                "version=2",
                "host=" + Encode(config.Host),
                "username=" + Encode(config.Username),
                "channel=" + config.Channel,
                "stream=" + Encode(config.Stream),
                "layout=" + Encode(config.Layout),
                "remember=" + config.RememberPassword,
                "keychainAccount=" + Encode(config.RememberPassword ? newAccount : "")
            };

            var temporary = _settingsPath + ".new";
            File.WriteAllLines(temporary, lines, new UTF8Encoding(false));
            File.Move(temporary, _settingsPath, true);
        }

        private Dictionary<string, string> ReadValues()
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (!File.Exists(_settingsPath)) return values;

            foreach (var line in File.ReadAllLines(_settingsPath, Encoding.UTF8))
            {
                var separator = line.IndexOf('=');
                if (separator <= 0) continue;
                values[line.Substring(0, separator)] = line.Substring(separator + 1);
            }

            return values;
        }

        private static string BuildKeychainAccount(PlayerConfig config)
        {
            return (config.Username ?? "") + "@" + (config.Host ?? "");
        }

        private static string Encode(string value)
        {
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? ""));
        }

        private static string Decode(Dictionary<string, string> values, string key, string fallback)
        {
            if (!values.TryGetValue(key, out var value) || string.IsNullOrEmpty(value)) return fallback;
            return Encoding.UTF8.GetString(Convert.FromBase64String(value));
        }

        private static class Keychain
        {
            public static string Read(string account)
            {
                if (string.IsNullOrEmpty(account)) return "";
                var result = Run("find-generic-password", "-a", account, "-s", KeychainService, "-w");
                return result.ExitCode == 0 ? result.StandardOutput.TrimEnd('\r', '\n') : "";
            }

            public static void Write(string account, string password)
            {
                var result = Run(
                    "add-generic-password",
                    "-U",
                    "-a", account,
                    "-s", KeychainService,
                    "-w", password ?? "");

                if (result.ExitCode != 0)
                    throw new InvalidOperationException("无法将录像机密码保存到 macOS 钥匙串。");
            }

            public static void Delete(string account)
            {
                if (string.IsNullOrEmpty(account)) return;
                Run("delete-generic-password", "-a", account, "-s", KeychainService);
            }

            private static ProcessResult Run(params string[] arguments)
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = "/usr/bin/security",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);

                using var process = Process.Start(startInfo);
                if (process == null) return new ProcessResult(-1, "");

                var output = process.StandardOutput.ReadToEnd();
                process.StandardError.ReadToEnd();
                if (!process.WaitForExit(5000))
                {
                    try { process.Kill(true); } catch { }
                    return new ProcessResult(-1, output);
                }

                return new ProcessResult(process.ExitCode, output);
            }

            private readonly struct ProcessResult
            {
                public ProcessResult(int exitCode, string standardOutput)
                {
                    ExitCode = exitCode;
                    StandardOutput = standardOutput;
                }

                public int ExitCode { get; }
                public string StandardOutput { get; }
            }
        }
    }
}
