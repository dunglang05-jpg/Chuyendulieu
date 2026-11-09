// Phone Transfer Pro — iOS platform adapter. NOT YET BUILT OR DEVICE-TESTED (see docs/STATUS.md).
// Uses only public APIs: Photos, Contacts, UIDocumentPicker, FileManager. Never touches other apps' data.
import Contacts
import Flutter
import NetworkExtension
import Photos
import Security
import UIKit
import UniformTypeIdentifiers

public class PtpPlatformPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "ptp.platform", qos: .userInitiated, attributes: .concurrent)
  private let photos = PhotosAdapter()
  private let contacts = ContactsAdapter()
  private let files = FilesAdapter()
  private var picker: DocumentPickerCoordinator?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var joinedSsid: String?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.phonetransferpro/ptp_platform", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PtpPlatformPlugin(), channel: channel)
  }

  /// Runs work off the main thread; errors become FlutterError codes the Dart side maps to PtpErrorCode.
  private func runAsync(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any?) {
    queue.async {
      do {
        let v = try work()
        DispatchQueue.main.async { result(v) }
      } catch let e as AdapterError {
        DispatchQueue.main.async { result(FlutterError(code: e.code, message: e.message, details: nil)) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "INTERNAL_ERROR", message: String(describing: type(of: error)), details: nil)) }
      }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "probe":
      runAsync(result) { self.probe() }
    case "requestPermission":
      requestPermission(category: args["category"] as? String ?? "", forImport: args["forImport"] as? Bool ?? false, result: result)
    case "scan":
      let cat = args["category"] as? String ?? ""
      let limit = args["limit"] as? Int ?? 100_000
      runAsync(result) {
        switch cat {
        case "photos", "videos": return self.photos.scan(category: cat, limit: limit)
        case "contacts": return self.contacts.scan()
        default: return [] as [Any]  // documents/audio: only via the document picker
        }
      }
    case "pickDocuments":
      let cat = args["category"] as? String ?? "documents"
      DispatchQueue.main.async { self.presentPicker(category: cat, result: result) }
    case "openForRead":
      let id = args["id"] as? String ?? ""
      let cat = args["category"] as? String ?? ""
      runAsync(result) {
        if id == ContactsAdapter.allContactsId { return try self.files.openStaged(self.contacts.exportAll()) }
        if cat == "photos" || cat == "videos" { return try self.files.openStaged(self.photos.export(localIdentifier: id)) }
        return try self.files.openStaged(Staged(url: URL(fileURLWithPath: id), mtimeMs: nil, cleanupDir: nil))
      }
    case "closeRead":
      files.close(token: args["token"] as? String ?? "")
      result(nil)
    case "inboxDir":
      runAsync(result) { try FilesAdapter.inboxDir().path }
    case "freeBytes":
      runAsync(result) { FilesAdapter.freeBytes(at: URL(fileURLWithPath: args["path"] as? String ?? NSHomeDirectory())) }
    case "importFile":
      let url = URL(fileURLWithPath: args["path"] as? String ?? "")
      let cat = args["category"] as? String ?? ""
      let name = args["name"] as? String ?? url.lastPathComponent
      runAsync(result) {
        switch cat {
        case "photos", "videos":
          let r = self.photos.importFile(url: url, isVideo: cat == "videos", name: name)
          if r["status"] as? String == "imported" { return r }
          return try self.files.saveToFiles(url: url, category: cat, name: name, reason: r["message"] as? String)
        case "contacts":
          return try self.contacts.importVCard(url: url, files: self.files)
        default:
          return try self.files.saveToFiles(url: url, category: cat, name: name, reason: nil)
        }
      }
    case "setTransferActive":
      setTransferActive(args["active"] as? Bool ?? false)
      result(nil)
    case "deviceState":
      result(deviceState())
    case "usbStatus", "usbStart":
      // iOS exposes no USB API to third-party iPhone apps (DriverKit is iPadOS-only; ExternalAccessory needs MFi/iAP2).
      result(["supported": false, "hostSupported": false, "accessorySupported": false, "state": "failed",
              "role": NSNull(), "error": "IOS_NO_USB_API", "bridgePort": NSNull()])
    case "usbStop":
      result(nil)
    case "backgroundStatus":
      // iOS has no equivalent: transfers need the app in front (idle timer is disabled while transferring).
      result(["ignoringBatteryOptimizations": true, "manufacturer": "apple"])
    case "requestBackground":
      result("not_applicable")
    case "openBatterySettings":
      result(nil)
    // "Điểm phát": an iPhone cannot create a hotspot from an app; it can only JOIN the Android host's hotspot.
    // Needs the "Hotspot Configuration" capability in the Runner entitlements (docs/HOTSPOT.md). Without it the Dart
    // side shows the network name/password for a manual join. NOT TESTED ON DEVICES.
    case "hotspotStart":
      result(FlutterError(code: "HOTSPOT_UNSUPPORTED", message: "iOS apps cannot create a hotspot", details: nil))
    case "hotspotStop", "hotspotLeave":
      if let ssid = joinedSsid {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        joinedSsid = nil
      }
      result(nil)
    case "hotspotJoin":
      guard let ssid = args["ssid"] as? String, let psk = args["psk"] as? String else {
        result(FlutterError(code: "HOTSPOT_JOIN_FAILED", message: "bad arguments", details: nil))
        return
      }
      let cfg = NEHotspotConfiguration(ssid: ssid, passphrase: psk, isWEP: false)
      cfg.joinOnce = true
      NEHotspotConfigurationManager.shared.apply(cfg) { error in
        DispatchQueue.main.async {
          var code: String? = nil
          if let error = error {
            if let ne = error as? NEHotspotConfigurationError {
              switch ne.code {
              case .alreadyAssociated: code = nil
              case .userDenied: code = "HOTSPOT_JOIN_DENIED"
              default: code = "HOTSPOT_JOIN_FAILED"
              }
            } else {
              code = "HOTSPOT_JOIN_FAILED"
            }
          }
          if let code = code {
            result(FlutterError(code: code, message: code, details: nil))
          } else {
            self.joinedSsid = ssid
            result("") // gateway unknown on iOS: the QR lists the host's hotspot address first
          }
        }
      }
    case "wifiLinkMbps":
      result(-1) // not exposed to iOS apps
    case "openAppSettings":
      if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
      result(nil)
    // Continuation key (audit P1-10): Keychain, this device only, readable after first unlock (survives reboot,
    // never synced to iCloud or restored to another phone). NOT TESTED ON DEVICES.
    case "vaultPut":
      guard let a = call.arguments as? [String: Any], let name = a["name"] as? String,
            let b64 = a["data"] as? String, let data = Data(base64Encoded: b64), Vault.valid(name) else {
        return result(FlutterError(code: "INTERNAL_ERROR", message: "vaultPut args", details: nil))
      }
      Vault.put(name, data) ? result(nil) : result(FlutterError(code: "INTERNAL_ERROR", message: "keychain", details: nil))
    case "vaultGet":
      guard let a = call.arguments as? [String: Any], let name = a["name"] as? String, Vault.valid(name) else {
        return result(FlutterError(code: "INTERNAL_ERROR", message: "vaultGet args", details: nil))
      }
      result(Vault.get(name)?.base64EncodedString())
    case "vaultDelete":
      if let a = call.arguments as? [String: Any], let name = a["name"] as? String, Vault.valid(name) { Vault.delete(name) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: capabilities (runtime-probed)

  private func probe() -> [String: Any] {
    let photoPerm = PhotosAdapter.permissionState()
    let contactPerm = ContactsAdapter.permissionState()
    func mediaStatus(_ p: String) -> String { p == "granted" ? "supported" : (p == "limited" ? "partial" : "permission_required") }
    let cats: [[String: Any]] = [
      ["id": "photos", "export": true, "import": true, "status": mediaStatus(photoPerm), "importStatus": "permission_required"],
      ["id": "videos", "export": true, "import": true, "status": mediaStatus(photoPerm), "importStatus": "permission_required"],
      ["id": "contacts", "export": true, "import": true,
       "status": contactPerm == "granted" ? "supported" : (contactPerm == "limited" ? "partial" : "permission_required"),
       "importStatus": contactPerm == "granted" ? "supported" : "permission_required"],
      ["id": "documents", "export": true, "import": true, "status": "supported", "importStatus": "supported"],
      // No public API to read the Music library files or write into it: user-picked files only, received into Files.
      ["id": "audio", "export": true, "import": true, "status": "partial", "importStatus": "partial"],
      ["id": "calendar", "export": false, "import": false, "status": "unsupported", "importStatus": "unsupported"],
    ]
    var sys = utsname()
    uname(&sys)
    let model = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
    return [
      "platform": "ios",
      "osVersion": "iOS \(UIDevice.current.systemVersion)",
      "model": model,
      "deviceName": UIDevice.current.name,  // generic "iPhone" on iOS 16+ without entitlement; user can rename in-app
      "freeBytes": FilesAdapter.freeBytes(at: URL(fileURLWithPath: NSHomeDirectory())) as Any,
      "backgroundConstraints": "ios_foreground_only",
      "permissions": ["photos": photoPerm, "videos": photoPerm, "contacts": contactPerm, "documents": "not_applicable",
                      "audio": "not_applicable", "calendar": "not_applicable"],
      "categories": cats,
    ]
  }

  private func requestPermission(category: String, forImport: Bool, result: @escaping FlutterResult) {
    switch category {
    case "photos", "videos":
      PHPhotoLibrary.requestAuthorization(for: forImport ? .addOnly : .readWrite) { status in
        DispatchQueue.main.async { result(PhotosAdapter.map(status)) }
      }
    case "contacts":
      CNContactStore().requestAccess(for: .contacts) { _, _ in
        DispatchQueue.main.async { result(ContactsAdapter.permissionState()) }
      }
    default:
      result("granted")
    }
  }

  private func presentPicker(category: String, result: @escaping FlutterResult) {
    guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
      result(FlutterError(code: "INTERNAL_ERROR", message: "no view controller", details: nil))
      return
    }
    let types: [UTType] = category == "audio" ? [.audio] : [.item]
    let coordinator = DocumentPickerCoordinator(category: category) { [weak self] items in
      result(items)
      self?.picker = nil
    }
    picker = coordinator
    let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
    vc.allowsMultipleSelection = true
    vc.delegate = coordinator
    var top = root
    while let presented = top.presentedViewController { top = presented }
    top.present(vc, animated: true)
  }

  /// iOS suspends apps in the background; the transfer must stay in the foreground. We keep the screen on and
  /// request the short background grace period so a brief app switch does not drop the socket immediately.
  private func setTransferActive(_ active: Bool) {
    DispatchQueue.main.async {
      UIApplication.shared.isIdleTimerDisabled = active
      if active, self.backgroundTask == .invalid {
        self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ptp-transfer") { [weak self] in
          guard let self = self else { return }
          UIApplication.shared.endBackgroundTask(self.backgroundTask)
          self.backgroundTask = .invalid
        }
      } else if !active, self.backgroundTask != .invalid {
        UIApplication.shared.endBackgroundTask(self.backgroundTask)
        self.backgroundTask = .invalid
      }
    }
  }

  private func deviceState() -> [String: Any] {
    UIDevice.current.isBatteryMonitoringEnabled = true
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "unknown"
    }
    let level = UIDevice.current.batteryLevel
    return [
      "batteryPct": level < 0 ? -1 : Int(level * 100),
      "charging": UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full,
      "thermal": thermal,
    ]
  }
}

struct AdapterError: Error {
  let code: String
  let message: String
}

/// A readable file prepared for sending. cleanupDir is deleted on closeRead.
struct Staged {
  let url: URL
  let mtimeMs: Int64?
  let cleanupDir: URL?
}

/// Generic-password Keychain items under one service. kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: not in
/// iCloud Keychain, not in backups restored to another device, readable after the first unlock following a reboot.
enum Vault {
  private static let service = "com.phonetransferpro.continuation"

  static func valid(_ name: String) -> Bool {
    name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
  }

  static func put(_ name: String, _ data: Data) -> Bool {
    delete(name)
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
  }

  static func get(_ name: String) -> Data? {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: AnyObject?
    return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
  }

  static func delete(_ name: String) {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
    ]
    SecItemDelete(q as CFDictionary)
  }
}
