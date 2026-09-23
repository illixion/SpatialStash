using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.MediaEncoding;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

public enum SceneState
{
    None,
    Preparing,
    Ready,
    Unsupported,
    Failed
}

public sealed record SceneStatus(SceneState State, double ProgressSeconds, double DurationSeconds, string? Error);

/// <summary>
/// Turns an item's TrueHD track into a prepared scene on disk:
///
///   &lt;cache&gt;/&lt;itemId&gt;/scene.json            — elements, events, segment layout
///   &lt;cache&gt;/&lt;itemId&gt;/seg/&lt;n&gt;-&lt;group&gt;.flac   — 16-bit FLAC, ≤8 channels per group
///
/// jellyfin-ffmpeg copies the TrueHD track out of the container into truehdd,
/// which writes the object audio (one CAF channel per element, 24-bit) and the
/// DAMF metadata. The CAF is then cut into fixed-length segments, split into
/// channel groups (FLAC tops out at 8 channels) and encoded with ffmpeg.
/// scene.json is written last, so its presence means the scene is complete.
/// </summary>
public sealed class AtmosSceneService
{
    private const int MaxChannelsPerGroup = 8;

    private readonly ILibraryManager _libraryManager;
    private readonly IMediaSourceManager _mediaSourceManager;
    private readonly IMediaEncoder _mediaEncoder;
    private readonly IApplicationPaths _paths;
    private readonly ILogger<AtmosSceneService> _logger;
    private readonly ConcurrentDictionary<Guid, Job> _jobs = new();

    public AtmosSceneService(
        ILibraryManager libraryManager,
        IMediaSourceManager mediaSourceManager,
        IMediaEncoder mediaEncoder,
        IApplicationPaths paths,
        ILogger<AtmosSceneService> logger)
    {
        _libraryManager = libraryManager;
        _mediaSourceManager = mediaSourceManager;
        _mediaEncoder = mediaEncoder;
        _paths = paths;
        _logger = logger;
    }

    private static PluginConfiguration Config => Plugin.Instance?.Configuration ?? new PluginConfiguration();

    private string CacheRoot => string.IsNullOrWhiteSpace(Config.CacheDirectory)
        ? Path.Combine(_paths.CachePath, "atmos-objects")
        : Config.CacheDirectory;

    private string TruehddPath => string.IsNullOrWhiteSpace(Config.TruehddPath)
        ? Path.Combine(Plugin.Instance?.DataFolderPath ?? _paths.PluginConfigurationsPath, "truehdd")
        : Config.TruehddPath;

    public string SceneDirectory(Guid itemId) => Path.Combine(CacheRoot, itemId.ToString("N"));

    public string ScenePath(Guid itemId) => Path.Combine(SceneDirectory(itemId), "scene.json");

    public string? SegmentPath(Guid itemId, int segment, int group)
    {
        var path = Path.Combine(SceneDirectory(itemId), "seg", $"{segment}-{group}.flac");
        return File.Exists(path) ? path : null;
    }

    public SceneStatus GetStatus(Guid itemId)
    {
        if (_jobs.TryGetValue(itemId, out var job))
        {
            return new SceneStatus(job.State, job.ProgressSeconds, job.DurationSeconds, job.Error);
        }

        if (File.Exists(ScenePath(itemId)))
        {
            return new SceneStatus(SceneState.Ready, 0, 0, null);
        }

        var unsupported = Path.Combine(SceneDirectory(itemId), "unsupported.txt");
        if (File.Exists(unsupported))
        {
            return new SceneStatus(SceneState.Unsupported, 0, 0, File.ReadAllText(unsupported));
        }

        return new SceneStatus(SceneState.None, 0, 0, null);
    }

    /// <summary>Starts preparing the scene unless it is ready or already running. Returns false for unknown items.</summary>
    public bool Prepare(Guid itemId)
    {
        var item = _libraryManager.GetItemById(itemId);
        if (item is null || string.IsNullOrEmpty(item.Path))
        {
            return false;
        }

        var status = GetStatus(itemId);
        if (status.State is SceneState.Ready or SceneState.Preparing or SceneState.Unsupported)
        {
            return true;
        }

        var job = new Job
        {
            State = SceneState.Preparing,
            DurationSeconds = item.RunTimeTicks is long ticks ? TimeSpan.FromTicks(ticks).TotalSeconds : 0
        };
        if (!_jobs.TryAdd(itemId, job) && _jobs[itemId].State == SceneState.Preparing)
        {
            return true;
        }

        _jobs[itemId] = job;
        _ = Task.Run(async () =>
        {
            try
            {
                await RunAsync(itemId, item.Path, job).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Atmos scene preparation failed for {ItemId}", itemId);
                job.Error = ex.Message;
                job.State = SceneState.Failed;
            }
            finally
            {
                // Finished states are read back from disk; keep failures visible.
                if (job.State != SceneState.Failed)
                {
                    _jobs.TryRemove(itemId, out _);
                }
            }
        });
        return true;
    }

