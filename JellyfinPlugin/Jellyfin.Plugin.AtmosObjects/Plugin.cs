using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Controller;
using MediaBrowser.Controller.Plugins;
using MediaBrowser.Model.Serialization;
using Microsoft.Extensions.DependencyInjection;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Serves the Atmos objects of TrueHD tracks as separate audio stems plus
/// position metadata, so a client can place its own spatial sources instead
/// of relying on a Dolby renderer. Decoding is done by truehdd, an external
/// open-source TrueHD decoder the server operator installs.
/// </summary>
public class Plugin : BasePlugin<PluginConfiguration>
{
    public Plugin(IApplicationPaths applicationPaths, IXmlSerializer xmlSerializer)
        : base(applicationPaths, xmlSerializer)
    {
        Instance = this;
    }

    public static Plugin? Instance { get; private set; }

    public override string Name => "Atmos Objects";

    public override Guid Id => Guid.Parse("030dca02-37ea-4c55-a4d7-726bb00db38a");

    public override string Description =>
        "Extracts Atmos objects from TrueHD tracks (via truehdd) and serves them as FLAC stems with position metadata.";
}

public class PluginConfiguration : MediaBrowser.Model.Plugins.BasePluginConfiguration
{
    /// <summary>Path to the truehdd binary. Empty means "truehdd" next to the plugin's data folder.</summary>
    public string TruehddPath { get; set; } = string.Empty;

    /// <summary>Where prepared scenes are stored. Empty means &lt;cache&gt;/atmos-objects.</summary>
    public string CacheDirectory { get; set; } = string.Empty;

    /// <summary>Segment length in seconds; every segment is one FLAC file per channel group.</summary>
    public int SegmentSeconds { get; set; } = 10;

    /// <summary>How many segment encoders run at once.</summary>
    public int EncoderParallelism { get; set; } = 4;
}

public class PluginServiceRegistrator : IPluginServiceRegistrator
{
    public void RegisterServices(IServiceCollection serviceCollection, IServerApplicationHost applicationHost)
    {
        serviceCollection.AddSingleton<AtmosSceneService>();
    }
}
