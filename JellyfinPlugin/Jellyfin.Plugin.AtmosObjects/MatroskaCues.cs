using System.Buffers.Binary;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Reads a Matroska file's Cues (its seek index) for the first video track:
/// the presentation times of the keyframes a demuxer can seek to. Reads only
/// the file's head and the Cues element, a few hundred KB even for a UHD
/// remux, so it takes a fraction of a second where scanning packets would
/// read the whole file.
/// </summary>
public static class MatroskaCues
{
    private const uint EbmlHeader = 0x1A45DFA3;
    private const uint Segment = 0x18538067;
    private const uint SeekHead = 0x114D9B74;
    private const uint Seek = 0x4DBB;
    private const uint SeekId = 0x53AB;
    private const uint SeekPosition = 0x53AC;
    private const uint Info = 0x1549A966;
    private const uint TimestampScale = 0x2AD7B1;
    private const uint Tracks = 0x1654AE6B;
    private const uint TrackEntry = 0xAE;
    private const uint TrackNumber = 0xD7;
    private const uint TrackType = 0x83;
    private const uint Cues = 0x1C53BB6B;
    private const uint CuePoint = 0xBB;
    private const uint CueTime = 0xB3;
    private const uint CueTrackPositions = 0xB7;
    private const uint CueTrack = 0xF7;
    private const uint Cluster = 0x1F43B675;
    private const ulong VideoTrackType = 1;

    /// <summary>Keyframe times in seconds, ascending, or null if the file has no usable Cues.</summary>
    public static List<double>? ReadVideoKeyframes(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024);
        if (ReadId(file) != EbmlHeader)
        {
            return null;
        }

        file.Seek((long)ReadSize(file), SeekOrigin.Current);
        if (ReadId(file) != Segment)
        {
            return null;
        }

        ReadSize(file);
        var segmentStart = file.Position;
        long? cuesPosition = null;
        ulong timestampScaleNs = 1_000_000;
        ulong? videoTrack = null;

        // Top-level elements up to the first Cluster: SeekHead says where Cues are.
        while (file.Position < file.Length)
        {
            var id = ReadId(file);
            var size = (long)ReadSize(file);
            var body = file.Position;
            if (id == Cluster)
            {
                break;
            }

            switch (id)
            {
                case SeekHead:
                    foreach (var (_, seekEnd) in Children(file, body + size, Seek))
                    {
                        uint? target = null;
                        long? position = null;
                        foreach (var (childId, value) in Leaves(file, seekEnd))
                        {
                            if (childId == SeekId)
                            {
                                target = (uint)ToUInt(value);
                            }
                            else if (childId == SeekPosition)
                            {
                                position = (long)ToUInt(value);
                            }
                        }

                        if (target == Cues && position is { } p)
                        {
                            cuesPosition = segmentStart + p;
                        }
                    }

                    break;
                case Info:
                    foreach (var (childId, value) in Leaves(file, body + size))
                    {
                        if (childId == TimestampScale)
                        {
                            timestampScaleNs = ToUInt(value);
                        }
                    }

                    break;
                case Tracks:
                    foreach (var (_, entryEnd) in Children(file, body + size, TrackEntry))
                    {
                        ulong? number = null;
                        ulong? type = null;
                        foreach (var (childId, value) in Leaves(file, entryEnd, TrackNumber, TrackType))
                        {
                            if (childId == TrackNumber)
                            {
                                number = ToUInt(value);
                            }
                            else
                            {
                                type = ToUInt(value);
                            }
                        }

                        if (type == VideoTrackType && videoTrack is null)
                        {
                            videoTrack = number;
                        }
                    }

                    break;
            }

            file.Position = body + size;
        }

        if (cuesPosition is not { } cues || videoTrack is not { } track)
        {
            return null;
        }

        file.Position = cues;
        if (ReadId(file) != Cues)
        {
            return null;
        }

