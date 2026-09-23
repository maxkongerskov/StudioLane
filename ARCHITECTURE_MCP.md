# MCP Server Architecture — StudioAudioLane

## Design Principles

1. **In-process server** — MCP runs inside the app binary (SwiftNIO or the `swift-mcp-sdk` package). No helper process, no IPC complexity. Binds to localhost only.
2. **Thin tool handlers** — Each MCP tool maps 1:1 to an existing `EditorModel` method. The MCP layer adds no business logic; it only serializes, validates input, and routes to the model.
3. **All mutations are atomic** — Every edit routes through `EditorModel`'s existing `rebuildComposition()` / history push path. If a multi-op batch fails partway, the entire batch is rolled back.
4. **Revision conflict detection** — Every `get_project_state` returns a monotonically increasing `revision` integer. Every mutating tool accepts an optional `expected_revision`. If provided and stale, the tool returns a conflict error instead of silently overwriting a human edit made in the UI.

## Tool Surface (17 tools)

### Read

| Tool | Input | Output |
|------|-------|--------|
| `get_project_state` | `compact?: bool` | Full or compact timeline snapshot + `revision` |
| `get_schema_docs` | `section?: string` | JSON model documentation with optional section filter |
| `get_export_status` | — | `{ is_exporting, progress, destination?, error? }` |

### Edit (single-op)

| Tool | Input | Routes to |
|------|-------|-----------|
| `add_clip` | `file_path`, `track_kind`, `start?`, `track_id?` | `addVideo` / `addAudio` |
| `trim_clip` | `clip_id`, `new_in?`, `new_duration?` | `setClipLength` / direct `inPoint` mutation |
| `move_clip` | `clip_id`, `new_start`, `track_id?` | Direct `timelineStart` + `trackID` mutation |
| `split_clip` | `clip_id`, `at_time` | `splitSelectedAtPlayhead` (adapted to accept position) |
| `delete_clip` | `clip_id`, `confirmed: bool` | `deleteClip` |
| `set_clip_volume` | `clip_id`, `gain` | Direct `gain` mutation |
| `set_track_volume` | `track_id`, `volume` | `setTrackVolume` |
| `toggle_mute` | `clip_id` | Direct `muted` toggle |
| `set_fade_in` | `clip_id`, `duration` | `fadeIn` + `clampFades()` |
| `set_fade_out` | `clip_id`, `duration` | `fadeOut` + `clampFades()` |
| `clear_fades` | `clip_id` | Zero both, `clampFades()` |

### Edit (batch)

| Tool | Input | Notes |
|------|-------|-------|
| `batch_edit` | `ops: [EditOp]`, `expected_revision?` | Ordered array of any single-op above. Applied atomically: all succeed or all roll back. Returns per-op results. |

### Export

| Tool | Input | Notes |
|------|-------|-------|
| `export_project` | `destination_path`, `container` (mp4/mov/m4v), `codec`, `quality`, `overwrite?: bool` | Non-blocking. Returns `{ job_id, status: "started" }` immediately. |
| `cancel_export` | — | Cancels active export, deletes partial output. |

## Data Model (MCP JSON)

```json
{
  "revision": 14,
  "timeline_duration": 45.2,
  "tracks": [
    { "id": "uuid", "kind": "video", "name": "Video", "volume": 1.0 }
  ],
  "clips": [
    {
      "id": "uuid",
      "track_id": "uuid",
      "name": "interview.mp4",
      "timeline_start": 0.0,
      "duration": 12.4,
      "source_in": 3.2,
      "fade_in": 0.5,
      "fade_out": 1.0,
      "gain": 0.8,
      "muted": false
    }
  ]
}
```

Compact mode omits `source_in` when zero, omits `gain` when 1.0, omits `muted` when false — same pattern as FableCut's compact project view.

## Batch Edit Op Format

```json
{
  "ops": [
    { "action": "trim_clip", "clip_id": "a1b2", "new_in": 2.0, "new_duration": 8.0 },
    { "action": "set_fade_in", "clip_id": "a1b2", "duration": 0.5 },
    { "action": "set_fade_out", "clip_id": "a1b2", "duration": 1.0 },
    { "action": "add_clip", "file_path": "/path/music.mp3", "track_kind": "audio", "start": 0.0 }
  ]
}
```

Each op is validated (clip exists, values in range) before any mutation begins. If validation fails for any op, the entire batch is rejected with per-op error details.

## Revision Conflict Flow

```
AI: get_project_state() → { revision: 14, ... }
AI: batch_edit(ops, expected_revision: 14)
    ├── Model revision still 14 → apply, bump to 15, return success
    └── Model revision now 16 (user edited in UI) → return conflict error with current revision
AI: re-read state, re-plan, retry with expected_revision: 16
```

