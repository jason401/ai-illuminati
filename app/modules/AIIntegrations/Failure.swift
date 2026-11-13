import Foundation

// A tool call's error reply, the MCP result shape the app's tool gateway uses too ({content, isError}).
func mcpFailure(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": true]
}
