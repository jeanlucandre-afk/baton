import Defaults
import KeyboardShortcuts

enum Theme: String, Defaults.Serializable, CaseIterable {
    case dark, glass
    var label: String { self == .dark ? "Dark" : "Transparent" }
}

enum ShowOn: String, Defaults.Serializable, CaseIterable {
    case all, builtIn, main
    var label: String {
        switch self {
        case .all: "All displays"
        case .builtIn: "Built-in display only"
        case .main: "Main display only"
        }
    }
}

enum CollapsedStyle: String, Defaults.Serializable, CaseIterable {
    case iconsNext, readyCount, progress, lanes
    var label: String {
        switch self {
        case .iconsNext: "Icons and next"
        case .readyCount: "Ready count"
        case .progress: "AI progress"
        case .lanes: "Lanes"
        }
    }
}

enum BeltSpeed: String, Defaults.Serializable, CaseIterable {
    case slow, normal, fast
    var label: String { rawValue.capitalized }
    /// points per second
    var pointsPerSecond: Double { self == .slow ? 18 : self == .normal ? 30 : 48 }
}

extension Defaults.Keys {
    static let theme = Key<Theme>("theme", default: .dark)
    static let showOn = Key<ShowOn>("showOn", default: .all)
    static let collapsedStyle = Key<CollapsedStyle>("collapsedStyle", default: .iconsNext)
    static let pings = Key<Bool>("pings", default: true)
    /// Stop reading after this many minutes without mouse or keyboard input; 0 = never.
    static let idlePauseMinutes = Key<Double>("idlePauseMinutes", default: 45)
    static let pingSeconds = Key<Double>("pingSeconds", default: 6)
    /// The new-task box remembers your last choice for each switch.
    static let newTaskPing = Key<Bool>("newTaskPing", default: true)
    static let newTaskReadScreen = Key<Bool>("newTaskReadScreen", default: true)
    static let notifications = Key<Bool>("notifications", default: true)
    static let sound = Key<Bool>("sound", default: true)
    static let showShelf = Key<Bool>("showShelf", default: false)
    static let beltSpeed = Key<BeltSpeed>("beltSpeed", default: .normal)
    static let settle = Key<Double>("settle", default: 2.5)
    /// When an app update breaks how Baton reads a sidebar, re-learn it on its own.
    static let autoRepair = Key<Bool>("autoRepair", default: true)
    /// The first-run window (Welcome, permissions, keys) has been through once.
    static let onboarded = Key<Bool>("onboarded", default: false)
}

extension KeyboardShortcuts.Name {
    static let newTask = Self("newTask", default: .init(.n, modifiers: [.option]))
    static let nextReady = Self("nextReady", default: .init(.tab, modifiers: [.option]))
}