No forcing or overriding. The AI must always observe the latest state after a conflict.

## Export Flow

```
AI: export_project(destination_path: "/tmp/output.mp4", container: "mp4", codec: "h264", quality: "high", overwrite: true)
    ← { job_id: "exp-001", status: "started" }

AI: get_export_status()
    ← { is_exporting: true, progress: 0.42, destination: "/tmp/output.mp4" }

AI: get_export_status()
    ← { is_exporting: false, progress: 1.0, destination: "/tmp/output.mp4" }
```

`export_project` bypasses the save panel (unlike the UI's `beginExport(with:)`) by taking a pre-resolved destination path. The `overwrite` flag must be `true` if the destination file already exists; otherwise the tool returns an error rather than silently clobbering.

## Confirmation Gate

`delete_clip` requires `confirmed: true` in the input. If omitted or false, the tool returns:
```json
{ "status": "confirmation_required", "message": "Set confirmed=true to delete clip a1b2 (interview.mp4, 12.4s on Video track)." }
```

This matches DaVinci Resolve MCP's gate pattern. No other tools require confirmation initially.

## Implementation Notes

### Package Structure

```
Sources/StudioAudioLane/
  EditorModel.swift        (existing — no changes to core logic)
  MCPServer.swift           (new — MCP server lifecycle, tool registry, dispatch)
  MCPSchema.swift           (new — Codable structs for request/response types)
  MCPHandlers.swift         (new — per-tool handlers, thin wrappers into EditorModel)
```

### Threading

`EditorModel` is `@MainActor`. MCP server runs on a background queue. Each tool handler dispatches to `MainActor` via `await MainActor.run { ... }` or a structured concurrency task. The `batch_edit` handler wraps the entire sequence in a single `MainActor` block to guarantee atomicity.

### History & Undo

Every mutating tool that calls a public `EditorModel` method inherits its history push automatically. For direct mutations (fade, gain, trim), the handler wraps the change in `pushHistory()` / `rebuildComposition()` — the same pattern the UI uses. Batch operations push a single history entry for the entire group.

### `swift-mcp-sdk`

Apple's Swift SDK for MCP (https://github.com/modelcontextprotocol/swift-sdk) provides the transport, JSON-RPC framing, and tool registration. We implement a `MCPTool` for each entry. If the SDK is too opinionated for our needs, a minimal stdio JSON-RPC handler (~200 lines) is sufficient — FableCut does this in zero-dep Node.

### Build target

The MCP server is compiled into the main app binary. It activates on a launch argument (`--mcp`) or via a preference toggle. This means:
- `./.build/StudioAudioLane.app/Contents/MacOS/StudioAudioLane --mcp` starts the app with the MCP server listening on stdio.
- The normal app launch (no flag) behaves identically to today.

## Phased Delivery

**Phase 1 — Foundation** (core read + 3 most impactful edits)
- `get_project_state`, `get_schema_docs`, `get_export_status`
- `add_clip`, `set_fade_in`, `set_fade_out`
- Stdio transport, `--mcp` launch flag

**Phase 2 — Full editing surface**
- `trim_clip`, `move_clip`, `split_clip`, `delete_clip`, `set_clip_volume`, `set_track_volume`, `toggle_mute`, `clear_fades`
- `batch_edit` with revision conflict detection
- `export_project` + `cancel_export`

**Phase 3 — Polish**
- Export progress callbacks (push notification to MCP client)
- Crossfade composition helper (`crossfade_clips` tool that wraps `set_fade_out` + `set_fade_in` + `move_clip`)
- AI-authored project templates (agent can create a new project from a text description)

## What Makes This Competitive

| Feature | FableCut | DaVinci MCP | Premiere MCP | Ours |
|---------|----------|-------------|--------------|------|
| In-process (no bridge) | ✅ | ❌ (external Python) | ❌ (CEP panel) | ✅ |
| Atomic batch ops | ✅ | ❌ | ❌ | ✅ |
| Revision conflict detection | ✅ | ❌ | ❌ | ✅ |
| Export via MCP | ❌ | ✅ | ✅ | ✅ |
| Fade in/out per clip | ✅ | ✅ | ✅ | ✅ |
| Progressive discovery | ❌ | ✅ | ✅ | Not needed at 17 tools |
| Native macOS app | ❌ (browser) | ❌ (external) | ❌ (external) | ✅ |

The in-process advantage is the biggest differentiator: no external bridge to install, no version mismatch between the editor and the MCP server, and the AI sees exactly the same state the user sees.