    private async Task RunAsync(Guid itemId, string mediaPath, Job job)
    {
        var dir = SceneDirectory(itemId);
        var work = Path.Combine(dir, "work");
        var segDir = Path.Combine(dir, "seg");
        if (Directory.Exists(dir))
        {
            Directory.Delete(dir, recursive: true);
        }

        Directory.CreateDirectory(work);
        Directory.CreateDirectory(segDir);

        var stream = _mediaSourceManager.GetMediaStreams(itemId)
            .FirstOrDefault(s => s.Type == MediaStreamType.Audio
                && string.Equals(s.Codec, "truehd", StringComparison.OrdinalIgnoreCase));
        if (stream is null)
        {
            MarkUnsupported(dir, job, "No TrueHD audio track.");
            return;
        }

        if (!File.Exists(TruehddPath))
        {
            throw new FileNotFoundException($"truehdd not found at {TruehddPath}; set TruehddPath in the plugin configuration.");
        }

        _logger.LogInformation("Preparing Atmos scene for {ItemId} from stream {Index} of {Path}", itemId, stream.Index, mediaPath);
        var sw = Stopwatch.StartNew();
        var basePath = Path.Combine(work, "out");
        await DecodeAsync(mediaPath, stream.Index, basePath, job).ConfigureAwait(false);

        if (!File.Exists(basePath + ".atmos"))
        {
            MarkUnsupported(dir, job, "The TrueHD track has no Atmos object presentation.");
            Directory.Delete(work, recursive: true);
            return;
        }

        var elements = DamfReader.ReadElements(basePath + ".atmos");
        var (sampleRate, events) = DamfReader.ReadEvents(basePath + ".atmos.metadata");
        var caf = CafPcm.Open(basePath + ".atmos.audio");
        if (caf.Channels != elements.Count)
        {
            throw new InvalidDataException($"Audio has {caf.Channels} channels but the header lists {elements.Count} elements.");
        }

        var segmentFrames = sampleRate * Math.Max(1, Config.SegmentSeconds);
        var segmentCount = (int)((caf.FrameCount + segmentFrames - 1) / segmentFrames);
        var groups = SplitGroups(caf.Channels);
        _logger.LogInformation(
            "Decoded {Elements} elements, {Events} events, {Seconds:F0} s in {Elapsed:F0} s; encoding {Segments} segments",
            elements.Count, events.Count, (double)caf.FrameCount / sampleRate, sw.Elapsed.TotalSeconds, segmentCount);

        await EncodeSegmentsAsync(caf, segDir, segmentFrames, segmentCount, groups, sampleRate).ConfigureAwait(false);

        var scene = new SceneDocument
        {
            SampleRate = sampleRate,
            FrameCount = caf.FrameCount,
            SegmentFrames = segmentFrames,
            SegmentCount = segmentCount,
            Groups = groups,
            StartSeconds = await ProbeStartSecondsAsync(mediaPath, stream.Index).ConfigureAwait(false),
            Elements = elements,
            Events = events
        };
        var tmp = ScenePath(itemId) + ".tmp";
        await File.WriteAllTextAsync(tmp, JsonSerializer.Serialize(scene, JsonOptions)).ConfigureAwait(false);
        File.Move(tmp, ScenePath(itemId), overwrite: true);
        Directory.Delete(work, recursive: true);
        job.State = SceneState.Ready;
        _logger.LogInformation("Atmos scene for {ItemId} ready in {Elapsed:F0} s", itemId, sw.Elapsed.TotalSeconds);
    }

    public static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    /// <summary>Balanced groups of at most 8 channels: 14 → 7+7 rather than 8+6.</summary>
    private static List<int[]> SplitGroups(int channels)
    {
        var count = (channels + MaxChannelsPerGroup - 1) / MaxChannelsPerGroup;
        var groups = new List<int[]>();
        var next = 0;
        for (var g = 0; g < count; g++)
        {
            var size = (channels - next + (count - g) - 1) / (count - g);
            groups.Add(Enumerable.Range(next, size).ToArray());
            next += size;
        }

        return groups;
    }

