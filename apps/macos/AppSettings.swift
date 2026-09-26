import AppKit
import SwiftUI
import ServiceManagement

enum CelebrationIntensity: String, CaseIterable, Identifiable {
    case subtle, normal, celebratory
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum MotionPreference: String, CaseIterable, Identifiable {
    case system, reduced, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Follow system"
        case .reduced: return "Reduced"
        case .full: return "Full"
        }
    }
}

enum ScreenPreference: String, CaseIterable, Identifiable {
    case notched, main
    var id: String { rawValue }
    var label: String { self == .notched ? "Built-in display (notch)" : "Main display" }
}

/// MVP settings (PRD §35). Stored in UserDefaults; nothing leaves the Mac.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var completionAnimation: Bool { didSet { d.set(completionAnimation, forKey: "completionAnimation") } }
    @Published var completionSound: Bool { didSet { d.set(completionSound, forKey: "completionSound") } }
    @Published var attentionSound: Bool { didSet { d.set(attentionSound, forKey: "attentionSound") } }
    @Published var intensity: CelebrationIntensity { didSet { d.set(intensity.rawValue, forKey: "intensity") } }
    @Published var motion: MotionPreference { didSet { d.set(motion.rawValue, forKey: "motion") } }
    @Published var showCompletedSessions: Bool { didSet { d.set(showCompletedSessions, forKey: "showCompletedSessions") } }
    @Published var autoExpandOnQuestion: Bool { didSet { d.set(autoExpandOnQuestion, forKey: "autoExpandOnQuestion") } }
    @Published var screen: ScreenPreference { didSet { d.set(screen.rawValue, forKey: "screen") } }
    @Published var diagnosticLogging: Bool { didSet { d.set(diagnosticLogging, forKey: "diagnosticLogging") } }
    @Published var readPlanUsage: Bool { didSet { d.set(readPlanUsage, forKey: "readPlanUsage") } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    init() {
        d.register(defaults: [
            "completionAnimation": true,
            "completionSound": true,
            "attentionSound": true,
            "intensity": CelebrationIntensity.normal.rawValue,
            "motion": MotionPreference.system.rawValue,
            "showCompletedSessions": true,
            "autoExpandOnQuestion": true,
            "screen": ScreenPreference.notched.rawValue,
            "diagnosticLogging": false,
            "readPlanUsage": true,
            "onboarded": false,
        ])
        completionAnimation = d.bool(forKey: "completionAnimation")
        completionSound = d.bool(forKey: "completionSound")
        attentionSound = d.bool(forKey: "attentionSound")
        intensity = CelebrationIntensity(rawValue: d.string(forKey: "intensity") ?? "") ?? .normal
        motion = MotionPreference(rawValue: d.string(forKey: "motion") ?? "") ?? .system
        showCompletedSessions = d.bool(forKey: "showCompletedSessions")
        autoExpandOnQuestion = d.bool(forKey: "autoExpandOnQuestion")
        screen = ScreenPreference(rawValue: d.string(forKey: "screen") ?? "") ?? .notched
        diagnosticLogging = d.bool(forKey: "diagnosticLogging")
        readPlanUsage = d.bool(forKey: "readPlanUsage")
        onboarded = d.bool(forKey: "onboarded")
    }

    var reduceMotion: Bool {
        switch motion {
        case .system: return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        case .reduced: return true
        case .full: return false
        }
    }

    // Launch at login is owned by the system, not stored here.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.info("launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Minimal local diagnostics. Never logs payload contents, prompts, code, or env vars.
enum Log {
    static var enabled = UserDefaults.standard.bool(forKey: "diagnosticLogging")

    static func info(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("[ClaudeNotch] %@", message())
    }
}
