import AVFoundation
import AppKit
import SwiftUI

/// Opens one window per phone, keeps it going across Wi-Fi drops and reboots,
/// and reopens it by itself when the phone comes back.
@MainActor
final class MirrorManager: ObservableObject {
  static let shared = MirrorManager()

  @Published private(set) var mirroring: Set<String> = []
  /// Phones with any window open, shown in the menu bar while they are.
  @Published private(set) var live: [Phone] = []
  @Published private(set) var recording = false
  /// Phone windows by phone id, app windows by phone id and package.
  private var controllers: [String: MirrorWindowController] = [:]

  /// Phones whose window someone closed: they are not reopened until they disconnect.
  private var dismissed: Set<String> = []
  /// Phones whose own window turned their screen off, to lock once their last window closes.
  private var darkened: Set<String> = []
  private var quitting = false

  private init() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { MirrorManager.shared.quit() }
    }
  }

  /// Ends every session, then leaves each phone as the app found it, before the app exits.
  private func quit() {
    quitting = true
    let phones = live
    for controller in controllers.values { controller.close() }
    for phone in phones {
      PhonePower.release(phone, lock: darkened.contains(phone.id) && phoneScreenOff, settle: true)
    }
  }

  private var phoneScreenOff: Bool {
    UserDefaults.standard.object(forKey: "phoneScreenOff") as? Bool ?? true
  }

  /// Phones shown as a computer desktop instead of a phone screen.
  @Published private(set) var computers = Set(
    UserDefaults.standard.stringArray(forKey: "computerPhones") ?? [])

  /// Switches a phone, by default the one in front, between its own screen and a desktop.
  func toggleComputer(_ phone: Phone? = nil) {
    guard let phone = phone ?? currentPhone else { return }
    if computers.contains(phone.id) {
      computers.remove(phone.id)
    } else {
      computers.insert(phone.id)
    }
    UserDefaults.standard.set(Array(computers), forKey: "computerPhones")
    if let controller = controllers[phone.id] {
      controller.setComputer(computers.contains(phone.id))
    } else {
      open(phone)
    }
  }

  func phoneBecameReady(_ phone: Phone) {
    for controller in controllers.values where controller.phone.id == phone.id {
      controller.resume(with: phone)
    }
    sessionsChanged()
    if controllers[phone.id] == nil, !dismissed.contains(phone.id) {
      open(phone)
    }
  }

  func phonesChanged(_ phones: [Phone]) {
    let present = Set(phones.map(\.id))
    dismissed = dismissed.intersection(present)
    for controller in controllers.values where !present.contains(controller.phone.id) {
      controller.phoneWentAway()
    }
    sessionsChanged()
  }

  func open(_ phone: Phone) {
    dismissed.remove(phone.id)
    show(key: phone.id) {
      MirrorWindowController(phone: phone, computer: computers.contains(phone.id))
    }
  }

  /// Opens a phone app in a Mac window of its own.
  func open(_ app: PhoneApp, on phone: Phone) {
    PhoneApps.shared.opened(app)
    show(key: "\(phone.id)/\(app.package)") { MirrorWindowController(phone: phone, app: app) }
  }

  private func show(key: String, make: () -> MirrorWindowController) {
    if let controller = controllers[key] {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let controller = make()
    let isPhone = controller.app == nil
    let phone = controller.phone
    let phoneID = phone.id
    if !controllers.values.contains(where: { $0.phone.id == phoneID }) {
      PhonePower.keepAwake(phone)
    }
    if isPhone { darkened.insert(phoneID) }
    controller.onClose = { [weak self] in
      guard let self else { return }
      self.controllers[key] = nil
      if isPhone {
        self.mirroring.remove(phoneID)
        self.dismissed.insert(phoneID)
      }
      self.sessionsChanged()
      self.releaseIfLast(phone)
    }
    controllers[key] = controller
    if isPhone { mirroring.insert(phoneID) }
    sessionsChanged()
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func sessionsChanged() {
    var phones: [Phone] = []
    for controller in controllers.values
    where !phones.contains(where: { $0.id == controller.phone.id }) {
      phones.append(controller.phone)
    }
    phones.sort { $0.name < $1.name }
    if phones != live { live = phones }
    let recording = controllers.values.contains { $0.isRecording }
    if recording != self.recording { self.recording = recording }
  }

  /// Once a phone's last window has closed, gives it back its own settings, and locks it
  /// if this app had turned its screen off.
  private func releaseIfLast(_ phone: Phone) {
    guard !quitting, !controllers.values.contains(where: { $0.phone.id == phone.id }) else {
      return
    }
    let lock = darkened.contains(phone.id) && phoneScreenOff
    // The mirror's own cleanup lights the screen as it ends; let it finish first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, !self.quitting,
        !self.controllers.values.contains(where: { $0.phone.id == phone.id })
      else { return }
      self.darkened.remove(phone.id)
      DispatchQueue.global().async { PhonePower.release(phone, lock: lock, settle: false) }
    }
  }

  /// The phone's own window, on its screen or its desktop.
  func phoneWindow(of phone: Phone) -> MirrorWindowController? { controllers[phone.id] }

  /// The phone's own window if it is open, else one of its app windows.
  func controller(for phone: Phone) -> MirrorWindowController? {
    controllers[phone.id] ?? controllers.values.first { $0.phone.id == phone.id }
  }

  /// Closes every window of the phone.
  func stop(_ phone: Phone) {
    for controller in controllers.values where controller.phone.id == phone.id {
      controller.close()
    }
  }

  var keyController: MirrorWindowController? {
    controllers.values.first { $0.window?.isKeyWindow == true }
      ?? controllers.values.first { $0.window?.isMainWindow == true }
  }

  /// The phone the next command is for: the one in front, else the only one there is.
  var currentPhone: Phone? {
    keyController?.phone ?? DeviceHub.shared.phones.first
  }
}

/// Keeps a mirrored phone awake on its charger, and puts its own Stay awake setting back
/// once mirroring ends. Mirroring sessions overlap, so the app keeps the original, not each one.
enum PhonePower {
  private static func key(_ phone: Phone) -> String { "stayAwake.\(phone.id)" }

  static func keepAwake(_ phone: Phone) {
    let key = key(phone)
    let transport = phone.transport
    DispatchQueue.global().async {
      if UserDefaults.standard.string(forKey: key) == nil {
        let value = ADB.shell(transport, "settings get global stay_on_while_plugged_in")
        guard Int(value) != nil else { return }
        UserDefaults.standard.set(value, forKey: key)
      }
      _ = ADB.shell(transport, "settings put global stay_on_while_plugged_in 7")
    }
  }

