import Cocoa
import SwiftUI

// The menu's account cards (ideas from CodexBar: usage bars, reset countdowns and an even-use guide).
// Each card: the account name and plan, then one line per limit:
//   5시간  [██████████░░░░░|░░]  62%   ◔ 2시간 13분 후 충전
// - The bar is what is left; it turns orange under 30% and red under 10%.
// - The small tick on the bar is where you would be if you used the window evenly: a bar ending left
//   of the tick means you are using it faster than that pace.
// - The ring fills as the refill time comes closer; the text says when.

extension UsageWindow {
    // Fraction of the window already passed (0…1), from its length and the reset time.
    func elapsed(minutes: Double, now: Date = Date()) -> Double? {
        guard let resetsAt, resetsAt > now else { return nil }
        let remaining = resetsAt.timeIntervalSince(now) / 60
        return min(max(1 - remaining / minutes, 0), 1)
    }
}

enum UsageText {
    // "2시간 13분 후 충전" for today-ish resets, "10/26 (일) 오전 8:59 충전" further out.
    static func refill(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return L("아직 안 씀", "Not used yet") }
        if date <= now { return L("충전됨", "Refilled") }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 60 { return L("\(max(minutes, 1))분 후 충전", "Refills in \(max(minutes, 1))m") }
        if minutes < 24 * 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? L("\(h)시간 후 충전", "Refills in \(h)h") : L("\(h)시간 \(m)분 후 충전", "Refills in \(h)h \(m)m")
        }
        let d = minutes / (24 * 60), h = (minutes % (24 * 60)) / 60
        return h == 0 ? L("\(d)일 후 충전", "Refills in \(d)d") : L("\(d)일 \(h)시간 후 충전", "Refills in \(d)d \(h)h")
    }

    static func tint(_ left: Double) -> Color {
        if left < 10 { return .red }
        if left < 30 { return .orange }
        return .primary
    }
}

struct UsageCard: View {
    let usage: AIUsage
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundColor(usage.account.map { $0.provider.color } ?? .primary)
                Spacer(minLength: 8)
                if let plan = planText { Text(plan).font(.caption).foregroundColor(.secondary).lineLimit(1) }
            }
            // Only the limits this plan has (Gemini has no 5-hour one; a school Claude plan no overall weekly one).
            if let w = usage.fiveHour { LimitLine(name: L("5시간", "5h"), window: w, minutes: 300) }
            if let w = usage.weekly { LimitLine(name: L("주간", "Week"), window: w, minutes: 7 * 24 * 60) }
            ForEach(usage.extras, id: \.self) { Text($0).font(.caption).foregroundColor(.secondary) }
            if let note = usage.note {
                Text(note).font(.caption).foregroundColor(usage.needsLogin ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if usage.fiveHour == nil && usage.weekly == nil {
                Text(L("확인 중…", "Checking…")).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: MenuCardItem.width, alignment: .leading)
    }

    // "plus", "enterprise", … from the account details (never the email).
    private var planText: String? {
        guard let detail = usage.detail, !detail.isEmpty else { return nil }
        let parts = detail.components(separatedBy: " · ")
        return parts.count > 1 ? parts.last : (detail.contains("@") ? nil : detail)
    }
}

private struct LimitLine: View {
    let name: String
    let window: UsageWindow
    let minutes: Double

    var body: some View {
        let left = window.left()
        HStack(spacing: 8) {
            Text(name).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                .frame(width: 34, alignment: .leading)
            LeftBar(left: left, evenLeft: window.elapsed(minutes: minutes).map { 100 * (1 - $0) })
            Text("\(Int(left.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(UsageText.tint(left))
                .frame(width: 36, alignment: .trailing)
            RefillRing(progress: window.elapsed(minutes: minutes) ?? (window.resetsAt == nil ? 0 : 1))
            Text(UsageText.refill(window.resetsAt)).font(.system(size: 11)).foregroundColor(.secondary)
                .lineLimit(1).frame(width: 118, alignment: .leading)
        }
        .help(L("남은 양 \(Int(left.rounded()))% · ", "\(Int(left.rounded()))% left · ") + UsageText.refill(window.resetsAt))
    }
}

// What is left, as a rounded bar, with a tick where even use would be.
private struct LeftBar: View {
    let left: Double
    let evenLeft: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(UsageText.tint(left).opacity(left < 30 ? 0.9 : 0.75))
                    .frame(width: max(left > 0 ? 4 : 0, width * left / 100))
                if let evenLeft {
                    Rectangle().fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5, height: 10)
                        .offset(x: min(max(width * evenLeft / 100 - 0.75, 0), width - 1.5))
                }
            }
        }
        .frame(height: 6)
        .frame(maxWidth: .infinity)
    }
}

// A small ring that fills as the refill comes closer.
private struct RefillRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: progress).stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }
}

enum MenuCardItem {
    static let width: CGFloat = 400

    static func make(_ usage: AIUsage, title: String) -> NSMenuItem {
        let host = NSHostingView(rootView: UsageCard(usage: usage, title: title))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let item = NSMenuItem()
        item.view = host
        return item
    }

    // A one-line explanation of the tick and ring, under the cards.
    static func legend() -> NSMenuItem {
        let view = HStack(spacing: 6) {
            Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 1.5, height: 9)
            Text(L("고르게 쓸 때의 위치", "even-use pace")).font(.caption2).foregroundColor(.secondary)
            RefillRing(progress: 0.6).scaleEffect(0.8)
            Text(L("충전까지 지난 시간", "time toward refill")).font(.caption2).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 3)
        .frame(width: width, alignment: .leading)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let item = NSMenuItem()
        item.view = host
        return item
    }
}
