// Photos, Contacts and Files adapters for iOS. NOT YET BUILT OR DEVICE-TESTED.
import Contacts
import Flutter
import Photos
import UIKit
import UniformTypeIdentifiers

// MARK: - Photos

final class PhotosAdapter {
  static func map(_ s: PHAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "granted"
    case .limited: return "limited"
    case .notDetermined: return "not_determined"
    default: return "denied"
    }
  }

  static func permissionState() -> String { map(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

  /// Metadata only. Under "limited" access PhotoKit returns just the assets the user selected.
  func scan(category: String, limit: Int) -> [[String: Any]] {
    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    opts.fetchLimit = limit
    let assets = PHAsset.fetchAssets(with: category == "videos" ? .video : .image, options: opts)
    var out: [[String: Any]] = []
    out.reserveCapacity(assets.count)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM"
    assets.enumerateObjects { asset, _, _ in
      guard let res = Self.primaryResource(asset) else { return }
      let folder = asset.creationDate.map { fmt.string(from: $0) } ?? "Unknown"
      out.append([
        "id": asset.localIdentifier,
        "name": res.originalFilename,
        "relPath": "\(folder)/\(Self.sanitize(res.originalFilename))",
        "category": category,
        "size": 0,  // exact size is only known after export (no public API before that)
        "mime": UTType(res.uniformTypeIdentifier)?.preferredMIMEType as Any,
      ])
    }
    return out
  }

  static func primaryResource(_ asset: PHAsset) -> PHAssetResource? {
    let rs = PHAssetResource.assetResources(for: asset)
    let order: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
    for t in order { if let r = rs.first(where: { $0.type == t }) { return r } }
    return rs.first
  }

  /// Writes the original resource into a private staging folder (downloads from iCloud if needed).
  /// Live Photos: only the still image is exported (documented limitation).
  func export(localIdentifier: String) throws -> Staged {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
          let res = Self.primaryResource(asset) else {
      throw AdapterError(code: "FILE_CHANGED", message: "asset no longer available")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stage/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(Self.sanitize(res.originalFilename))
    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = true
    let sem = DispatchSemaphore(value: 0)
    var failure: Error?
    PHAssetResourceManager.default().writeData(for: res, toFile: url, options: opts) { err in
      failure = err
      sem.signal()
    }
    sem.wait()
    if failure != nil {
      try? FileManager.default.removeItem(at: dir)
      throw AdapterError(code: "PERMISSION_DENIED", message: "export failed")
    }
    let mtime = (asset.modificationDate ?? asset.creationDate).map { Int64($0.timeIntervalSince1970 * 1000) }
    return Staged(url: url, mtimeMs: mtime, cleanupDir: dir)
  }

  /// Adds a received file to the Photos library (needs add-only permission). Moves instead of copying.
  func importFile(url: URL, isVideo: Bool, name: String) -> [String: Any] {
    guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized ||
            PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized ||
            PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
      return ["status": "failed", "message": "PERMISSION_DENIED"]
    }
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    PHPhotoLibrary.shared().performChanges({
      let req = PHAssetCreationRequest.forAsset()
      let o = PHAssetResourceCreationOptions()
      o.shouldMoveFile = true
      o.originalFilename = name
      req.addResource(with: isVideo ? .video : .photo, fileURL: url, options: o)
    }) { success, _ in
      ok = success
      sem.signal()
    }
    sem.wait()
    // Typical failure: a format Photos cannot ingest (e.g. some Android video codecs). Caller saves to Files.
    return ok ? ["status": "imported", "location": "Photos"] : ["status": "failed", "message": "UNSUPPORTED_FORMAT"]
  }

  static func sanitize(_ name: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    var s = String(name.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
    while s.hasSuffix(" ") || s.hasSuffix(".") { s.removeLast() }
    return s.isEmpty ? "item" : String(s.prefix(120))
  }
}

// MARK: - Contacts

final class ContactsAdapter {
  static let allContactsId = "contacts:all"

  static func permissionState() -> String {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized: return "granted"
    case .notDetermined: return "not_determined"
    default:
      if #available(iOS 18.0, *), CNContactStore.authorizationStatus(for: .contacts) == .limited { return "limited" }
      return "denied"
    }
  }

  func scan() -> [[String: Any]] {
    guard Self.permissionState() == "granted" || Self.permissionState() == "limited" else { return [] }
    return [["id": Self.allContactsId, "name": "contacts.vcf", "relPath": "contacts.vcf", "category": "contacts",
             "size": 0, "mime": "text/vcard"]]
  }

  /// vCard 3.0 via CNContactVCardSerialization. iOS omits the "note" field for third-party apps.
  func exportAll() throws -> Staged {
    let store = CNContactStore()
    let keys = [CNContactVCardSerialization.descriptorForRequiredKeys()]
    var all: [CNContact] = []
    try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in all.append(c) }
    let data = try CNContactVCardSerialization.data(with: all)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stage/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("contacts.vcf")
    try data.write(to: url, options: .completeFileProtection)
    return Staged(url: url, mtimeMs: nil, cleanupDir: dir)
  }

  /// Adds contacts that do not already exist (same full name AND a shared phone number or e-mail).
  /// Without Contacts permission the .vcf is kept in Files (status saved_to_files) so nothing is lost and the
  /// user can open it later with the Contacts app.
  func importVCard(url: URL, files: FilesAdapter) throws -> [String: Any] {
    guard Self.permissionState() == "granted" else {
      return try files.saveToFiles(url: url, category: "contacts", name: url.lastPathComponent, reason: "PERMISSION_DENIED")
    }
    let incoming = try CNContactVCardSerialization.contacts(with: Data(contentsOf: url))
    let store = CNContactStore()
    let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                   CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
    let save = CNSaveRequest()
    var added = 0, duplicates = 0
    for c in incoming {
      let name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
      var dup = false
      if !name.isEmpty {
        let existing = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        let phones = Set(c.phoneNumbers.map { $0.value.stringValue.filter(\.isNumber) })
        let mails = Set(c.emailAddresses.map { ($0.value as String).lowercased() })
        dup = existing.contains { e in
          !phones.isDisjoint(with: e.phoneNumbers.map { $0.value.stringValue.filter(\.isNumber) }) ||
            !mails.isDisjoint(with: e.emailAddresses.map { ($0.value as String).lowercased() }) ||
            (phones.isEmpty && mails.isEmpty)
        }
      }
      if dup { duplicates += 1; continue }
      if let m = c.mutableCopy() as? CNMutableContact { save.add(m, toContainerWithIdentifier: nil); added += 1 }
    }
    if added > 0 { try store.execute(save) }
    try? FileManager.default.removeItem(at: url)
    return ["status": "imported", "location": "Contacts", "message": "added=\(added) duplicates=\(duplicates)"]
  }
}

