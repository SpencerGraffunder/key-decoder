import Foundation
import LocalAuthentication

/// Optional Face ID / Touch ID gate (LocalAuthentication only — no accounts, no network).
enum BiometricLock {
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            || LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func evaluate(reason: String) async -> Bool {
        let context = LAContext()
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