  /// Restores the setting and, when `lock`, presses the power key like a phone laid face down.
  /// `settle` first waits on the phone for the mirror's own cleanup, which lights the screen.
  nonisolated static func release(_ phone: Phone, lock: Bool, settle: Bool) {
    let key = key(phone)
    var steps = settle ? ["sleep 1"] : []
    if let original = UserDefaults.standard.string(forKey: key), Int(original) != nil {
      steps.append("settings put global stay_on_while_plugged_in \(original)")
    }
    if lock {
      steps.append("dumpsys power | grep -q 'mWakefulness=Awake' && input keyevent KEYCODE_POWER")
    }
    guard !steps.isEmpty else { return }
    _ = ADB.shell(phone.transport, steps.joined(separator: "; "))
    UserDefaults.standard.removeObject(forKey: key)
  }
}

@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate, MirrorSessionDelegate {
  private(set) var phone: Phone
  let app: PhoneApp?
  /// The phone's desktop, with a taskbar and windows, at the size of this window.
  private(set) var computer: Bool
  /// An app or a desktop has a display of its own, which follows the window.
  private var ownsDisplay: Bool { app != nil || (computer && !unlocking) }
  /// A locked phone gives its desktop no taskbar, so the desktop waits on its lock screen.
  private var unlocking = false
  private var lockTimer: Timer?
  private var lockCheck: UUID?
  /// What the last check found: the phone is locked, and its PIN screen is open.
  private var phoneLocked = false
  private var checkingLock = false
  /// Touch ID asks once each time the phone locks, not again after it is cancelled.
  private var touchIDAsked = false
  /// The app opens the PIN screen by itself once each time the phone locks.
  private var pinScreenOpened = false
  private var openingPINScreen = false
  private var submittingPIN = false
  private let mirrorView = MirrorView()
  private let overlay = NSHostingView(rootView: MirrorOverlay(text: "", busy: true))
  private let notice = NSHostingView(rootView: InputBlockedNotice(maker: "", close: {}))
  private let unlockModel = UnlockModel()
  private lazy var unlockCard = NSHostingView(rootView: UnlockCard(model: unlockModel))
  private var session: MirrorSession?
  private let files = FileSender()
  private let keyMapper = KeyMapper()
  private let keyMapBar = NSHostingView(rootView: AnyView(EmptyView()))
  /// The app whose keys are in use: this window's app, or the one in front on the phone.
  private var mapPackage: String?
  private var foregroundTimer: Timer?
  private lazy var transferHUD = NSHostingView(
    rootView: TransferHUD(sender: files, dropping: false))
  private var videoSize = CGSize.zero
  private var retries = 0
  private var phonePresent = true
  var onClose: (() -> Void)?

  @AppStorage("phoneScreenOff") private var phoneScreenOff = true
  private lazy var buttons = PhoneButtons(controller: self)

  init(phone: Phone, app: PhoneApp? = nil, computer: Bool = false) {
    self.phone = phone
    self.app = app
    self.computer = computer && app == nil
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: app == nil ? 360 : 400, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.titleVisibility = .visible
    window.backgroundColor = .black
    window.appearance = NSAppearance(named: .darkAqua)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self

    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.cgColor
    mirrorView.translatesAutoresizingMaskIntoConstraints = false
    overlay.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(mirrorView)
    container.addSubview(overlay)
    notice.translatesAutoresizingMaskIntoConstraints = false
    notice.isHidden = true
    container.addSubview(notice)
    transferHUD.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(transferHUD)
    keyMapBar.translatesAutoresizingMaskIntoConstraints = false
    keyMapBar.isHidden = true
    container.addSubview(keyMapBar)
    unlockCard.translatesAutoresizingMaskIntoConstraints = false
    unlockCard.isHidden = true
    container.addSubview(unlockCard)
    NSLayoutConstraint.activate([
      keyMapBar.leadingAnchor.constraint(
        greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
      keyMapBar.trailingAnchor.constraint(
        lessThanOrEqualTo: container.trailingAnchor, constant: -12),
      keyMapBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      keyMapBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
      transferHUD.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      transferHUD.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
      mirrorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      mirrorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      mirrorView.topAnchor.constraint(equalTo: container.topAnchor),
      mirrorView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      overlay.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      notice.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      notice.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      notice.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
      unlockCard.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      unlockCard.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    window.contentView = container
    window.addTitlebarAccessoryViewController(buttons)
    mirrorView.onDragging = { [weak self] dropping in
      guard let self else { return }
      self.transferHUD.rootView = TransferHUD(sender: self.files, dropping: dropping)
    }
    mirrorView.onDropFiles = { [weak self] urls in self?.send(urls) }
    mirrorView.onPasteImage = { [weak self] image in self?.send(image) }
    mirrorView.keyMapper = keyMapper
    mirrorView.keyMapView.onChange = { [weak self] map in self?.updateKeyMapBar(map) }
    mirrorView.keyMapView.onDone = { [weak self] in self?.finishEditingKeys() }
    if let app { useKeys(of: app.package) }
    mirrorView.onLockedKey = { [weak self] event in self?.lockedKey(event) ?? false }
    unlockModel.onTouchID = { [weak self] in self?.unlockWithTouchID() }
    unlockModel.onSubmit = { [weak self] in self?.submitPIN() }
    updateTitle()
    applyShape()
    startSession()
    if app == nil { watchLock() }
  }

  /// A tall phone or a wide desktop, each remembered where it was left.
  private func applyShape() {
    guard let window else { return }
    let name =
      app.map { "App-\($0.package)" } ?? (computer ? "Computer-\(phone.id)" : "Mirror-\(phone.id)")
    let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)")
    window.setFrameAutosaveName(name)
    window.acceptsMouseMovedEvents = computer
    mirrorView.computer = computer
    if ownsDisplay {
      window.contentResizeIncrements = NSSize(width: 1, height: 1)  // no aspect ratio
      window.contentMinSize =
        computer ? NSSize(width: 640, height: 400) : NSSize(width: 280, height: 360)
    } else {
      window.contentMinSize = NSSize(width: 160, height: 160)
    }
    if let saved {
      window.setFrame(from: saved)
    } else if computer, let screen = window.screen ?? NSScreen.main {
      let visible = screen.visibleFrame
      let size = NSSize(
        width: min(1280, visible.width * 0.9), height: min(800, visible.height * 0.85))
      window.setFrame(
        window.frameRect(forContentRect: NSRect(origin: .zero, size: size)), display: true)
      window.center()
    } else if !computer, app == nil {
      window.setContentSize(NSSize(width: 360, height: 780))
      window.center()
    } else {
      window.center()
    }
  }

  /// Switches this window between the phone's screen and its desktop.
  func setComputer(_ on: Bool) {
    guard app == nil, on != computer else { return }
    if isRecording { session?.stopRecording() }
    session?.delegate = nil
    session?.stop()
    session = nil
    computer = on
    stopWaitingForUnlock()
    videoSize = .zero
    mirrorView.videoSize = .zero
    mirrorView.displayLayer.flushAndRemoveImage()
    applyShape()
    updateTitle()
    buttons.update(screenOn: isPhoneScreenOn)
    buttons.update(computer: on)
    retries = 0
    startSession()
  }

  required init?(coder: NSCoder) { fatalError() }

  // MARK: - Session

  private func startSession() {
    session?.delegate = nil
    session?.stop()
    session = nil
    showOverlay(String(localized: "Connecting to \(phone.name)…"), busy: true)
    notice.isHidden = true
    guard computer, !unlocking else { return openSession() }
    let check = UUID()
    lockCheck = check
    PhoneUnlock.isLocked(phone.transport) { [weak self] locked in
      guard let self, self.lockCheck == check, self.computer, self.session == nil else { return }
      if locked == true { self.waitForUnlock() }
      self.openSession()
    }
  }

  private func openSession() {
    let display =
      ownsDisplay
      ? MirrorSession.OwnDisplay(package: app?.package, size: displaySize, dpi: dpi) : nil
    let session = MirrorSession(
      transport: phone.transport, isUSB: phone.isUSB, renderer: mirrorView.displayLayer,
      display: display)
    session.delegate = self
    mirrorView.control = session.input
    keyMapper.control = session.input
    self.session = session
    session.start()
  }

  /// Shows the phone's lock screen, to unlock from here, and opens the desktop once it is unlocked.
  private func waitForUnlock() {
    unlocking = true
    mirrorView.computer = false
    updateTitle()
  }

  private func stopWaitingForUnlock() {
    guard unlocking else { return }
    unlocking = false
    mirrorView.computer = computer
    updateTitle()
  }

  /// While the phone's own screen is in this window, a locked phone can be opened from here.
  private func watchLock() {
    lockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkLock() }
    }
  }

  private func checkLock() {
    guard !ownsDisplay, session != nil, !unlockModel.working, !checkingLock, !openingPINScreen
    else {
      if ownsDisplay {
        phoneLocked = false
        showUnlockCard(false)
      }
      return
    }
    checkingLock = true
    let transport = phone.transport
    DispatchQueue.global().async { [weak self] in
      let state = PhoneUnlock.state(transport)
      DispatchQueue.main.async {
        guard let self else { return }
        self.checkingLock = false
        guard !self.ownsDisplay, !self.unlockModel.working, !self.openingPINScreen else { return }
        self.lockChanged(locked: state.locked, pinScreen: state.pinScreen)
      }
    }
  }

  private func lockChanged(locked: Bool, pinScreen: Bool) {
    phoneLocked = locked
    guard locked else {
      touchIDAsked = false
      pinScreenOpened = false
      showUnlockCard(false)
      if unlocking {
        stopWaitingForUnlock()
        startSession()
      }
      return
    }
    guard window?.isKeyWindow == true else { return }
    if pinScreen {
      // The PIN screen is up: the box, and Touch ID with it, go over it.
      showUnlockCard(true)
      if !touchIDAsked, PhonePIN.isSaved(phone.id) {
        touchIDAsked = true
        unlockWithTouchID()
      }
    } else if !pinScreenOpened {
      pinScreenOpened = true
      openPINScreen()
    } else if unlockModel.pin.isEmpty, unlockModel.problem == nil {
      showUnlockCard(false)  // the PIN screen timed out or was closed
    }
  }

  /// Takes the lock screen to its PIN screen, the way a key on a keyboard does.
  private func openPINScreen() {
    openingPINScreen = true
    let transport = phone.transport
    DispatchQueue.global().async { [weak self] in
      let ready = PhoneUnlock.openPINScreen(transport)
      DispatchQueue.main.async {
        guard let self else { return }
        self.openingPINScreen = false
        if ready, !self.ownsDisplay { self.lockChanged(locked: true, pinScreen: true) }
      }
    }
  }

  /// A locked phone takes its PIN straight from the keyboard: type it, then press Return.
  private func lockedKey(_ event: NSEvent) -> Bool {
    guard phoneLocked, !ownsDisplay, !unlockModel.working,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    else { return false }
    let model = unlockModel
    let shown = !unlockCard.isHidden
    switch event.keyCode {
    case 36, 76:  // Return, Enter
      guard shown else { return false }
      submitPIN()
      return true
    case 51:  // Delete
      guard shown else { return false }
      if !model.pin.isEmpty { model.pin.removeLast() }
      return true
    case 53:  // Esc closes the PIN screen too
      guard shown else { return false }
      showUnlockCard(false)
      session?.input.tap(4)  // Back
      return true
    default:
      guard let typed = event.characters, typed.count == 1, let character = typed.first,
        character.isASCII, !character.isWhitespace, !character.isNewline,
        character.asciiValue.map({ $0 >= 32 && $0 < 127 }) == true, model.pin.count < 16
      else { return false }
      model.problem = nil
      model.pin.append(character)
      showUnlockCard(true)
      return true
    }
  }

  private func submitPIN() {
    guard !unlockModel.pin.isEmpty, !unlockModel.working else { return }
    unlock(with: unlockModel.pin, saved: false)
  }

  private func showUnlockCard(_ show: Bool) {
    guard unlockCard.isHidden == show else { return }
    unlockCard.isHidden = !show
    if show {
      unlockModel.saved = PhonePIN.isSaved(phone.id)
      unlockModel.name = phone.name
      window?.makeFirstResponder(mirrorView)
    } else {
      unlockModel.pin = ""
      unlockModel.problem = nil
    }
  }

  private func unlockWithTouchID() {
    let id = phone.id
    let reason = String(localized: "unlock \(phone.name)")
    unlockModel.working = true
    DispatchQueue.global().async { [weak self] in
      let pin = PhonePIN.read(id, reason: reason)
      DispatchQueue.main.async {
        guard let self else { return }
        self.unlockModel.working = false
        self.unlockModel.saved = PhonePIN.isSaved(id)
        if let pin { self.unlock(with: pin, saved: true) }
      }
    }
  }

  /// Opens the phone's PIN screen, types the PIN there and checks that the phone opened.
  private func unlock(with pin: String, saved: Bool) {
    guard let session else { return }
    let model = unlockModel
    setSubmittingPIN(true)
    model.problem = nil
    model.pin = String(repeating: "•", count: pin.count)
    showUnlockCard(true)
    let transport = phone.transport
    let id = phone.id
    DispatchQueue.global().async { [weak self] in
      let ready = PhoneUnlock.openPINScreen(transport, wakeBeforeChecking: true)
      DispatchQueue.main.async {
        guard let self else { return }
        guard ready, self.session === session else {
          self.setSubmittingPIN(false)
          model.pin = ""
          model.problem = String(localized: "Couldn't open the phone's PIN screen.")
          return
        }
        session.input.text(pin)
        session.input.tap(66)  // Enter
        PhoneUnlock.confirmUnlock(transport) { [weak self] opened in
          guard let self else { return }
          self.setSubmittingPIN(false)
          model.pin = ""
          guard self.session === session else { return }
          if opened == true {
            self.phoneLocked = false
            self.touchIDAsked = false
            self.showUnlockCard(false)
            self.checkLock()
            if !saved { self.offerTouchID(for: pin) }
          } else if opened == false {
            if saved { PhonePIN.delete(id) }
            model.saved = PhonePIN.isSaved(id)
            model.wrong += 1
            NSAccessibility.post(
              element: self.unlockCard, notification: .announcementRequested,
              userInfo: [.announcement: String(localized: "Wrong PIN")])
          }
        }
      }
    }
  }

  private func setSubmittingPIN(_ active: Bool) {
    submittingPIN = active
    unlockModel.working = active
    if phoneScreenOff { session?.input.setScreenPower(on: active) }
  }

  /// Phones already offered Touch ID since the app opened.
  private static var touchIDOffered: Set<String> = []

  /// After a PIN typed by hand opens the phone, offers to keep it for Touch ID.
  private func offerTouchID(for pin: String) {
    let id = phone.id
    guard let window, PhonePIN.canUseTouchID, !PhonePIN.isSaved(id),
      Self.touchIDOffered.insert(id).inserted
    else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Use Touch ID to unlock “\(phone.name)”?")
    alert.informativeText = String(
      localized: "Your PIN stays in this Mac’s keychain and only opens with your fingerprint.")
    alert.addButton(withTitle: String(localized: "Use Touch ID"))
    alert.addButton(withTitle: String(localized: "Not Now"))
    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn else { return }
      PhonePIN.save(pin, for: id)
    }
  }

  func resume(with phone: Phone) {
    self.phone = phone
    phonePresent = true
    updateTitle()
    if session == nil {
      retries = 0
      startSession()
    }
  }

  func phoneWentAway() {
    phonePresent = false
    showOverlay(String(localized: "Waiting for \(phone.name)…"), busy: true)
  }

  func sessionInputBlocked(_ session: MirrorSession) {
    guard session === self.session else { return }
    notice.rootView = InputBlockedNotice(maker: phone.maker) { [weak self] in
      self?.notice.isHidden = true
    }
    notice.isHidden = false
  }

  func sessionDidStart(_ session: MirrorSession, deviceName: String) {
    guard session === self.session else { return }
    retries = 0
    // The phone window, on the phone's screen or its desktop, owns the screen switch.
    guard phoneScreenOff, app == nil, !submittingPIN else { return }
    session.input.setScreenPower(on: false)
    // A session that just ended lights the screen again as it cleans up; turn it off after it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self, session === self.session, self.phoneScreenOff, !self.submittingPIN else {
        return
      }
      session.input.setScreenPower(on: false)
    }
  }

  func session(_ session: MirrorSession, videoSizeChanged size: CGSize) {
    guard session === self.session, size.width > 0, size.height > 0 else { return }
    hideOverlay()
    let rotated =
      videoSize != .zero && (videoSize.width > videoSize.height) != (size.width > size.height)
    let first = videoSize == .zero
    videoSize = size
    mirrorView.videoSize = size
    keyMapper.videoSize = size
    // An app's or a desktop's display follows its window, not the other way round.
    if !ownsDisplay, !unlocking { fit(to: size, resize: first || rotated) }
  }

  func sessionDidEnd(_ session: MirrorSession, error: String?) {
    guard session === self.session else { return }
    self.session = nil
    mirrorView.control = nil
    guard window?.isVisible == true else { return }
    if phonePresent, retries < 3 {
      retries += 1
      showOverlay(String(localized: "Reconnecting…"), busy: true)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let self, self.session == nil, self.phonePresent else { return }
        self.startSession()
      }
    } else {
      showOverlay(String(localized: "Waiting for \(phone.name)…"), busy: true)
    }
  }

  // MARK: - Window

  private func updateTitle() {
    if let start = recordingStart {
      let seconds = Int(Date().timeIntervalSince(start))
      let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
      window?.title = app?.label ?? phone.name
      window?.subtitle = String(localized: "Recording \(time)")
      return
    }
    if let app {
      window?.title = app.label
      window?.subtitle = phone.name
      return
    }
    window?.title = phone.name
    window?.subtitle =
      unlocking
      ? String(localized: "Unlock the phone to open its desktop")
      : phone.isUSB ? String(localized: "USB") : String(localized: "Wi-Fi")
  }

  /// An app's display in pixels: the window's size, so one Mac point is one Android dp.
  private var displaySize: CGSize {
    let points = window?.contentView?.bounds.size ?? CGSize(width: 400, height: 760)
    let scale = window?.backingScaleFactor ?? 2
    return CGSize(
      width: (points.width * scale).rounded(), height: (points.height * scale).rounded())
  }

  private var dpi: Int { Int(160 * (window?.backingScaleFactor ?? 2)) }

  // While recording, the display keeps its size: one recording has one size.
  func windowDidEndLiveResize(_ notification: Notification) {
    if ownsDisplay, !isRecording { session?.input.resizeDisplay(displaySize) }
  }

  func windowDidResize(_ notification: Notification) {
    guard ownsDisplay, !isRecording, window?.inLiveResize == false else { return }
    session?.input.resizeDisplay(displaySize)
  }

  private func fit(to size: CGSize, resize: Bool) {
    guard let window, let screen = window.screen ?? NSScreen.main else { return }
    window.contentAspectRatio = size
    guard resize, !window.styleMask.contains(.fullScreen) else { return }
    let visible = screen.visibleFrame
    var height = min(visible.height * 0.86, size.height / (screen.backingScaleFactor))
    if size.width > size.height { height = min(visible.height * 0.7, height) }
    var width = height * size.width / size.height
    if width > visible.width * 0.9 {
      width = visible.width * 0.9
      height = width * size.height / size.width
    }
    let content = NSRect(x: 0, y: 0, width: width, height: height)
    var frame = window.frameRect(forContentRect: content)
    let old = window.frame
    frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.maxY - frame.height)
    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
    window.setFrame(frame, display: true, animate: !resize || videoSize != size)
  }

  private func showOverlay(_ text: String, busy: Bool) {
    overlay.rootView = MirrorOverlay(text: text, busy: busy)
    overlay.isHidden = false
  }

  private func hideOverlay() {
    overlay.isHidden = true
  }

  func windowWillClose(_ notification: Notification) {
    lockTimer?.invalidate()
    session?.delegate = nil
    session?.stop()
    session = nil
    onClose?()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    if mirrorView.keyMapView.editing {
      window?.makeFirstResponder(mirrorView.keyMapView)
    } else {
      window?.makeFirstResponder(mirrorView)
    }
    // The phone's own screen shows whichever app is in front, so follow it while keys are saved.
    guard app == nil, !computer else { return }
    followForegroundApp()
    foregroundTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.followForegroundApp() }
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    keyMapper.releaseAll()
    foregroundTimer?.invalidate()
    foregroundTimer = nil
  }

  // MARK: - Key mapping

  private func useKeys(of package: String?) {
    mapPackage = package
    let map = package.flatMap(KeyMap.load) ?? KeyMap()
    keyMapper.releaseAll()
    keyMapper.map = map
    mirrorView.keyMapView.map = map
  }

  private func followForegroundApp(then done: (() -> Void)? = nil) {
    guard app == nil, !computer, KeyMap.anySaved || done != nil, !mirrorView.keyMapView.editing
    else {
      done?()
      return
    }
    let transport = phone.transport
    DispatchQueue.global().async {
      let package = Self.foregroundPackage(transport)
      DispatchQueue.main.async {
        if package != self.mapPackage { self.useKeys(of: package) }
        done?()
      }
    }
  }

  /// The app in front on the phone's own screen.
  nonisolated private static func foregroundPackage(_ transport: String) -> String? {
    let output = ADB.shell(
      transport, "dumpsys activity activities | grep -E '^Display #|ResumedActivity:'")
    var onPhoneScreen = false
    for line in output.split(separator: "\n") {
      if line.hasPrefix("Display #") {
        onPhoneScreen = line.hasPrefix("Display #0 ")
      } else if onPhoneScreen,
        let record = line.split(separator: " ").first(where: { $0.contains("/") })
      {
        return String(record.split(separator: "/")[0])
      }
    }
    return nil
  }

  var isEditingKeys: Bool { mirrorView.keyMapView.editing }

  /// Shows the keys over the phone so they can be placed, moved and removed.
  func editKeyMap() {
    if isEditingKeys { return finishEditingKeys() }
    guard session != nil, videoSize != .zero else { return }
    followForegroundApp { [weak self] in
      guard let self else { return }
      guard self.mapPackage != nil else {
        self.files.note("exclamationmark.circle.fill", String(localized: "Open a game first"))
        return
      }
      self.keyMapper.releaseAll()
      self.mirrorView.keyMapView.editing = true
      self.updateKeyMapBar(self.mirrorView.keyMapView.map)
      self.keyMapBar.isHidden = false
      self.window?.makeFirstResponder(self.mirrorView.keyMapView)
    }
  }

  private func updateKeyMapBar(_ map: KeyMap) {
    let view = mirrorView.keyMapView
    keyMapBar.rootView = AnyView(
      KeyMapBar(
        map: map,
        setJoystick: { [weak self] on in
          view.map.joystick = on ? KeyMap.Joystick(x: 0.2, y: 0.72, radius: 0.12) : nil
          self?.updateKeyMapBar(view.map)
        },
        setEnabled: { [weak self] on in
          view.map.enabled = on
          self?.updateKeyMapBar(view.map)
        },
        clear: { [weak self] in
          view.map.taps = []
          view.map.joystick = nil
          self?.updateKeyMapBar(view.map)
        },
        done: { [weak self] in self?.finishEditingKeys() }))
  }

  private func finishEditingKeys() {
    let map = mirrorView.keyMapView.finish()
    if let mapPackage { map.save(mapPackage) }
    keyMapper.map = map
    mirrorView.keyMapView.map = map
    mirrorView.keyMapView.editing = false
    keyMapBar.isHidden = true
    window?.makeFirstResponder(mirrorView)
  }

  // MARK: - Files

  /// Files dropped on the window go to the phone's Download folder.
  private func send(_ urls: [URL]) {
    guard let input = session?.input else { return }
    files.send(urls, transport: phone.transport) { input.scanFile($0) }
  }

  /// A pasted image is saved as a PNG and sent like a dropped file.
  private func send(_ image: NSImage) {
    guard let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let url = folder.appendingPathComponent(
      Capture.fileName(String(localized: "Pasted Image"), ext: "png"))
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try png.write(to: url)
    } catch { return }
    send([url])
  }

  // MARK: - Screenshots and recordings

  /// Saves to the Desktop and copies to the clipboard, like the Mac's own screenshots.
  func takeScreenshot() {
    let url = Capture.desktop.appendingPathComponent(
      Capture.fileName(app?.label ?? phone.name, ext: "png"))
    let frame = session?.currentFrame.flatMap {
      NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
    }
    guard !ownsDisplay else { return saveScreenshot(frame, to: url) }
    // The phone's own capture is sharper than the stream over Wi-Fi.
    let transport = phone.transport
    DispatchQueue.global().async {
      let data = ADB.data(["-s", transport, "exec-out", "screencap -p"], timeout: 20)
      DispatchQueue.main.async { self.saveScreenshot(data ?? frame, to: url) }
    }
  }

  private func saveScreenshot(_ data: Data?, to url: URL) {
    guard let data, NSImage(data: data) != nil, (try? data.write(to: url)) != nil else {
      files.note("exclamationmark.circle.fill", String(localized: "Couldn't take a screenshot"))
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setData(data, forType: .png)
    Capture.play("Screen Capture.aif")
    files.note("camera.fill", String(localized: "Saved to Desktop and copied"))
  }

  var isRecording: Bool { recordingStart != nil }
  private var recordingStart: Date?
  private var recordingTimer: Timer?

  /// Records the window with the phone's sound to an .mp4 in Movies.
  func toggleRecording() {
    guard let session else { return }
    if session.isRecording { return session.stopRecording() }
    let url = Capture.movies.appendingPathComponent(
      Capture.fileName(app?.label ?? phone.name, ext: "mp4"))
    do {
      try session.startRecording(to: url)
    } catch {
      files.note("exclamationmark.circle.fill", String(localized: "Couldn't start recording"))
      return
    }
    recordingStart = Date()
    MirrorManager.shared.sessionsChanged()
    Capture.play("begin_record.caf")
    buttons.update(recording: true)
    updateTitle()
    recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateTitle() }
    }
  }

  func session(_ session: MirrorSession, recordingFinished url: URL?) {
    recordingStart = nil
    MirrorManager.shared.sessionsChanged()
    recordingTimer?.invalidate()
    recordingTimer = nil
    buttons.update(recording: false)
    updateTitle()
    Capture.play("end_record.caf")
    if url != nil {
      files.note("film.fill", String(localized: "Saved to Movies"))
    } else {
      files.note("exclamationmark.circle.fill", String(localized: "Nothing was recorded"))
    }
  }

  // MARK: - Commands

  func back() { session?.input.backOrScreenOn() }
  func home() { session?.input.tap(ControlChannel.Key.home) }
  func recents() { session?.input.tap(ControlChannel.Key.appSwitch) }
  func volumeUp() { session?.input.tap(ControlChannel.Key.volumeUp) }
  func volumeDown() { session?.input.tap(ControlChannel.Key.volumeDown) }
  func rotate() { session?.input.rotate() }
  func notifications() { session?.input.expandNotifications() }

  func togglePhoneScreen() {
    // An app window passes it on: the phone window keeps the screen dark and shows the sun.
    if app != nil { return MirrorManager.shared.phoneWindow(of: phone)?.togglePhoneScreen() ?? () }
    phoneScreenOff.toggle()
    session?.input.setScreenPower(on: submittingPIN || !phoneScreenOff)
    buttons.update(screenOn: !phoneScreenOff)
  }

  var isPhoneScreenOn: Bool { !phoneScreenOff }

  func toggleComputer() { MirrorManager.shared.toggleComputer(phone) }
}

