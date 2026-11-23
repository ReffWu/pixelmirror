import Foundation
import LocalAuthentication
import Security
import SwiftUI

/// Android hides its PIN screen from every capture, so the mirror goes black there.
/// The PIN is typed on the Mac instead, and the app opens that screen and enters it.
enum PhoneUnlock {
  /// The PIN screen is the only one that captures as pure black, a tiny PNG.
  private static let black = "[ $(screencap -p | wc -c) -lt 100000 ]"
  private static let keyguard = "dumpsys window policy | grep -A1 KeyguardServiceDelegate"

  /// Whether the phone is locked and, only then, whether its PIN screen is open.
  static func state(_ transport: String) -> (locked: Bool, pinScreen: Bool) {
    let script = """
      \(keyguard) | grep -q showing=true || exit
      echo locked; \(black) && echo pin
      """
    let out = ADB.shell(transport, script)
    return (out.contains("locked"), out.hasSuffix("pin"))
  }

  static func isLocked(_ transport: String, _ done: @escaping @MainActor (Bool?) -> Void) {
    DispatchQueue.global().async {
      let policy = ADB.shell(transport, keyguard)
      let locked = policy.contains("showing=") ? policy.contains("showing=true") : nil
      DispatchQueue.main.async { done(locked) }
    }
  }

  static func confirmUnlock(
    _ transport: String, tries: Int = 3, _ done: @escaping @MainActor (Bool?) -> Void
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      isLocked(transport) { locked in
        if locked == false || tries <= 1 { return done(locked.map { !$0 }) }
        confirmUnlock(transport, tries: tries - 1, done)
      }
    }
  }

  /// Wakes the phone and opens its PIN screen, unless it is open already.
  /// A key opens it straight from the lock screen; a tap near the top first
  /// leaves the dimmed fingerprint prompt, which ignores keys.
  static func openPINScreen(_ transport: String, wakeBeforeChecking: Bool = false) -> Bool {
    let wake = "input keyevent KEYCODE_WAKEUP"
    let script = """
      locked() { \(keyguard) | grep -q showing=true; }
      pin_ready() { \(black) && locked; }
      locked || exit
      \(wakeBeforeChecking ? wake + "; sleep 0.3" : "")
      pin_ready && { echo ready; exit; }
      \(wakeBeforeChecking ? "" : wake)
      set -- $(wm size | grep -o '[0-9]*x[0-9]*' | tail -1 | tr x ' ')
      for try in 1 2; do
        locked || exit
        input keyevent KEYCODE_SPACE
        for wait in 1 2 3 4 5; do sleep 0.3; pin_ready && { echo ready; exit; }; done
        input tap $(($1/2)) $(($2/6)); sleep 0.5
      done
      """
    return ADB.shell(transport, script, timeout: 12).hasSuffix("ready")
  }
}

/// A phone's PIN, kept in this Mac's keychain only behind Touch ID, never synced.
enum PhonePIN {
  private static let service = "com.reffwu.pixelmirror.phone-pin"
  private static func savedKey(_ id: String) -> String { "pinSaved.\(id)" }

  static var canUseTouchID: Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
  }

  static func isSaved(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: savedKey(id)) }

  /// False when this Mac or this build can't keep it, such as a Mac without a password.
  @discardableResult
  static func save(_ pin: String, for id: String) -> Bool {
    delete(id)
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil)
    else { return false }
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecValueData as String: Data(pin.utf8),
      kSecAttrAccessControl as String: access,
      kSecUseDataProtectionKeychain as String: true,
    ]
    let saved = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    UserDefaults.standard.set(saved, forKey: savedKey(id))
    return saved
  }

  /// Asks for Touch ID. Nil if it was cancelled; a PIN Touch ID no longer opens is forgotten.
  static func read(_ id: String, reason: String) -> String? {
    let context = LAContext()
    context.localizedReason = reason
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
      kSecUseDataProtectionKeychain as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { delete(id) }
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  static func delete(_ id: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecUseDataProtectionKeychain as String: true,
    ]
    SecItemDelete(query as CFDictionary)
    UserDefaults.standard.removeObject(forKey: savedKey(id))
  }
}

@MainActor
final class UnlockModel: ObservableObject {
  @Published var name = ""
  @Published var pin = ""
  @Published var working = false
  @Published var problem: String?
  @Published var saved = false
  /// Counts wrong PINs; each one shakes the field, as on the Mac's login window.
  @Published var wrong = 0
  var onSubmit: () -> Void = {}
  var onTouchID: () -> Void = {}
}

/// The Mac's login field, over the phone's black PIN screen. Keys reach it through the mirror.
struct UnlockCard: View {
  @ObservedObject var model: UnlockModel

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "lock.fill")
        .font(.system(size: 22))
        .foregroundStyle(.secondary)
      Text(model.name)
        .font(.headline)
      field
        .modifier(Shake(times: CGFloat(model.wrong)))
        .animation(.linear(duration: 0.4), value: model.wrong)
      if let hint {
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 18)
    .frame(width: 248)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    .environment(\.colorScheme, .dark)
  }

  private var hint: String? {
    model.problem ?? (model.saved ? String(localized: "Touch ID or Enter PIN") : nil)
  }

  private var field: some View {
    HStack(spacing: 6) {
      Group {
        if model.pin.isEmpty {
          Text("Enter PIN").foregroundStyle(.tertiary)
        } else {
          Text(String(repeating: "\u{2022}", count: model.pin.count)).kerning(2)
        }
      }
      .font(.system(size: 13))
      .frame(maxWidth: .infinity, alignment: .leading)
      .lineLimit(1)
      accessory
        .frame(width: 18, height: 18)
    }
    .padding(.leading, 12)
    .padding(.trailing, 5)
    .frame(width: 188, height: 28)
    .background(.white.opacity(0.1), in: Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Enter PIN"))
  }

  @ViewBuilder private var accessory: some View {
    if model.working {
      ProgressView().controlSize(.small)
    } else if !model.pin.isEmpty {
      Button(action: model.onSubmit) {
        Image(systemName: "arrow.right.circle.fill").font(.system(size: 17))
      }
      .buttonStyle(.plain)
      .focusable(false)
      .accessibilityLabel(Text("Unlock"))
    } else if model.saved {
      Button(action: model.onTouchID) {
        Image(systemName: "touchid").font(.system(size: 15))
      }
      .buttonStyle(.plain)
      .focusable(false)
      .help(String(localized: "Unlock with Touch ID"))
    }
  }
}

/// The side-to-side shake of a wrong password.
private struct Shake: GeometryEffect {
  var times: CGFloat
  var animatableData: CGFloat {
    get { times }
    set { times = newValue }
  }

  func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(CGAffineTransform(translationX: 8 * sin(times * .pi * 4), y: 0))
  }
}