        var cuesEnd = (long)ReadSize(file) + file.Position;
        var times = new List<double>();
        foreach (var (_, pointEnd) in Children(file, cuesEnd, CuePoint))
        {
            ulong? time = null;
            var forVideo = false;
            while (file.Position < pointEnd)
            {
                var id = ReadId(file);
                var size = (long)ReadSize(file);
                var body = file.Position;
                if (id == CueTime)
                {
                    time = ToUInt(ReadBytes(file, size));
                }
                else if (id == CueTrackPositions)
                {
                    foreach (var (childId, value) in Leaves(file, body + size, CueTrack))
                    {
                        forVideo |= ToUInt(value) == track;
                    }
                }

                file.Position = body + size;
            }

            if (forVideo && time is { } t)
            {
                times.Add(t * (double)timestampScaleNs / 1e9);
            }
        }

        times.Sort();
        return times.Count > 0 ? times : null;
    }

    /// <summary>Children with id <paramref name="wanted"/>; yields each one's end, positioned at its body.</summary>
    private static IEnumerable<(uint Id, long End)> Children(Stream file, long end, uint wanted)
    {
        while (file.Position < end)
        {
            var id = ReadId(file);
            var size = (long)ReadSize(file);
            var body = file.Position;
            if (id == wanted)
            {
                yield return (id, body + size);
            }

            file.Position = body + size;
        }
    }

    /// <summary>Leaf children (all, or only <paramref name="wanted"/>) with their raw values.</summary>
    private static IEnumerable<(uint Id, byte[] Value)> Leaves(Stream file, long end, params uint[] wanted)
    {
        while (file.Position < end)
        {
            var id = ReadId(file);
            var size = (long)ReadSize(file);
            var body = file.Position;
            if (wanted.Length == 0 || wanted.Contains(id))
            {
                yield return (id, ReadBytes(file, size));
            }

            file.Position = body + size;
        }
    }

    private static byte[] ReadBytes(Stream file, long size)
    {
        var bytes = new byte[size];
        file.ReadExactly(bytes);
        return bytes;
    }

    private static ulong ToUInt(byte[] value)
    {
        ulong result = 0;
        foreach (var b in value)
        {
            result = (result << 8) | b;
        }

        return result;
    }

    private static uint ReadId(Stream file)
    {
        var first = file.ReadByte();
        if (first < 0)
        {
            throw new EndOfStreamException();
        }

        var length = VintLength((byte)first);
        uint id = (uint)first;
        for (var i = 1; i < length; i++)
        {
            id = (id << 8) | (uint)file.ReadByte();
        }

        return id;
    }

    private static ulong ReadSize(Stream file)
    {
        var first = file.ReadByte();
        if (first < 0)
        {
            throw new EndOfStreamException();
        }

        var length = VintLength((byte)first);
        ulong size = (ulong)(first & (0xFF >> length));
        for (var i = 1; i < length; i++)
        {
            size = (size << 8) | (uint)file.ReadByte();
        }

        return size;
    }

    private static int VintLength(byte first)
    {
        var length = 1;
        for (var mask = 0x80; length <= 8 && (first & mask) == 0; mask >>= 1)
        {
            length++;
        }

        return length;
    }
}

/// <summary>
/// The few fragmented-MP4 reads and writes the video segments need: the
/// track timescale from an init segment, and a media segment's first
/// presentation time and decode-time base (tfdt), which gets shifted onto
/// film time.
/// </summary>
public static class Fmp4
{
    /// <summary>The media timescale (mdhd) of the init segment's first track.</summary>
    public static uint? Timescale(byte[] init)
    {
        foreach (var (type, _, body, end) in Boxes(init, 0, init.Length))
        {
            if (type == "moov")
            {
                return FindMdhd(init, body, end);
            }
        }

        return null;
    }