// MARK: - Title bar buttons

/// Back, Home, Recent Apps and the phone screen switch, sitting at the right of the title bar.
@MainActor
private final class PhoneButtons: NSTitlebarAccessoryViewController {
  private weak var controller: MirrorWindowController?
  private let screen = TitlebarButton()
  private let stop = TitlebarButton()
  private let mode = TitlebarButton()
  private var width: NSLayoutConstraint?
  private var baseWidth: CGFloat = 118

  init(controller: MirrorWindowController) {
    self.controller = controller
    super.init(nibName: nil, bundle: nil)
    layoutAttribute = .trailing
  }

  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    let back = TitlebarButton(
      symbol: "chevron.backward", tip: String(localized: "Back"), action: #selector(backAction))
    let home = TitlebarButton(
      symbol: "app.grid.3x3", fallback: "circle.grid.3x3", tip: String(localized: "Home"),
      action: #selector(homeAction))
    let recents = TitlebarButton(
      symbol: "iphone.app.switcher", tip: String(localized: "Recent Apps"),
      action: #selector(recentsAction))
    screen.action = #selector(screenAction)
    // An app window only needs Back: Home and Recent Apps belong to the phone's own screen.
    let isApp = controller?.app != nil
    stop.image = TitlebarButton.symbol("stop.circle.fill", size: 14, weight: .regular)
    stop.contentTintColor = .systemRed
    stop.toolTip = String(localized: "Stop Recording")
    stop.action = #selector(stopAction)
    stop.isHidden = true
    mode.action = #selector(modeAction)
    let stack = NSStackView(
      views: isApp ? [stop, back] : [stop, mode, back, home, recents, screen])
    stack.spacing = 3
    stack.distribution = .fillEqually
    stack.translatesAutoresizingMaskIntoConstraints = false
    for button in stack.arrangedSubviews { (button as? NSButton)?.target = self }
    // The same metrics as the buttons this replaces: 118 × 24 for four, 6 pt from the edge.
    baseWidth = isApp ? 32 : 147
    let container = NSView(frame: NSRect(x: 0, y: 0, width: baseWidth, height: 24))
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
      container.heightAnchor.constraint(equalToConstant: 24),
    ])
    let width = container.widthAnchor.constraint(equalToConstant: baseWidth)
    width.isActive = true
    self.width = width
    view = container
    update(screenOn: controller?.isPhoneScreenOn ?? false)
    update(computer: controller?.computer ?? false)
  }

