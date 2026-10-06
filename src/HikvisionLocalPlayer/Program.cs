using System;
using System.IO;
using System.Threading;

namespace HikvisionLocalPlayer
{
    internal static class AppPaths
    {
        private static readonly string BaseDirectory = ResolveBaseDirectory();

        private static string ResolveBaseDirectory()
        {
            var overrideDirectory = Environment.GetEnvironmentVariable("HIKVISION_PLAYER_DATA_DIR");
            if (!string.IsNullOrWhiteSpace(overrideDirectory)) return Path.GetFullPath(overrideDirectory);

            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "Library",
                "Application Support",
                "HikvisionLocalPlayer");
        }

        public static string ApplicationSupportDirectory => BaseDirectory;
        public static string RuntimeDirectory => Path.Combine(BaseDirectory, "Runtime");
    }

    internal static class Program
    {
        private static readonly ManualResetEventSlim ShutdownEvent = new ManualResetEventSlim(false);

        private static void Main()
        {
            bool createdNew;
            using (var mutex = new Mutex(true, "HikvisionLocalPlayer.Backend.SingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    Console.Error.WriteLine("海康威视播放器后台服务已经在运行。");
                    return;
                }

                Console.CancelKeyPress += (_, args) =>
                {
                    args.Cancel = true;
                    RequestShutdown();
                };

                try
                {
                    using (var media = new Go2RtcController())
                    using (var server = new AppServer(media))
                    {
                        media.Start();
                        server.Start();
                        Console.WriteLine("READY http://127.0.0.1:1985/");
                        Console.Out.Flush();
                        ShutdownEvent.Wait();
                    }
                }
                catch (Exception error)
                {
                    Console.Error.WriteLine("播放器后台服务启动失败：" + error);
                    Environment.ExitCode = 1;
                }
            }
        }

        internal static void RequestShutdown()
        {
            ShutdownEvent.Set();
        }
    }
}
