import CoreGraphics
import Foundation
import QX20Core

/// Saves the sheets between launches.
/// Images are copied into the app's library so sheets survive the originals
/// being moved or deleted; unreferenced copies are removed at launch.
enum PageStore {
    struct SavedLayer: Codable {
        var file: String
        var name: String
        var cx, cy, w, h, rotation: Double
        var fills: Bool
        /// Normalized crop x, y, w, h (absent = whole image)
        var crop: [Double]?
    }

    struct SavedPage: Codable {
        var layers: [SavedLayer]
        var autoLayout: Bool
        /// 0 = automatic, otherwise images per sheet
        var grid: Int
    }

    struct SavedState: Codable {
        var version = 1
        var selected: Int?
        var pages: [SavedPage]
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QX20 Print", isDirectory: true)
    }

    static var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }
    static var stateFile: URL { directory.appendingPathComponent("pages.json") }

    /// Copy an image into the library; returns the copy's URL.
    static func importFile(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        if url.deletingLastPathComponent().standardizedFileURL == imagesDirectory.standardizedFileURL {
            return url
        }
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        let dest = imagesDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    @MainActor
    static func save(_ pages: [Page], selected: Page.ID?) {
        let state = SavedState(
            selected: pages.firstIndex { $0.id == selected },
            pages: pages.map { page in
                SavedPage(layers: page.layers.map { l in
                    let p = l.placement
                    return SavedLayer(file: l.source.url.lastPathComponent, name: l.source.name,
                                      cx: p.center.x, cy: p.center.y, w: p.size.width, h: p.size.height,
                                      rotation: p.rotation, fills: p.fillsFrame,
                                      crop: p.isCropped ? [p.crop.minX, p.crop.minY, p.crop.width, p.crop.height] : nil)
                }, autoLayout: page.autoLayout, grid: page.grid.cellCount ?? 0)
            })
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            NSLog("QX20 Print: could not save sheets: \(error)")
        }
    }

    /// Restored pages (images loaded) plus the selected index. Call off the main thread.
    static func load(launchedAt: Date) -> (pages: [(SavedPage, [LayerSource?])], selected: Int?)? {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return nil }
        var cache: [String: LayerSource] = [:]
        var referenced = Set<String>()
        let pages = state.pages.map { page -> (SavedPage, [LayerSource?]) in
            let sources = page.layers.map { l -> LayerSource? in
                referenced.insert(l.file)
                if let s = cache[l.file] { return s }
                let s = try? LayerSource.load(imagesDirectory.appendingPathComponent(l.file), name: l.name)
                cache[l.file] = s
                return s
            }
            return (page, sources)
        }
        removeUnreferenced(keeping: referenced, olderThan: launchedAt)
        return (pages, state.selected)
    }

    /// Delete copies no saved sheet uses. Files created after launch are kept
    /// (images added while the saved sheets were still loading).
    private static func removeUnreferenced(keeping: Set<String>, olderThan date: Date) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        for f in files where !keeping.contains(f) {
            let url = imagesDirectory.appendingPathComponent(f)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            if created < date { try? fm.removeItem(at: url) }
        }
    }
}