  /// Shows the other mode: a computer on the phone's screen, a phone on the desktop.
  func update(computer: Bool) {
    mode.image = TitlebarButton.symbol(
      computer ? "iphone" : "laptopcomputer", size: computer ? 13 : 14, weight: .regular)
    mode.toolTip = computer ? String(localized: "Phone Mode") : String(localized: "Computer Mode")
  }

  /// A filled orange sun while the phone's screen is lit, a quiet outline while it is dark.
  func update(screenOn: Bool) {
    screen.image = TitlebarButton.symbol(
      screenOn ? "sun.max.fill" : "sun.max", size: screenOn ? 14 : 13,
      weight: screenOn ? .bold : .regular)
    screen.contentTintColor = screenOn ? .systemOrange : .secondaryLabelColor
    screen.toolTip =
      screenOn
      ? String(localized: "Turn the phone's screen off")
      : String(localized: "Turn the phone's screen on")
  }

  /// A red stop button joins the others while the window is being recorded.
  func update(recording: Bool) {
    stop.isHidden = !recording
    let total = baseWidth + (recording ? 29 : 0)
    width?.constant = total
    view.setFrameSize(NSSize(width: total, height: 24))
  }

  @objc private func stopAction() { controller?.toggleRecording() }
  @objc private func backAction() { controller?.back() }
  @objc private func homeAction() { controller?.home() }
  @objc private func recentsAction() { controller?.recents() }
  @objc private func screenAction() { controller?.togglePhoneScreen() }
  @objc private func modeAction() { controller?.toggleComputer() }
}

