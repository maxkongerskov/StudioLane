# Driving StudioLane over MCP

Launch the app with `--mcp` and it speaks [MCP](https://modelcontextprotocol.io/specification/2024-11-05/basic/transports) on stdio (protocol `2024-11-05`). One JSON object per line. Responses and progress notifications go to stdout. Logs go to stderr only.

An `--mcp` process starts on an empty timeline. It does not restore the last session, and it does not write that session's autosave. Export writes the file you asked for and does not reveal it in Finder. Closing stdin quits the app.

The window still opens. AVFoundation needs the app process; the timeline inside it is empty until a tool adds media.

## Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "studiolane": {
      "command": "/Applications/StudioLane.app/Contents/MacOS/StudioAudioLane",
      "args": ["--mcp"]
    }
  }
}
```

Restart Claude Desktop. The server name in the client is `studiolane`.

A build from this repo, before it is copied into `/Applications`, is the same binary:

```json
{
  "mcpServers": {
    "studiolane": {
      "command": "/absolute/path/to/StudioLane/.build/StudioAudioLane.app/Contents/MacOS/StudioAudioLane",
      "args": ["--mcp"]
    }
  }
}
```

## Cursor

Put the same `mcpServers` object in `.cursor/mcp.json` for the project, or in Cursor Settings → MCP. Cursor launches the binary, passes `--mcp`, and speaks JSON-RPC on the pipes.

## Ollama or llama.cpp

Those runtimes emit tool calls; they do not speak MCP themselves. Point a small stdio bridge at the same binary and args. The bridge writes one JSON-RPC line per tool call and reads one JSON line back. The app does not embed a model.

## What the agent has to know

`get_project_state` is the planning snapshot: `revision`, `playhead`, `timeline_duration`, `audio_layout` (`playlist` or `layer`), track `id`s, and for each clip `file_path`, `source_duration`, `timeline_start`, `duration`, and fades. `editing_behavior` in that snapshot is the contract below.

- `add_clip` returns `clip_id`. Use that id for later tools. Do not guess from the file name.
- Every response echoes the JSON-RPC `id` you sent, including errors. Notifications such as `notifications/initialized` get no response. `notifications/progress` during export uses that same id as `progressToken`.
- Revision increases only when the timeline changes. Deleting a clip that is not there returns `clip_not_found` and leaves the revision alone. `undo` and `redo` are changes: the number goes up, it does not rewind. Pass `expected_revision` from the last snapshot to refuse a stale edit.
- Playlist is the default audio layout. Adding or deleting an audio clip ripples later clips on that lane and writes an automatic crossfade (0.75s unless a clip is too short). `trim_clip` and `move_clip` do not ripple and do not rewrite those fades. The result includes `rippled` and `auto_crossfade` when a call can do either. `audio_layout` tells you which mode you are in.
- Fades are clamped so fade-in plus fade-out fit the clip. Read `fade_in` and `fade_out` from the tool result, not from the duration you asked for.
- `delete_clip` requires `confirmed: true`.
- `export_project` returns immediately. Poll `get_export_status` until `is_exporting` is false. `succeeded` is true and `progress` is 1 when the file is ready. An audio-only timeline is exported as WAV, so a path ending in `.mp4` may come back as `.wav`. Use the `destination` in the result.

A short session looks like this:

1. `initialize`, then `notifications/initialized`, then `tools/list`.
2. `add_clip` with an absolute `file_path`.
3. `get_project_state`, then `get_waveform` and `render_frame` so the agent can see the sound and the picture.
4. `apply_batch` to trim and fade. If the frame looks wrong, `undo` once. That undoes the whole batch.
5. `export_project` with `destination_path` and `overwrite: true`.
6. `get_export_status` until `succeeded` is true.

## Seeing the picture and the sound

`render_frame` writes a PNG of the composited frame and returns `file_path`, `width`, `height`, and `time`. `time` defaults to the playhead. `max_dimension` is the longest edge in pixels (default 640, clamped to 16–4096). Set `include_image` to true to also get an MCP image block (`type: image`, `mimeType: image/png`, base64 `data`). An audio-only project returns `no_video`. It does not open Finder.

`get_waveform` returns `peaks` and `rms`, one pair per bucket. Values are linear amplitude, where 1 is full scale. `buckets` defaults to 64 and is clamped to 1–2048.

- Pass `clip_id` to read that file over the overlap with `start` and `duration`. Lane volume is not applied. This still works when the clip is muted.
- Omit `clip_id` to mix the timeline the way it plays: lane volume, clip gain, mute, and fades. A range with nothing audible returns `no_audio`.

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "render_frame",
    "arguments": { "time": 1.2, "max_dimension": 640, "include_image": true }
  }
}
```

## Undo

`undo` and `redo` use the same stack as the window, so an MCP edit and a change made in the UI share one history. Each call bumps `revision` by one. The number does not rewind. An empty stack returns `nothing_to_undo` or `nothing_to_redo` and leaves the revision alone.

`get_history` returns `undo_labels` and `redo_labels`, newest first, plus `can_undo` and `can_redo`. `limit` defaults to 20.

Every mutating tool records a label: Add clip, Trim clip, Move clip, Split clip, Delete clip, Set clip volume, Set track volume, Toggle mute, Set fade in, Set fade out, Clear fades, Crossfade, Create template. A window edit that did not come from a tool is labeled Edit. Export is not an undo step.

## apply_batch

`operations` is an ordered list of `{ "tool", "arguments" }`. The steps run in order. If any step fails, the timeline is put back to the state from before the call. The error is `batch_failed` and includes `failed_step` (0-based), `failed_tool`, `step_error`, and `step_message`.

A successful batch is one undo step labeled `Apply batch` and bumps `revision` once, not once per step. `dry_run: true` runs the steps and then restores the timeline. Revision does not change.

`export_project`, `cancel_export`, `undo`, `redo`, `batch_edit`, and `apply_batch` are rejected as `not_batchable` and nothing is applied. `batch_edit` is the older tool: it does not roll back.

`expected_revision` still guards the whole call. A conflict applies nothing.

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "apply_batch",
    "arguments": {
      "expected_revision": 2,
      "operations": [
        { "tool": "trim_clip", "arguments": { "clip_id": "CLIP", "new_duration": 4 } },
        { "tool": "set_fade_in", "arguments": { "clip_id": "CLIP", "duration": 0.4 } }
      ]
    }
  }
}
```

A result looks like `{ "status": "applied", "applied": 2, "revision": 3, "undo_label": "Apply batch", "results": [ ... ] }`. `undo` then returns the timeline to revision 2's contents and reports `"label": "Apply batch"`. The revision after that undo is 4.
