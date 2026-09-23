import Foundation

// MARK: - MCP JSON Schema Types

struct MCPTrack: Codable {
    let id: String
    let kind: String
    let name: String
    let volume: Double
}

struct MCPClip: Codable {
    let id: String
    let trackId: String
    let name: String
    let timelineStart: Double
    let duration: Double
    let sourceIn: Double
    let fadeIn: Double
    let fadeOut: Double
    let gain: Double
    let muted: Bool
}

struct MCPProjectState: Codable {
    let revision: Int
    let timelineDuration: Double
    let isPlaying: Bool
    let isExporting: Bool
    let tracks: [MCPTrack]
    let clips: [MCPClip]
}

struct MCPErrorResponse: Codable, Error {
    let error: String
    let message: String
    let currentRevision: Int?
}

struct MCPExportJobStatus: Codable {
    let isExporting: Bool
    let progress: Double
    let destination: String?
    let error: String?
}

typealias MCPBatchOp = [String: Any]
typealias MCPBatchResult = [String: Any]

// MARK: - MCP Tool Schema (JSON-RPC)

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

struct MCPToolCall {
    let id: Any
    let name: String
    let arguments: [String: Any]
}

struct MCPToolResult {
    let id: Any
    let isError: Bool
    let content: String
}

// MARK: - JSON-RPC Framing

enum MCPJSONRPC {
    static func notification(method: String, params: [String: Any]) -> Data {
        encode([
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ])
    }

    static func response(id: Any, result: Any) -> Data {
        let dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        return encode(dict)
    }

    static func error(id: Any, code: Int, message: String) -> Data {
        let dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ] as [String: Any]
        ]
        return encode(dict)
    }

    static func encode(_ obj: Any) -> Data {
        guard JSONSerialization.isValidJSONObject(obj) else {
            return Data(#"{"jsonrpc":"2.0","error":{"code":-32700,"message":"Invalid JSON"}}"#.utf8)
        }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}