private final class TitlebarButton: NSButton {
  private var tracking: NSTrackingArea?

  convenience init(symbol: String, fallback: String? = nil, tip: String, action: Selector) {
    self.init()
    image =
      Self.symbol(symbol, size: 13, weight: .medium)
      ?? fallback.flatMap { Self.symbol($0, size: 13, weight: .medium) }
    toolTip = tip
    self.action = action
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    isBordered = false
    imagePosition = .imageOnly
    contentTintColor = .labelColor
    wantsLayer = true
    layer?.cornerRadius = 5
    translatesAutoresizingMaskIntoConstraints = false
  }

  required init?(coder: NSCoder) { fatalError() }

  // A press in the title bar must click the button, not drag the window.
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
  }

  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = nil
  }

  override func mouseDown(with event: NSEvent) {
    layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
    super.mouseDown(with: event)
    let inside = bounds.contains(
      convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    layer?.backgroundColor = inside ? NSColor.quaternaryLabelColor.cgColor : nil
  }

  /// SF Symbols, including the system's own private ones such as app.grid.3x3.
  static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
      return image.withSymbolConfiguration(config)
    }
    let selector = NSSelectorFromString(
      "imageWithPrivateSystemSymbolName:accessibilityDescription:")
    guard NSImage.responds(to: selector) else { return nil }
    typealias Lookup = @convention(c) (AnyObject, Selector, NSString, NSString?) -> NSImage?
    let lookup = unsafeBitCast(NSImage.method(for: selector), to: Lookup.self)
    return lookup(NSImage.self, selector, name as NSString, nil)?.withSymbolConfiguration(config)
  }
}

