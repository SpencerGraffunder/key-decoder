import Foundation
import UIKit

/// Key photos as JPEG files in Application Support/Images/, referenced by name from KeyRecord.
enum ImageStore {
    private static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyDecoderImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @discardableResult
    static func save(_ image: UIImage, name: String? = nil) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        return write(data, name: name ?? UUID().uuidString + ".jpg")
    }

    @discardableResult
    static func write(_ data: Data, name: String) -> String? {
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func data(_ name: String?) -> Data? {
        guard let name else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func image(_ name: String?) -> UIImage? {
        guard let data = data(name) else { return nil }
        return UIImage(data: data)
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}
