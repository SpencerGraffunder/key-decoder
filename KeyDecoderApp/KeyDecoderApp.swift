import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

@main
struct KeyDecoderApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: KeyRecord.self)
        } catch {
            fatalError("Could not open the key library: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

/// App-wide UserDefaults keys (no other persistence path for settings).
enum Preferences {
    static let legalAccepted = "legalAccepted"
    static let lockEnabled = "lockEnabled"
    static let gridView = "libraryGridView"
}

struct RootView: View {
    @AppStorage(Preferences.legalAccepted) private var legalAccepted = false

    var body: some View {
        ZStack {
            MainTabs()
            if !legalAccepted {
                LegalNotice { legalAccepted = true }
            }
        }
    }
}

struct MainTabs: View {
    @AppStorage(Preferences.lockEnabled) private var lockEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var unlockMessage: String?

    private var needsLock: Bool { lockEnabled && !unlocked }

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("My Keys", systemImage: "key.horizontal") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay {
            if needsLock {
                LockOverlay(message: unlockMessage) { attemptUnlock() }
            }
        }
        .task {
            if !lockEnabled {
                unlocked = true
            } else if unlocked {
                // already unlocked at cold launch path
            } else {
                attemptUnlock()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if lockEnabled { unlocked = false }
            case .active:
                if lockEnabled, !unlocked { attemptUnlock() }
            default:
                break
            }
        }
    }

    private func attemptUnlock() {
        guard BiometricLock.isAvailable else {
            // Device has no biometrics (or they are disabled for apps): do not lock out.
            unlocked = true
            return
        }
        Task {
            let ok = await BiometricLock.evaluate(
                reason: "Unlock your saved key codes."
            )
            await MainActor.run {
                unlocked = ok
                unlockMessage = ok ? nil : "Use Face ID / Touch ID to open the library."
            }
        }
    }
}

struct LockOverlay: View {
    let message: String?
    let onUnlock: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.secure")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Locked")
                .font(.title2.bold())
            if let message {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button("Unlock", action: onUnlock)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Authenticates with Face ID or Touch ID")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

/// Shown once: the app is for keys the user owns or is authorized to copy.
struct LegalNotice: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Text("Use this app responsibly")
                    .font(.headline)
                Text(
                    "Key Decoder decodes bitting codes from keys you own or are authorized to copy — for example your own door, mailbox, or a property you manage. Decoding keys you have no right to duplicate is illegal in many places. Everything stays on this device."
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                Button(action: onAccept) {
                    Text("I understand").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.45))
        .accessibilityElement(children: .contain)
    }
}