    private async Task DecodeAsync(string mediaPath, int streamIndex, string basePath, Job job)
    {
        var ffmpeg = StartProcess(_mediaEncoder.EncoderPath,
            ["-v", "error", "-nostdin", "-i", mediaPath, "-map", $"0:{streamIndex}", "-c", "copy", "-f", "truehd", "pipe:1"],
            redirectInput: false);
        var truehdd = StartProcess(TruehddPath,
            ["--loglevel", "error", "decode", "-", "--output-path", basePath],
            redirectInput: true);

        var pump = Task.Run(async () =>
        {
            try
            {
                await ffmpeg.StandardOutput.BaseStream.CopyToAsync(truehdd.StandardInput.BaseStream).ConfigureAwait(false);
            }
            finally
            {
                truehdd.StandardInput.Close();
            }
        });
        var ffmpegErr = ffmpeg.StandardError.ReadToEndAsync();
        var truehddErr = truehdd.StandardError.ReadToEndAsync();
        _ = truehdd.StandardOutput.ReadToEndAsync();

        // Progress from how much audio has landed so far.
        using var progress = new CancellationTokenSource();
        var watcher = Task.Run(async () =>
        {
            while (!progress.IsCancellationRequested)
            {
                try
                {
                    var audio = new FileInfo(basePath + ".atmos.audio");
                    if (audio.Exists && CafPcm.TryReadLayout(audio.FullName, out var layout))
                    {
                        job.ProgressSeconds = (double)(audio.Length - layout.DataOffset) / layout.BytesPerFrame / layout.SampleRate;
                    }
                }
                catch (IOException)
                {
                }

                await Task.Delay(1000).ConfigureAwait(false);
            }
        });

        await Task.WhenAll(ffmpeg.WaitForExitAsync(), truehdd.WaitForExitAsync(), pump).ConfigureAwait(false);
        await progress.CancelAsync().ConfigureAwait(false);
        await watcher.ConfigureAwait(false);

        if (ffmpeg.ExitCode != 0)
        {
            throw new InvalidOperationException($"ffmpeg exited {ffmpeg.ExitCode}: {(await ffmpegErr.ConfigureAwait(false)).Trim()}");
        }

        if (truehdd.ExitCode != 0)
        {
            throw new InvalidOperationException($"truehdd exited {truehdd.ExitCode}: {(await truehddErr.ConfigureAwait(false)).Trim()}");
        }
    }

    private async Task EncodeSegmentsAsync(CafPcm caf, string segDir, int segmentFrames, int segmentCount, List<int[]> groups, int sampleRate)
    {
        using var gate = new SemaphoreSlim(Math.Max(1, Config.EncoderParallelism));
        var tasks = new List<Task>();
        using var reader = caf.OpenData();
        var frameBytes = caf.Channels * 3;
        for (var s = 0; s < segmentCount; s++)
        {
            var frames = (int)Math.Min(segmentFrames, caf.FrameCount - ((long)s * segmentFrames));
            var block = new byte[frames * frameBytes];
            await reader.ReadExactlyAsync(block).ConfigureAwait(false);
            await gate.WaitAsync().ConfigureAwait(false);
            var segment = s;
            tasks.Add(Task.Run(async () =>
            {
                try
                {
                    for (var g = 0; g < groups.Count; g++)
                    {
                        var pcm = Deinterleave(block, caf.Channels, groups[g]);
                        await EncodeFlacAsync(pcm, groups[g].Length, sampleRate, Path.Combine(segDir, $"{segment}-{g}.flac")).ConfigureAwait(false);
                    }
                }
                finally
                {
                    gate.Release();
                }
            }));
            tasks.RemoveAll(t => t.IsCompletedSuccessfully);
            if (tasks.FirstOrDefault(t => t.IsFaulted) is { } failed)
            {
                await failed.ConfigureAwait(false);
            }
        }

        await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>Picks one group's channels out of interleaved 24-bit frames, still 24-bit big-endian.</summary>
    private static byte[] Deinterleave(byte[] block, int channels, int[] group)
    {
        var frames = block.Length / (channels * 3);
        var output = new byte[frames * group.Length * 3];
        var o = 0;
        for (var f = 0; f < frames; f++)
        {
            var frameStart = f * channels * 3;
            foreach (var ch in group)
            {
                var i = frameStart + (ch * 3);
                output[o++] = block[i];
                output[o++] = block[i + 1];
                output[o++] = block[i + 2];
            }
        }

        return output;
    }

    private async Task EncodeFlacAsync(byte[] pcm, int channels, int sampleRate, string path)
    {
        var tmp = path + ".tmp";
        var process = StartProcess(_mediaEncoder.EncoderPath,
            ["-v", "error", "-f", "s24be", "-ar", sampleRate.ToString(CultureInfo.InvariantCulture),
             "-ac", channels.ToString(CultureInfo.InvariantCulture), "-i", "pipe:0",
             "-af", "aresample=osf=s16:dither_method=triangular",
             "-c:a", "flac", "-f", "flac", "-y", tmp],
            redirectInput: true);
        var stderr = process.StandardError.ReadToEndAsync();
        _ = process.StandardOutput.ReadToEndAsync();
        await process.StandardInput.BaseStream.WriteAsync(pcm).ConfigureAwait(false);
        process.StandardInput.Close();
        await process.WaitForExitAsync().ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"FLAC encode of {Path.GetFileName(path)} failed: {(await stderr.ConfigureAwait(false)).Trim()}");
        }