/// Shown when the phone refuses touch from the computer, with the switch its maker hides it behind.
private struct InputBlockedNotice: View {
  var maker: String
  var close: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "hand.raised.fill")
        .foregroundStyle(.orange)
        .font(.system(size: 15))
      VStack(alignment: .leading, spacing: 3) {
        Text("This phone blocks touch from your Mac")
          .font(.system(size: 12, weight: .semibold))
        Text(advice)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      Button(action: close) {
        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .environment(\.colorScheme, .dark)
  }

  private var advice: String {
    switch maker.lowercased() {
    case "xiaomi", "redmi", "poco":
      return String(
        localized:
          "In Developer options, turn on USB debugging (Security settings), then restart the phone."
      )
    case "oppo", "oneplus", "realme":
      return String(localized: "In Developer options, turn on Disable permission monitoring.")
    default:
      return String(localized: "In Developer options, allow input from USB debugging.")
    }
  }
}

private struct MirrorOverlay: View {
  var text: String
  var busy: Bool

  var body: some View {
    VStack(spacing: 12) {
      if busy { ProgressView().controlSize(.small) }
      Text(verbatim: text)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .environment(\.colorScheme, .dark)
  }
}

// MARK: - The view that shows the phone and takes input

final class MirrorView: NSView, NSTextInputClient {
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
  var control: ControlChannel?
  var videoSize = CGSize.zero {
    didSet { needsLayout = true }
  }
  /// On a desktop the pointer is a mouse: it hovers, right-clicks and scrolls with a wheel.
  var computer = false

