import SwiftUI

/// Unit 41 — the single source of truth for the app's visual language.
///
/// Before this, every colour, spacing value, corner radius, and font was an
/// inline literal scattered across the views. That made the UI inconsistent
/// (three different "card" radii, four greys) and impossible to tune in one
/// place. These tokens codify the EXISTING look — applying them changes
/// nothing visually — so future polish is a one-file edit, not a hunt.
///
/// AuDHD-first constraints (AGENTS.md) are structural, not aesthetic: no
/// token here introduces motion, flashing, or colour-only meaning. Roles
/// pair a colour with a text label at the call site.
enum DT {
    // MARK: Spacing scale (4-pt base)
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
    }

    // MARK: Corner radii
    enum Radius {
        static let bubble: CGFloat = 16
        static let panel: CGFloat = 22
        static let control: CGFloat = 18
        static let chip: CGFloat = 12
    }

    // MARK: Role colours (paired with a text label at every call site)
    enum Role {
        static let user = Color.blue
        static let agent = Color.green
        /// Model-authored speech (`say`) — distinct from app-authored agent
        /// lines so a prompt-injected message can't impersonate system truth.
        static let agentSpeech = Color.teal
        static let system = Color.orange
    }

    // MARK: Surfaces
    enum Surface {
        static let panel = Color.white.opacity(0.05)
        static let card = Color.white.opacity(0.06)
        static let activityFold = Color.white.opacity(0.04)
        /// Window background gradient (top-leading → bottom-trailing).
        static let backgroundTop = Color(red: 0.07, green: 0.09, blue: 0.13)
        static let backgroundBottom = Color(red: 0.10, green: 0.12, blue: 0.17)
    }

    // MARK: Typography (system rounded throughout)
    enum Font {
        static let title = SwiftUI.Font.system(size: 22, weight: .bold, design: .rounded)
        static let bubble = SwiftUI.Font.system(size: 13, weight: .medium, design: .rounded)
        static let bubbleHeader = SwiftUI.Font.system(size: 11, weight: .bold, design: .rounded)
        static let timestamp = SwiftUI.Font.system(size: 10, weight: .medium, design: .rounded)
        static let caption = SwiftUI.Font.system(size: 11, weight: .semibold, design: .rounded)
        static let composer = SwiftUI.Font.system(size: 14, weight: .medium, design: .rounded)
    }
}