        File.Move(tmp, path, overwrite: true);
    }

    private async Task<double> ProbeStartSecondsAsync(string mediaPath, int streamIndex)
    {
        var process = StartProcess(_mediaEncoder.ProbePath,
            ["-v", "error", "-select_streams", streamIndex.ToString(CultureInfo.InvariantCulture),
             "-show_entries", "stream=start_time", "-of", "csv=p=0", mediaPath],
            redirectInput: false);
        var output = await process.StandardOutput.ReadToEndAsync().ConfigureAwait(false);
        _ = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync().ConfigureAwait(false);
        return double.TryParse(output.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var start) ? start : 0;
    }

    private static void MarkUnsupported(string dir, Job job, string reason)
    {
        File.WriteAllText(Path.Combine(dir, "unsupported.txt"), reason);
        job.Error = reason;
        job.State = SceneState.Unsupported;
    }

    private static Process StartProcess(string fileName, IEnumerable<string> args, bool redirectInput)
    {
        var info = new ProcessStartInfo(fileName)
        {
            RedirectStandardInput = redirectInput,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var arg in args)
        {
            info.ArgumentList.Add(arg);
        }

        return Process.Start(info) ?? throw new InvalidOperationException($"Could not start {fileName}");
    }

    private sealed class Job
    {
        public volatile SceneState State;
        public double ProgressSeconds;
        public double DurationSeconds;
        public string? Error;
    }
}

/// <summary>
/// The CAF truehdd writes for object audio: linear PCM, 24-bit big-endian,
/// interleaved, one channel per element. Only the 'desc' and 'data' chunks
/// matter here.
/// </summary>
public sealed class CafPcm
{
    private CafPcm(string path, CafLayout layout, long frameCount)
    {
        FilePath = path;
        Layout = layout;
        FrameCount = frameCount;
    }

    public string FilePath { get; }

    public CafLayout Layout { get; }

    public int Channels => Layout.Channels;

    public long FrameCount { get; }

    public static CafPcm Open(string path)
    {
        if (!TryReadLayout(path, out var layout))
        {
            throw new InvalidDataException($"{path} is not a 24-bit linear PCM CAF.");
        }

        var dataBytes = new FileInfo(path).Length - layout.DataOffset;
        return new CafPcm(path, layout, dataBytes / layout.BytesPerFrame);
    }

    public Stream OpenData()
    {
        var stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1 << 20);
        stream.Seek(Layout.DataOffset, SeekOrigin.Begin);
        return stream;
    }

    public static bool TryReadLayout(string path, out CafLayout layout)
    {
        layout = default;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        Span<byte> head = stackalloc byte[8];
        if (stream.Read(head) != 8 || !head[..4].SequenceEqual("caff"u8))
        {
            return false;
        }

        double sampleRate = 0;
        int channels = 0, bits = 0;
        Span<byte> chunk = stackalloc byte[12];
        Span<byte> desc = stackalloc byte[32];
        while (stream.Read(chunk) == 12)
        {
            var type = System.Text.Encoding.ASCII.GetString(chunk[..4]);
            var size = BinaryPrimitives.ReadInt64BigEndian(chunk[4..]);
            if (type == "desc")
            {
                stream.ReadExactly(desc);
                sampleRate = BinaryPrimitives.ReadDoubleBigEndian(desc);
                channels = (int)BinaryPrimitives.ReadUInt32BigEndian(desc[24..]);
                bits = (int)BinaryPrimitives.ReadUInt32BigEndian(desc[28..]);
                stream.Seek(size - 32, SeekOrigin.Current);
            }
            else if (type == "data")
            {
                // 4-byte edit count precedes the samples; size is -1 while still being written.
                if (channels == 0 || bits != 24)
                {
                    return false;
                }

                layout = new CafLayout((int)sampleRate, channels, stream.Position + 4);
                return true;
            }
            else
            {
                stream.Seek(size, SeekOrigin.Current);
            }
        }

        return false;
    }
}

public readonly record struct CafLayout(int SampleRate, int Channels, long DataOffset)
{
    public int BytesPerFrame => Channels * 3;
}
