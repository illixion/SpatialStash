using System.Net.Mime;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Client API. A client reads the scene layout (which starts a decode at the
/// requested point if needed), then fetches segments around its playhead;
/// every segment request decodes on demand, so seeking anywhere works without
/// preparing the film first:
///
///   GET  /AtmosObjects/{itemId}                          status
///   POST /AtmosObjects/{itemId}/Prepare                  cache the whole film in the background
///   GET  /AtmosObjects/{itemId}/Scene?startSeconds=T     layout
///   GET  /AtmosObjects/{itemId}/Segments/{n}/Events      snapshot + events for segment n
///   GET  /AtmosObjects/{itemId}/Segments/{n}/{g}         FLAC for segment n, channel group g
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
    public async Task<ActionResult> GetScene([FromRoute] Guid itemId, [FromQuery] double startSeconds, CancellationToken ct)
    {
        try
        {
            var scene = await _scenes.GetSceneAsync(itemId, startSeconds, ct).ConfigureAwait(false);
            return scene is null
                ? UnprocessableEntity(_scenes.GetStatus(itemId).Error)
                : new JsonResult(scene, AtmosSceneService.JsonOptions);
        }
        catch (FileNotFoundException)
        {
            return NotFound();
        }
        catch (Exception ex) when (ex is TimeoutException or InvalidOperationException)
        {
            return StatusCode(StatusCodes.Status503ServiceUnavailable, ex.Message);
        }
    }

    [HttpGet("{itemId}/Segments/{segment:int}/Events")]
    public async Task<ActionResult> GetSegmentEvents([FromRoute] Guid itemId, [FromRoute] int segment, CancellationToken ct)
    {
        if (!await _scenes.EnsureSegmentAsync(itemId, segment, ct).ConfigureAwait(false))
        {
            return NotFound();
        }

        var path = _scenes.SegmentEvents(itemId, segment);
        return path is null ? NotFound() : PhysicalFile(path, MediaTypeNames.Application.Json);
    }

    [HttpGet("{itemId}/Segments/{segment:int}/{group:int}")]
    public async Task<ActionResult> GetSegment([FromRoute] Guid itemId, [FromRoute] int segment, [FromRoute] int group, CancellationToken ct)
    {
        if (!await _scenes.EnsureSegmentAsync(itemId, segment, ct).ConfigureAwait(false))
        {
            return NotFound();
        }

        var path = _scenes.SegmentFlac(itemId, segment, group);
        return path is null ? NotFound() : PhysicalFile(path, "audio/flac");
    }
}
