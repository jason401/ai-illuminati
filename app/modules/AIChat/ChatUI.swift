import SwiftUI
import AILocalization
import AIProjects

// Like .plain, but the whole frame of the label is clickable, not only the drawn pixels of an icon
// (a thin pencil was almost impossible to hit). Dims while pressed or disabled.
public struct PlainHitButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { HitArea(configuration: configuration) }
    private struct HitArea: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
        }
    }
}
extension ButtonStyle where Self == PlainHitButtonStyle {
    public static var plainHit: PlainHitButtonStyle { PlainHitButtonStyle() }
}

// A section title in the chat sidebar, with an optional accessory (a + button) on the right. With a fold key a
// click on it folds the section (kept in SidebarFold); the accessory's buttons still work on their own. A folded
// section shows its badge (what waits for you inside) next to the title.
public struct SidebarHeader<Accessory: View>: View {
    let title: String
    let fold: String?
    let badge: Int
    let accessory: Accessory
    @ObservedObject private var folds = SidebarFold.shared
    public init(title: String, fold: String? = nil, badge: Int = 0, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.fold = fold; self.badge = badge; self.accessory = accessory()
    }

    public var body: some View {
        let folded = fold.map(folds.isFolded) ?? false
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            if fold != nil {
                Image(systemName: folded ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            if folded && badge > 0 {
                Text("\(badge)").font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16).background(Color.orange, in: Capsule())
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { if let fold { folds.toggle(fold) } }
        .help(fold == nil ? "" : folded ? L("눌러서 펼치기", "Click to show") : L("눌러서 접기", "Click to fold"))
        .accessibilityAddTraits(fold == nil ? [] : .isButton)
    }
}

extension SidebarHeader where Accessory == EmptyView {
    public init(title: String, fold: String? = nil, badge: Int = 0) { self.init(title: title, fold: fold, badge: badge) { EmptyView() } }
}


// A TODO's state as the board and the chat's TODO cards show it.
extension TodoItem.State {
    public var title: String {
        switch self {
        case .draft: return L("초안", "Draft")
        case .ready: return L("대기", "Ready")
        case .running: return L("진행 중", "Running")
        case .review: return L("확인 대기", "Check")
        case .done: return L("완료", "Done")
        case .needsYou: return L("네 결정 필요", "Needs you")
        case .cancelled: return L("취소", "Cancelled")
        }
    }
    public var color: Color {
        switch self {
        case .draft, .cancelled: return .secondary
        case .ready: return .green
        case .running: return .blue
        case .review: return .yellow
        case .done: return .purple
        case .needsYou: return .orange
        }
    }
}