  private var marked = NSMutableAttributedString()
  private var scrollFinger: CGPoint?
  private var pinch: (center: CGPoint, distance: CGFloat)?
  private var heldKeys: [UInt16: Int32] = [:]
  var onDropFiles: (([URL]) -> Void)?
  var onDragging: ((Bool) -> Void)?
  var onPasteImage: ((NSImage) -> Void)?
  /// Keys for the app itself while the phone is locked, such as its PIN.
  var onLockedKey: ((NSEvent) -> Bool)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    registerForDraggedTypes([.fileURL])
    addSubview(keyMapView)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func makeBackingLayer() -> CALayer {
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = NSColor.black.cgColor
    return layer
  }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // MARK: Files dropped from Finder

  private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
    info.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard control != nil, !fileURLs(sender).isEmpty else { return [] }
    onDragging?(true)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) { onDragging?(false) }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    onDragging?(false)
    let urls = fileURLs(sender)
    guard !urls.isEmpty else { return false }
    onDropFiles?(urls)
    return true
  }

  // MARK: Coordinates

  var keyMapper: KeyMapper?
  let keyMapView = KeyMapView()

  override func layout() {
    super.layout()
    keyMapView.frame = bounds
    keyMapView.videoRect = videoRect
  }

  var videoRect: CGRect {
    guard videoSize.width > 0, bounds.width > 0 else { return bounds }
    let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
    let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    return CGRect(
      x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
      width: size.width, height: size.height)
  }

  private func phonePoint(_ event: NSEvent) -> CGPoint {
    phonePoint(convert(event.locationInWindow, from: nil))
  }

  private func phonePoint(_ point: CGPoint) -> CGPoint {
    let rect = videoRect
    let x = (point.x - rect.minX) / rect.width * videoSize.width
    let y = (point.y - rect.minY) / rect.height * videoSize.height
    return CGPoint(
      x: min(max(x, 0), videoSize.width - 1), y: min(max(y, 0), videoSize.height - 1))
  }

  /// View points to phone pixels.
  private var pixelsPerPoint: CGFloat {
    let rect = videoRect
    return rect.width > 0 ? videoSize.width / rect.width : 1
  }

  // MARK: Mouse: the pointer is a finger, or on a desktop a mouse

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    press(.down, event, button: ControlChannel.Button.primary)
  }

  override func mouseDragged(with event: NSEvent) {
    press(.move, event, button: ControlChannel.Button.primary)
  }

  override func mouseUp(with event: NSEvent) {
    press(.up, event, button: ControlChannel.Button.primary)
  }

  override func mouseMoved(with event: NSEvent) {
    guard computer, videoRect.contains(convert(event.locationInWindow, from: nil)) else { return }
    control?.touch(.hover, pointer: ControlChannel.Pointer.cursor, at: phonePoint(event))
  }

  override func rightMouseDown(with event: NSEvent) {
    guard computer else { return control?.backOrScreenOn() ?? () }
    window?.makeFirstResponder(self)
    press(.down, event, button: ControlChannel.Button.secondary)
  }

  override func rightMouseDragged(with event: NSEvent) {
    if computer { press(.move, event, button: ControlChannel.Button.secondary) }
  }

  override func rightMouseUp(with event: NSEvent) {
    if computer { press(.up, event, button: ControlChannel.Button.secondary) }
  }

  private func press(_ action: ControlChannel.Action, _ event: NSEvent, button: Int32) {
    guard computer else {
      control?.touch(action, pointer: ControlChannel.Pointer.mouse, at: phonePoint(event))
      return
    }
    control?.touch(
      action, pointer: ControlChannel.Pointer.cursor, at: phonePoint(event),
      button: action == .move ? 0 : button, buttons: action == .up ? 0 : button)
  }

  override func otherMouseDown(with event: NSEvent) {
    control?.tap(ControlChannel.Key.home)
  }

  // MARK: Trackpad: two-finger scrolling drags a finger, so the phone flings natively

  override func scrollWheel(with event: NSEvent) {
    guard let control else { return }
    if computer, event.hasPreciseScrollingDeltas {
      // A desktop scrolls what is under the pointer, as a wheel does; one wheel step is 64 dp.
      control.scroll(
        at: phonePoint(event), horizontal: -event.scrollingDeltaX / 64,
        vertical: event.scrollingDeltaY / 64)
      return
    }
    guard event.hasPreciseScrollingDeltas, event.phase != [] || event.momentumPhase != [] else {
      // A mouse wheel: real scroll steps.
      control.scroll(
        at: phonePoint(event), horizontal: -event.scrollingDeltaX, vertical: event.scrollingDeltaY)
      return
    }
    if event.momentumPhase != [] { return }  // the phone does its own momentum
    let scale = pixelsPerPoint
    switch event.phase {
    case .began, .mayBegin:
      let start = phonePoint(event)
      scrollFinger = start
      control.touch(.down, pointer: ControlChannel.Pointer.scroll, at: start)
    case .changed:
      guard var finger = scrollFinger else { return }
      finger.x += event.scrollingDeltaX * scale
      finger.y += event.scrollingDeltaY * scale
      finger.x = min(max(finger.x, 0), videoSize.width - 1)
      finger.y = min(max(finger.y, 0), videoSize.height - 1)
      scrollFinger = finger
      control.touch(.move, pointer: ControlChannel.Pointer.scroll, at: finger)
    case .ended, .cancelled:
      if let finger = scrollFinger {
        control.touch(.up, pointer: ControlChannel.Pointer.scroll, at: finger)
      }
      scrollFinger = nil
    default:
      break
    }
  }

  // MARK: Trackpad: pinch is two fingers

  override func magnify(with event: NSEvent) {
    guard let control else { return }
    switch event.phase {
    case .began:
      let center = phonePoint(event)
      pinch = (center, 120)
      for (pointer, point) in pinchPoints(center: center, distance: 120) {
        control.touch(.down, pointer: pointer, at: point)
      }
    case .changed:
      guard var current = pinch else { return }
      current.distance = min(max(current.distance * (1 + event.magnification), 20), 2000)
      pinch = current
      for (pointer, point) in pinchPoints(center: current.center, distance: current.distance) {
        control.touch(.move, pointer: pointer, at: point)
      }
    case .ended, .cancelled:
      if let current = pinch {
        for (pointer, point) in pinchPoints(center: current.center, distance: current.distance) {
          control.touch(.up, pointer: pointer, at: point)
        }
      }
      pinch = nil
    default:
      break
    }
  }

  private func pinchPoints(center: CGPoint, distance: CGFloat) -> [(Int64, CGPoint)] {
    let half = distance / 2
    func clamp(_ p: CGPoint) -> CGPoint {
      CGPoint(x: min(max(p.x, 0), videoSize.width - 1), y: min(max(p.y, 0), videoSize.height - 1))
    }
    return [
      (ControlChannel.Pointer.pinchA, clamp(CGPoint(x: center.x - half, y: center.y - half))),
      (ControlChannel.Pointer.pinchB, clamp(CGPoint(x: center.x + half, y: center.y + half))),
    ]
  }

  // MARK: Keyboard

  /// Mac key codes with an Android key of their own.
  private static let keys: [UInt16: Int32] = [
    36: 66, 76: 66,  // return, enter
    48: 61,  // tab
    51: 67,  // delete
    117: 112,  // forward delete
    53: 4,  // escape works as Back, as on Android keyboards
    123: 21, 124: 22, 125: 20, 126: 19,  // arrows
    115: 122, 119: 123, 116: 92, 121: 93,  // home, end, page up, page down
  ]

  /// Mac key codes of letters, for Control shortcuts such as Control-C in a terminal app.
  private static let letters: [UInt16: Int32] = [
    0: 29, 11: 30, 8: 31, 2: 32, 14: 33, 3: 34, 5: 35, 4: 36, 34: 37, 38: 38, 40: 39, 37: 40,
    46: 41, 45: 42, 31: 43, 35: 44, 12: 45, 15: 46, 1: 47, 17: 48, 32: 49, 9: 50, 13: 51,
    7: 52, 16: 53, 6: 54,
  ]

  /// Mac text editing keys, as the phone knows them.
  private func macEditingKey(_ event: NSEvent, _ flags: NSEvent.ModifierFlags) -> Bool {
    guard let control else { return false }
    let shift = flags.contains(.shift) ? ControlChannel.Meta.shift : 0
    let ctrl = ControlChannel.Meta.ctrl
    func press(_ code: Int32, _ meta: Int32) {
      control.key(code, .down, meta: meta)
      control.key(code, .up, meta: meta)
    }
    if flags.contains(.command) {
      switch event.keyCode {
      case 123: press(122, shift)  // ⌘← to the start of the line
      case 124: press(123, shift)  // ⌘→ to the end
      case 51:  // ⌘⌫ deletes to the start of the line
        press(122, ControlChannel.Meta.shift)
        press(67, 0)
      default: return false
      }
      return true
    }
    if flags.contains(.option) {
      switch event.keyCode {
      case 123: press(21, ctrl | shift)  // ⌥← a word back
      case 124: press(22, ctrl | shift)  // ⌥→ a word on
      case 51: press(67, ctrl)  // ⌥⌫ deletes a word
      case 117: press(112, ctrl)  // ⌥⌦ deletes the next word
      default: return false
      }
      return true
    }
    return false
  }

  override func keyDown(with event: NSEvent) {
    if onLockedKey?(event) == true { return }
    guard let control else { return }
    if keyMapper?.keyDown(event) == true { return }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if !hasMarkedText(), macEditingKey(event, flags) { return }
    if flags.contains(.command) {
      super.keyDown(with: event)
      return
    }
    if flags.contains(.control), let letter = Self.letters[event.keyCode] {
      control.key(letter, .down, meta: ControlChannel.Meta.ctrl)
      control.key(letter, .up, meta: ControlChannel.Meta.ctrl)
      return
    }
    if !hasMarkedText(), let code = Self.keys[event.keyCode] {
      var meta: Int32 = 0
      if flags.contains(.shift) { meta |= ControlChannel.Meta.shift }
      if flags.contains(.option) { meta |= ControlChannel.Meta.alt }
      heldKeys[event.keyCode] = code
      control.key(code, .down, repeat: event.isARepeat ? 1 : 0, meta: meta)
      return
    }
    interpretKeyEvents([event])
  }

  override func keyUp(with event: NSEvent) {
    if keyMapper?.keyUp(event) == true { return }
    if let code = heldKeys.removeValue(forKey: event.keyCode) {
      control?.key(code, .up)
    }
  }

  // Edit menu: the Mac clipboard and the phone's stay in step.
  @objc func paste(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    if let text = pasteboard.string(forType: .string) {
      control?.setClipboard(text, paste: true)
    } else if let image = NSImage(pasteboard: pasteboard) {
      // The phone's clipboard only takes text from here, so an image goes to its photos instead.
      onPasteImage?(image)
    }
  }

  @objc func copy(_ sender: Any?) { control?.copyFromPhone(cut: false) }
  @objc func cut(_ sender: Any?) { control?.copyFromPhone(cut: true) }

  @objc override func selectAll(_ sender: Any?) {
    control?.key(29, .down, meta: ControlChannel.Meta.ctrl)
    control?.key(29, .up, meta: ControlChannel.Meta.ctrl)
  }

  @objc func undo(_ sender: Any?) {
    control?.key(54, .down, meta: ControlChannel.Meta.ctrl)
    control?.key(54, .up, meta: ControlChannel.Meta.ctrl)
  }

  @objc func redo(_ sender: Any?) {
    let meta = ControlChannel.Meta.ctrl | ControlChannel.Meta.shift
    control?.key(54, .down, meta: meta)
    control?.key(54, .up, meta: meta)
  }

  // MARK: Text input (so Chinese, Japanese and other input methods work)

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    marked = NSMutableAttributedString()
    control?.type(text)
  }

  override func doCommand(by selector: Selector) {
    switch selector {
    case #selector(insertNewline(_:)): control?.tap(66)
    case #selector(deleteBackward(_:)): control?.tap(67)
    case #selector(insertTab(_:)): control?.tap(61)
    default: break
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if let attributed = string as? NSAttributedString {
      marked = NSMutableAttributedString(attributedString: attributed)
    } else {
      marked = NSMutableAttributedString(string: string as? String ?? "")
    }
  }

  func unmarkText() { marked = NSMutableAttributedString() }
  func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
  func markedRange() -> NSRange {
    marked.length > 0
      ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
  }
  func hasMarkedText() -> Bool { marked.length > 0 }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    // Put the input method's candidates near the bottom of the phone, where its keyboard would be.
    let rect = videoRect
    let local = NSRect(x: rect.minX + 20, y: rect.maxY - 60, width: 1, height: 20)
    guard let window else { return .zero }
    return window.convertToScreen(convert(local, to: nil))
  }
}