// MARK: - Files (inbox, staging, "On My iPhone" exposure)

final class FilesAdapter {
  private var open: [String: Staged] = [:]
  private let lock = NSLock()

  /// Application Support/inbox — not visible in Files, excluded from iCloud backup.
  static func inboxDir() throws -> URL {
    var url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var rv = URLResourceValues()
    rv.isExcludedFromBackup = true
    try url.setResourceValues(rv)
    return url
  }

  static func freeBytes(at url: URL) -> Int64? {
    let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return v?.volumeAvailableCapacityForImportantUsage
  }

  func openStaged(_ s: Staged) throws -> [String: Any] {
    let attrs = try FileManager.default.attributesOfItem(atPath: s.url.path)
    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    let fsMtime = (attrs[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1000) }
    let token = UUID().uuidString
    lock.lock(); open[token] = s; lock.unlock()
    return ["path": s.url.path, "size": size, "mtimeMs": (s.mtimeMs ?? fsMtime) as Any, "token": token]
  }

  func close(token: String) {
    lock.lock(); let s = open.removeValue(forKey: token); lock.unlock()
    if let dir = s?.cleanupDir { try? FileManager.default.removeItem(at: dir) }
  }

  /// Documents/Received/<category>/ is shown in Files > On My iPhone > Phone Transfer Pro
  /// (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace in the app Info.plist).
  func saveToFiles(url: URL, category: String, name: String, reason: String?) throws -> [String: Any] {
    let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = docs.appendingPathComponent("Received/\(category)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var dest = dir.appendingPathComponent(PhotosAdapter.sanitize(name))
    var n = 1
    let stem = dest.deletingPathExtension().lastPathComponent
    let ext = dest.pathExtension
    while FileManager.default.fileExists(atPath: dest.path) {
      dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
      n += 1
    }
    try FileManager.default.moveItem(at: url, to: dest)
    var r: [String: Any] = ["status": "saved_to_files", "location": "Files/Phone Transfer Pro/Received/\(category)"]
    if let reason = reason { r["message"] = reason }
    return r
  }
}

// MARK: - Document picker (copies chosen files into our tmp; we never get broad file-system access)

final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
  private let category: String
  private let done: ([[String: Any]]) -> Void

  init(category: String, done: @escaping ([[String: Any]]) -> Void) {
    self.category = category
    self.done = done
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    done(urls.map { u in
      let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      return ["id": u.path, "name": u.lastPathComponent, "relPath": PhotosAdapter.sanitize(u.lastPathComponent),
              "category": category, "size": size, "mime": UTType(filenameExtension: u.pathExtension)?.preferredMIMEType as Any]
    })
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done([]) }
}
