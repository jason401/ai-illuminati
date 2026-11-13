import Foundation
import AIAccounts
import AIWorkspace
import AIProjects
import AIChat
@testable import AIIntegrations

private final class HubFixture: ToolProvider {
    let label: String
    var active = true
    var visible = true
    var calls = 0
    init(_ label: String) { self.label = label }
    func tools() -> [[String: Any]] { [["name": "hub_collision"]] }
    func tools(context: ToolContext) -> [[String: Any]] { visible ? tools() : [] }
    func call(_ name: String, _ arguments: [String: Any], context: ToolContext) -> [String: Any] {
        calls += 1
        return ["picked": label]
    }
}

func testToolHub() {
    let expected: [ToolProvider] = [FaceLink.shared, DriveLink.shared, GitLink.shared, PlanLink.shared, PeerLink.shared,
        ConveneLink.shared, ChatLink.shared, MemoryLink.shared, ProjectMakerLink.shared, TaskLink.shared,
        TodoAddLink.shared, StorageLink.shared, ExternalMCP.shared]
    let actual = ToolHub.appProviders
    let appHub = ToolHub(providers: { ToolHub.appProviders })
    let ordinary = ToolContext(room: UUID(), roots: [])
    var consultation = ordinary; consultation.origin = .consulted
    var sideAnswer = ordinary; sideAnswer.origin = .side
    let consultedProviders = appHub.available(context: consultation)
    let expectedConsulted = expected.filter { $0 !== PeerLink.shared && $0 !== ConveneLink.shared }
    expect(consultedProviders.count == 11 && zip(consultedProviders, expectedConsulted).allSatisfy { $0 === $1 },
           "consulted provider identities exclude Peer and Convene before their own gates")
    let sideProviders = appHub.available(context: sideAnswer), legacyProviders = appHub.available(context: ordinary, legacy: true)
    expect(sideProviders.count == 1 && sideProviders[0] === PeerLink.shared, "side provider identity is Peer only")
    expect(legacyProviders.count == 1 && legacyProviders[0] === FaceLink.shared, "legacy provider identity is Face only")
    expect(actual.count == 13 && zip(actual, expected).allSatisfy { $0 === $1 }, "the app supplies all 13 providers in their original order")
    // The explicit list must keep reading replaceable shared providers (Drive's fake backend).
    let previousDrive = DriveLink.shared
    let replacement = DriveLink(auth: .shared)
    DriveLink.shared = replacement
    expect(ToolHub.appProviders[1] === replacement, "the app list follows the current Drive provider")
    DriveLink.shared = previousDrive

    let socket = ToolHub.socketPath
    ToolHub.socketPath = AccountStore.home + "/hub.sock"
    defer { ToolHub.socketPath = socket }
    let first = HubFixture("first"), second = HubFixture("second")
    var instant = Date()
    let hub = ToolHub(providers: { [first, second] }, now: { instant })
    let room = UUID(), project = UUID()
    let member = hub.register(room: room, roots: [], projectRun: project)
    func reply(_ op: String, key: String? = nil, legacy: Bool = false, name: String = "hub_collision") -> [String: Any] {
        hub.handle(["op": op, "session": key ?? member, "name": name], legacy: legacy)
    }
    func error(_ response: [String: Any]) -> Bool { response["isError"] as? Bool == true }
    func names(_ response: [String: Any]) -> [String] {
        (response["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
    expect(names(reply("tools")) == ["hub_collision", "hub_collision"], "duplicate tool names retain provider order")
    expect(reply("call")["picked"] as? String == "first" && first.calls == 1 && second.calls == 0,
           "a duplicate tool is called on the first eligible provider")
    first.active = false
    expect(names(reply("tools")) == ["hub_collision"] && reply("call")["picked"] as? String == "second",
           "inactive providers are absent from both listing and calls")
    first.active = true; first.visible = false
    expect(names(reply("tools")) == ["hub_collision"] && reply("call")["picked"] as? String == "second",
           "context-hidden providers are absent from both listing and calls")
    second.active = false
    expect(names(reply("tools")).isEmpty && error(reply("call")), "an unavailable tool cannot be called by name")
    first.visible = true; second.active = true
    expect(error(reply("call", key: "unknown")) && error(reply("tools", key: "unknown")),
           "unknown sessions cannot list or call tools")
    expect(error(reply("call", name: "missing")), "unlisted names cannot be called")
    let side = hub.register(room: room, roots: [], origin: .side)
    expect(!names(reply("tools", key: side)).contains("hub_collision") && error(reply("call", key: side)),
           "side answers cannot list or call non-Peer providers")
    let consulted = hub.register(room: room, roots: [], origin: .consulted)
    expect(names(reply("tools", key: consulted)) == ["hub_collision", "hub_collision"],
           "consulted answers keep ordinary providers")
    for name in ["ask_ai", "convene_meeting", "meeting_result"] {
        expect(error(reply("call", key: consulted, name: name)), "consulted answers cannot call " + name)
    }
    expect(!names(reply("tools", legacy: true)).contains("hub_collision") && error(reply("call", legacy: true)),
           "legacy access cannot list or call providers other than Face")
    expect((reply("tools")["slow"] as? [String]) == [], "slow names include only exposed tools")
    expect(error(reply("other")), "unknown operations fail")
    hub.revoke(project: project)
    expect(error(reply("call")) && error(reply("tools")), "revoked project sessions cannot list or call")
    expect(!error(reply("tools", key: consulted)), "revocation preserves sessions of other runs")
    instant = instant.addingTimeInterval(7201)
    expect(error(reply("tools", key: consulted)) && error(reply("call", key: consulted)), "expired sessions cannot list or call")
}
