import Foundation
import AppKit
import CoreImage

/// iPhone access (PhoneAccess.swift): `tailscale status`/`serve status` JSON read the way the window shows it; only iOS
/// peers count as phones, an iPhone named "localhost" takes its DNS name, and nothing served means no web access.
func testPhoneAccess() {
    let status = """
    {"BackendState":"Running","CertDomains":["mac.tail1.ts.net"],
     "Self":{"DNSName":"mac.tail1.ts.net.","OS":"macOS"},
     "Peer":{"k1":{"ID":"1","HostName":"localhost","DNSName":"iphone-15-pro.tail1.ts.net.","OS":"iOS","Online":true,"LastSeen":"0001-01-01T00:00:00Z"},
             "k2":{"ID":"2","HostName":"old-phone","DNSName":"","OS":"iOS","Online":false,"LastSeen":"2026-11-15T10:00:00.5Z"},
             "k3":{"ID":"3","HostName":"mini","DNSName":"mini.tail1.ts.net.","OS":"macOS","Online":true}}}
    """
    let serve = """
    {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}
    """
    let s = TailnetStatus.parse(status: Data(status.utf8), serve: Data(serve.utf8))
    expect(s.state == .running && s.host == "mac.tail1.ts.net" && s.https, "phone access: host and HTTPS")
    expect(s.url?.absoluteString == "https://mac.tail1.ts.net/", "phone access: the QR's address")
    expect(s.served == "http://127.0.0.1:8787", "phone access: what serve sends the address to")
    expect(s.phones.map(\.name) == ["iphone-15-pro", "old-phone"], "phone access: only iPhones, online first, named by DNS")
    expect(s.phones[0].online && s.phones[0].lastSeen == nil, "phone access: an online phone has no last seen")
    expect(!s.phones[1].online && s.phones[1].lastSeen != nil, "phone access: an offline phone's last seen")
    let idle = TailnetStatus.parse(status: Data(#"{"BackendState":"Stopped","Self":{"DNSName":"mac.tail1.ts.net."}}"#.utf8), serve: Data("{}".utf8))
    expect(idle.state == .stopped && idle.served == nil && !idle.https && idle.phones.isEmpty, "phone access: stopped, nothing served")
    expect(TailnetStatus.parse(status: nil, serve: nil).state == .missing, "phone access: no CLI output means not installed")
    expect(TailnetStatus.qr("https://mac.tail1.ts.net/") != nil, "phone access: the QR is drawn")
}
