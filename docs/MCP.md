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
- Revision increases only when something changed. Deleting a clip that is not there returns `clip_not_found` and leaves the revision alone. Pass `expected_revision` from the last snapshot to refuse a stale edit.
- Playlist is the default audio layout. Adding or deleting an audio clip ripples later clips on that lane and writes an automatic crossfade (0.75s unless a clip is too short). `trim_clip` and `move_clip` do not ripple and do not rewrite those fades. The result includes `rippled` and `auto_crossfade` when a call can do either. `audio_layout` tells you which mode you are in.
- Fades are clamped so fade-in plus fade-out fit the clip. Read `fade_in` and `fade_out` from the tool result, not from the duration you asked for.
- `delete_clip` requires `confirmed: true`.
- `export_project` returns immediately. Poll `get_export_status` until `is_exporting` is false. `succeeded` is true and `progress` is 1 when the file is ready. An audio-only timeline is exported as WAV, so a path ending in `.mp4` may come back as `.wav`. Use the `destination` in the result.

A short session looks like this:

1. `initialize`, then `notifications/initialized`, then `tools/list`.
2. `add_clip` with an absolute `file_path`.
3. `get_project_state`, then `trim_clip` and `set_fade_in` with the returned `clip_id`.
4. `export_project` with `destination_path` and `overwrite: true`.
5. `get_export_status` until `succeeded` is true.
