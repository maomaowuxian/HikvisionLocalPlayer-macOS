namespace HikvisionLocalPlayer
{
    internal sealed class PlayerConfig
    {
        public string Host { get; set; }
        public string Username { get; set; }
        public string Password { get; set; }
        public int Channel { get; set; }
        public string Stream { get; set; }
        public string Layout { get; set; }
        public bool RememberPassword { get; set; }

        public static PlayerConfig Defaults()
        {
            return new PlayerConfig
            {
                Host = "",
                Username = "admin",
                Password = "",
                Channel = 1,
                Stream = "sub",
                Layout = "single",
                RememberPassword = false
            };
        }
    }
}
