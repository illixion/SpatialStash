using System.Net.Mime;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Client API. A client asks for the status, triggers preparation once, then
/// reads scene.json and fetches FLAC segments around its playhead:
///
///   GET  /AtmosObjects/{itemId}                     status + progress
///   POST /AtmosObjects/{itemId}/Prepare             start extraction (idempotent)
///   GET  /AtmosObjects/{itemId}/Scene               scene.json (404 until ready)
///   GET  /AtmosObjects/{itemId}/Segments/{n}/{g}    FLAC for segment n, channel group g
/// </summary>
[ApiController]
[Route("AtmosObjects")]
[Authorize]
public class AtmosObjectsController : ControllerBase
{
    private readonly AtmosSceneService _scenes;

    public AtmosObjectsController(AtmosSceneService scenes)
    {
        _scenes = scenes;
    }

    [HttpGet("{itemId}")]
    [Produces(MediaTypeNames.Application.Json)]
    public ActionResult<object> GetStatus([FromRoute] Guid itemId)
    {
        var status = _scenes.GetStatus(itemId);
        return new
        {
            state = status.State.ToString().ToLowerInvariant(),
            progressSeconds = status.ProgressSeconds,
            durationSeconds = status.DurationSeconds,
            error = status.Error
        };
    }

    [HttpPost("{itemId}/Prepare")]
    [ProducesResponseType(StatusCodes.Status202Accepted)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public ActionResult Prepare([FromRoute] Guid itemId)
        => _scenes.Prepare(itemId) ? Accepted() : NotFound();

    [HttpGet("{itemId}/Scene")]
    public ActionResult GetScene([FromRoute] Guid itemId)
    {
        var path = _scenes.ScenePath(itemId);
        return System.IO.File.Exists(path)
            ? PhysicalFile(path, MediaTypeNames.Application.Json)
            : NotFound();
    }

    [HttpGet("{itemId}/Segments/{segment:int}/{group:int}")]
    public ActionResult GetSegment([FromRoute] Guid itemId, [FromRoute] int segment, [FromRoute] int group)
    {
        var path = _scenes.SegmentPath(itemId, segment, group);
        return path is null ? NotFound() : PhysicalFile(path, "audio/flac");
    }
}
