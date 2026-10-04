// Compiled by Install-SkyrimMods.ps1, never executed by validation.
// Normal Steam launch entrypoint -> SKSE -> original SkyrimSE.exe.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class SteamSkyrimBridge
{
    private static string LogDirectory;

    [STAThread]
    private static int Main()
    {
        LogDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                    "SkyrimModInstaller", "LaunchLogs");
        bool owned = false;
        using (Mutex mutex = new Mutex(false, @"Local\SteamSkyrimBridge-489830"))
        {
            try
            {
                try { owned = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { owned = true; }
                if (!owned) return 0; // Repeated Steam Play does not start another game.
                string gameDirectory = AppDomain.CurrentDomain.BaseDirectory;
                string receiptPath = Path.Combine(gameDirectory, "SteamSkyrimBridge.json");
                if (!File.Exists(receiptPath))
                    throw new InvalidOperationException("The mod installation receipt is missing. Complete Install-SkyrimMods.ps1 before playing.");

                string version = ValidateReceipt(gameDirectory, File.ReadAllText(receiptPath));

                if (Process.GetProcessesByName("steam").Length == 0)
                    throw new InvalidOperationException("Start Steam and use Skyrim Special Edition's normal Play button (or Steam Remote Play).");
                if (Process.GetProcessesByName("SkyrimSE").Length != 0) return 0;
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = Path.Combine(gameDirectory, "skse64_loader.exe");
                start.Arguments = "-waitforclose";
                start.WorkingDirectory = gameDirectory;
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.EnvironmentVariables["SteamAppId"] = "489830";
                start.EnvironmentVariables["SteamGameId"] = "489830";
                Log("Starting SKSE for runtime " + version + " through the normal Steam entrypoint.");
                using (Process loader = Process.Start(start))
                {
                    if (loader == null) throw new InvalidOperationException("Windows did not create the SKSE process.");
                    // Official SKSE -waitforclose keeps the launch process alive for the
                    // full game session, allowing Steam/Remote Play to track the session.
                    loader.WaitForExit();
                    if (loader.ExitCode != 0)
                        throw new InvalidOperationException("SKSE exited with code " + loader.ExitCode +
                            ". Inspect SKSE logs in Documents\\My Games\\Skyrim Special Edition\\SKSE. No unmodded fallback was launched.");
                }
                Log("SKSE/game session ended.");
                return 0;
            }
            catch (Exception error)
            {
                Log(error.ToString());
                MessageBox.Show(error.Message + "\r\n\r\nLaunch log: " + LogDirectory,
                                "Skyrim Steam launch failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            finally { if (owned) mutex.ReleaseMutex(); }
        }
    }

    // Kept separate from Main so receipt validation can be tested without starting Steam/SKSE.
    internal static string ValidateReceipt(string gameDirectory, string json)
    {
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        var receipt = serializer.Deserialize<Dictionary<string, object>>(json);
        if (receipt != null && receipt.ContainsKey("Pending") && Convert.ToBoolean(receipt["Pending"]))
            throw new InvalidOperationException("Mod installation was interrupted or is still in progress. Finish Install-SkyrimMods.ps1 -Mode Install -Resume before playing.");
        if (receipt == null || !receipt.ContainsKey("SchemaVersion") || Convert.ToInt32(receipt["SchemaVersion"]) != 2 ||
            !receipt.ContainsKey("InstallListVersion") || Convert.ToString(receipt["InstallListVersion"]) != "V2" ||
            !receipt.ContainsKey("RenderingFramework") || Convert.ToString(receipt["RenderingFramework"]) != "CommunityShaders" ||
            !receipt.ContainsKey("SteamAppId") || Convert.ToString(receipt["SteamAppId"]) != "489830" ||
            !receipt.ContainsKey("Hashes") || !receipt.ContainsKey("Runtime"))
            throw new InvalidOperationException("The V2 mod installation receipt is incomplete. Re-run Install-SkyrimMods.ps1 -Mode Install -Resume.");

        Version runtime;
        string version = Convert.ToString(receipt["Runtime"]);
        if (!Version.TryParse(version, out runtime) || runtime.Build < 0 || version != runtime.ToString(3))
            throw new InvalidOperationException("Invalid runtime in installation receipt.");
        string runtimeDll = "skse64_" + version.Replace('.', '_') + ".dll";
        var hashes = receipt["Hashes"] as Dictionary<string, object>;
        string[] required = { "SkyrimSE.exe", "skse64_loader.exe", runtimeDll, @"Data\SKSE\Plugins\CommunityShaders.dll",
            @"Data\Shaders\Features\CloudShadows.ini", @"Data\Shaders\Features\ExtendedMaterials.ini",
            @"Data\Shaders\Features\InverseSquareLighting.ini", @"Data\Shaders\Features\Skylighting.ini",
            @"Data\Shaders\Features\TerrainHelper.ini", @"Data\Shaders\Features\TerrainBlending.ini" };
        foreach (string name in required)
            if (hashes == null || !hashes.ContainsKey(name))
                throw new InvalidOperationException("Required V2 launch file was not recorded: " + name);

        string root = Path.GetFullPath(gameDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        foreach (var pair in hashes)
        {
            if (String.IsNullOrWhiteSpace(pair.Key) || Path.IsPathRooted(pair.Key) || pair.Key.Contains(":"))
                throw new InvalidOperationException("Invalid receipt file path.");
            foreach (string segment in pair.Key.Split(new char[] { '\\', '/' }))
                if (segment == ".." || segment == "." || segment.Length == 0)
                    throw new InvalidOperationException("Invalid receipt file path.");
            string file = Path.GetFullPath(Path.Combine(root, pair.Key));
            if (!file.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Receipt file path escapes Skyrim.");
            if (!File.Exists(file) || !String.Equals(Hash(file), Convert.ToString(pair.Value), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Launch file changed or is missing: " + pair.Key +
                    ". Steam may have updated/verified Skyrim, or a shader/native mod changed. Recheck runtime compatibility and complete the installer again.");
        }
        foreach (string name in new string[] { "d3d11.dll", "d3dcompiler_46e.dll", "enbseries.ini", "enblocal.ini", @"Data\Shaders\Features\Effects11.ini" })
            if (File.Exists(Path.Combine(root, name)))
                throw new InvalidOperationException("Existing ENB/Effects11 component conflicts with V2: " + name);
        if (Directory.Exists(Path.Combine(root, "enbseries")))
            throw new InvalidOperationException("Existing ENB shader folder conflicts with V2.");
        return version;
    }

    private static string Hash(string path)
    {
        using (SHA256 hasher = SHA256.Create())
        using (FileStream stream = File.OpenRead(path))
            return BitConverter.ToString(hasher.ComputeHash(stream)).Replace("-", "");
    }

    private static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(LogDirectory);
            File.AppendAllText(Path.Combine(LogDirectory, "steam-launch.log"),
                               DateTime.UtcNow.ToString("o") + " " + message + Environment.NewLine);
        }
        catch { /* Reporting a launch failure must not depend on writable logs. */ }
    }
}
