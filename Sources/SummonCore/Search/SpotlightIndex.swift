import Foundation

/// S1 search provider seam. Production uses `mdfind`; tests inject fixtures.
public protocol SpotlightIndexing: Sendable {
    func search(query: FilterQuery, limit: Int) throws -> [SearchResult]
}

/// In-memory / fixture Spotlight for headless tests (no real mdfind).
public struct FakeSpotlightIndex: SpotlightIndexing, Sendable {
    public var files: [SearchResult]

    public init(files: [SearchResult] = []) {
        self.files = files
    }

    public func search(query: FilterQuery, limit: Int = 50) throws -> [SearchResult] {
        var results = files
        if let kind = query.kind {
            results = results.filter { result in
                switch kind {
                case "pdf":
                    return result.path?.lowercased().hasSuffix(".pdf") == true
                case "folder":
                    return result.kind == .folder
                case "image":
                    let ext = (result.path as NSString?)?.pathExtension.lowercased() ?? ""
                    return ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext)
                case "app":
                    return result.kind == .app
                case "file":
                    return result.kind == .file
                default:
                    return true
                }
            }
        }
        if let path = query.pathPrefix {
            results = results.filter { ($0.path ?? "").hasPrefix(path) }
        }
        if let name = query.nameContains?.lowercased() {
            results = results.filter { $0.title.lowercased().contains(name) }
        }
        let free = query.freeText.lowercased()
        if !free.isEmpty {
            results = results.filter {
                $0.title.lowercased().contains(free)
                    || ($0.subtitle?.lowercased().contains(free) ?? false)
                    || ($0.path?.lowercased().contains(free) ?? false)
            }
        }
        if let bound = query.modified {
            let now = Date()
            results = results.filter { result in
                guard case .number(let epoch) = result.payload["mtime"] else { return true }
                let date = Date(timeIntervalSince1970: epoch)
                return bound.matches(date: date, now: now)
            }
        }
        return Array(results.prefix(limit))
    }
}

/// Real S1: shells out to `mdfind` with a constructed Spotlight query.
/// Headless-safe: fails soft (empty) if mdfind is unavailable.
public struct MdfindSpotlightIndex: SpotlightIndexing, Sendable {
    public init() {}

    public func search(query: FilterQuery, limit: Int = 50) throws -> [SearchResult] {
        var parts: [String] = []
        if !query.freeText.isEmpty {
            // Escape quotes in free text
            let escaped = query.freeText.replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("kMDItemDisplayName == \"*\(escaped)*\"cd")
        }
        if let kind = query.kind {
            switch kind {
            case "pdf":
                parts.append("kMDItemContentTypeTree == 'com.adobe.pdf'")
            case "folder":
                parts.append("kMDItemContentTypeTree == 'public.folder'")
            case "image":
                parts.append("kMDItemContentTypeTree == 'public.image'")
            case "app":
                parts.append("kMDItemContentTypeTree == 'com.apple.application-bundle'")
            default:
                break
            }
        }
        if let name = query.nameContains {
            let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("kMDItemDisplayName == \"*\(escaped)*\"cd")
        }

        let predicate: String
        if parts.isEmpty {
            return []
        } else if parts.count == 1 {
            predicate = parts[0]
        } else {
            predicate = parts.map { "(\($0))" }.joined(separator: " && ")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        var args = [predicate]
        if let path = query.pathPrefix {
            args = ["-onlyin", path, predicate]
        }
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let paths = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return paths.prefix(limit).enumerated().map { index, path in
            let url = URL(fileURLWithPath: path)
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let kind: SearchResult.Kind = path.hasSuffix(".app") ? .app : (isDir ? .folder : .file)
            return SearchResult(
                id: "file:\(path)",
                title: url.lastPathComponent,
                subtitle: path,
                kind: kind,
                path: path,
                score: Double(500 - index)
            )
        }
    }
}
