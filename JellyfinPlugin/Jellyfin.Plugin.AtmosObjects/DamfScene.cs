using System.Globalization;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// The scene document a client reads: which audio channel carries which
/// Atmos element, every position/gain event, and how the audio is split into
/// segment files. Timestamps are sample frames from the first decoded sample.
/// </summary>
public sealed class SceneDocument
{
    public int Version { get; set; } = 1;
    public int SampleRate { get; set; }
    public long FrameCount { get; set; }
    public int SegmentFrames { get; set; }
    public int SegmentCount { get; set; }
    /// <summary>Audio channel indices carried by each group's FLAC file, in file channel order.</summary>
    public List<int[]> Groups { get; set; } = [];
    /// <summary>Start time of the TrueHD track in the container, for lining up with video.</summary>
    public double StartSeconds { get; set; }
    public List<SceneElement> Elements { get; set; } = [];
    public List<SceneEvent> Events { get; set; } = [];
}

public sealed class SceneElement
{
    public int Id { get; set; }
    public int Channel { get; set; }
    public string Kind { get; set; } = "object";
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BedChannel { get; set; }
}

public sealed class SceneEvent
{
    public int Id { get; set; }
    public long T { get; set; }
    public int Ramp { get; set; }
    public double Gain { get; set; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double[]? Pos { get; set; }
}

/// <summary>
/// Reads the DAMF set truehdd writes (&lt;base&gt;.atmos header +
/// &lt;base&gt;.atmos.metadata). Both are YAML, but in the fixed shape truehdd
/// emits, so a line reader is enough and keeps a feature film's metadata
/// streaming rather than loaded as one document.
/// </summary>
public static partial class DamfReader
{
    [GeneratedRegex(@"- channel: (\w+)\s+ID: (\d+)")]
    private static partial Regex BedRegex();

    [GeneratedRegex(@"^\s+- ID: (\d+)\s*$", RegexOptions.Multiline)]
    private static partial Regex ObjectRegex();

    /// <summary>Elements in audio channel order: beds first, then objects, as the header lists them.</summary>
    public static List<SceneElement> ReadElements(string headerPath)
    {
        var header = File.ReadAllText(headerPath);
        var elements = new List<SceneElement>();
        foreach (Match m in BedRegex().Matches(header))
        {
            elements.Add(new SceneElement
            {
                Id = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture),
                Channel = elements.Count,
                Kind = "bed",
                BedChannel = m.Groups[1].Value
            });
        }

        var objectsAt = header.IndexOf("objects:", StringComparison.Ordinal);
        if (objectsAt >= 0)
        {
            foreach (Match m in ObjectRegex().Matches(header[objectsAt..]))
            {
                elements.Add(new SceneElement
                {
                    Id = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture),
                    Channel = elements.Count
                });
            }
        }

        return elements;
    }

    /// <summary>
    /// Events in time order. Later events for an element carry only samplePos
    /// and pos, so ramp, gain and active persist from its previous event;
    /// an inactive element is reported at -144 dB.
    /// </summary>
    public static (int SampleRate, List<SceneEvent> Events) ReadEvents(string metadataPath)
    {
        var sampleRate = 48000;
        var events = new List<SceneEvent>();
        var state = new Dictionary<int, (int Ramp, double Gain, bool Active)>();

        int? id = null;
        long samplePos = 0;
        double[]? pos = null;
        (int Ramp, double Gain, bool Active) current = default;

        void Flush()
        {
            if (id is not int eid)
            {
                return;
            }

            state[eid] = current;
            events.Add(new SceneEvent
            {
                Id = eid,
                T = samplePos,
                Ramp = current.Ramp,
                Gain = current.Active ? current.Gain : -144.0,
                Pos = pos
            });
        }

        foreach (var raw in File.ReadLines(metadataPath))
        {
            var line = raw.Trim();
            if (line.StartsWith("- ID: ", StringComparison.Ordinal))
            {
                Flush();
                id = ParseInt(line[6..]);
                current = state.TryGetValue(id.Value, out var s) ? s : (0, 0.0, true);
                samplePos = 0;
                pos = null;
                continue;
            }

            var colon = line.IndexOf(':', StringComparison.Ordinal);
            if (colon <= 0)
            {
                continue;
            }

            var key = line[..colon];
            var value = line[(colon + 1)..].Trim();
            if (id is null)
            {
                if (key == "sampleRate")
                {
                    sampleRate = ParseInt(value);
                }

                continue;
            }

            switch (key)
            {
                case "samplePos":
                    samplePos = long.Parse(value, CultureInfo.InvariantCulture);
                    break;
                case "rampLength":
                    current.Ramp = ParseInt(value);
                    break;
                case "gain":
                    current.Gain = value.Contains("inf", StringComparison.Ordinal)
                        ? -144.0
                        : double.Parse(value, CultureInfo.InvariantCulture);
                    break;
                case "active":
                    current.Active = value == "true";
                    break;
                case "pos":
                    pos = value.Trim('[', ']')
                        .Split(',', StringSplitOptions.TrimEntries)
                        .Select(v => double.Parse(v, CultureInfo.InvariantCulture))
                        .ToArray();
                    break;
            }
        }

        Flush();
        events.Sort((a, b) => a.T != b.T ? a.T.CompareTo(b.T) : a.Id.CompareTo(b.Id));
        return (sampleRate, events);
    }

    private static int ParseInt(string s) => int.Parse(s.Trim(), CultureInfo.InvariantCulture);
}