    /// <summary>
    /// First sample's presentation time (tfdt plus its composition offset),
    /// in timescale units, from the segment's first fragment.
    /// </summary>
    public static long? FirstPresentationTime(byte[] segment)
    {
        foreach (var (type, _, body, end) in Boxes(segment, 0, segment.Length))
        {
            if (type != "moof")
            {
                continue;
            }

            foreach (var (trafType, _, trafBody, trafEnd) in Boxes(segment, body, end))
            {
                if (trafType != "traf")
                {
                    continue;
                }

                long? baseTime = null;
                long offset = 0;
                foreach (var (boxType, _, boxBody, _) in Boxes(segment, trafBody, trafEnd))
                {
                    if (boxType == "tfdt")
                    {
                        baseTime = ReadTfdt(segment, boxBody);
                    }
                    else if (boxType == "trun")
                    {
                        offset = FirstCompositionOffset(segment, boxBody);
                    }
                }

                return baseTime + offset;
            }
        }

        return null;
    }

    /// <summary>Adds <paramref name="delta"/> to every tfdt in the segment, in place.</summary>
    public static void ShiftDecodeTimes(byte[] segment, long delta)
    {
        foreach (var (type, _, body, end) in Boxes(segment, 0, segment.Length))
        {
            if (type != "moof")
            {
                continue;
            }

            foreach (var (trafType, _, trafBody, trafEnd) in Boxes(segment, body, end))
            {
                if (trafType != "traf")
                {
                    continue;
                }

                foreach (var (boxType, _, boxBody, _) in Boxes(segment, trafBody, trafEnd))
                {
                    if (boxType != "tfdt")
                    {
                        continue;
                    }

                    var shifted = ReadTfdt(segment, boxBody) + delta;
                    if (segment[boxBody] == 1)
                    {
                        BinaryPrimitives.WriteInt64BigEndian(segment.AsSpan(boxBody + 4, 8), shifted);
                    }
                    else
                    {
                        BinaryPrimitives.WriteUInt32BigEndian(segment.AsSpan(boxBody + 4, 4), checked((uint)shifted));
                    }
                }
            }
        }
    }

    private static uint? FindMdhd(byte[] data, int start, int end)
    {
        foreach (var (type, _, body, boxEnd) in Boxes(data, start, end))
        {
            if (type == "mdhd")
            {
                var version = data[body];
                return BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(body + (version == 1 ? 20 : 12), 4));
            }

            if (type is "trak" or "mdia" && FindMdhd(data, body, boxEnd) is { } found)
            {
                return found;
            }
        }

        return null;
    }

    private static long ReadTfdt(byte[] data, int body) => data[body] == 1
        ? BinaryPrimitives.ReadInt64BigEndian(data.AsSpan(body + 4, 8))
        : BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(body + 4, 4));

    private static long FirstCompositionOffset(byte[] data, int body)
    {
        var flags = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(body, 4)) & 0xFFFFFF;
        if ((flags & 0x800) == 0)
        {
            return 0;
        }

        var p = body + 8;
        p += (flags & 0x1) != 0 ? 4 : 0;   // data offset
        p += (flags & 0x4) != 0 ? 4 : 0;   // first sample flags
        p += (flags & 0x100) != 0 ? 4 : 0; // sample duration
        p += (flags & 0x200) != 0 ? 4 : 0; // sample size
        p += (flags & 0x400) != 0 ? 4 : 0; // sample flags
        return BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(p, 4));
    }

    private static IEnumerable<(string Type, int Start, int Body, int End)> Boxes(byte[] data, int start, int end)
    {
        var p = start;
        while (p + 8 <= end)
        {
            long size = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(p, 4));
            var type = System.Text.Encoding.Latin1.GetString(data, p + 4, 4);
            var header = 8;
            if (size == 1)
            {
                size = (long)BinaryPrimitives.ReadUInt64BigEndian(data.AsSpan(p + 8, 8));
                header = 16;
            }
            else if (size == 0)
            {
                size = end - p;
            }

            if (size < header || p + size > end)
            {
                yield break;
            }

            yield return (type, p, p + header, (int)(p + size));
            p += (int)size;
        }
    }
}
