import Foundation
import CoreServices
import Darwin

/// Logs are change signals only. They never overwrite the authenticated server snapshot.
final class ClientLogMonitor: @unchecked Sendable {
    private let root: URL
    private let queue = DispatchQueue(label: "com.usagebar.client-events", qos: .utility)
    private let onChange: @Sendable (Date) -> Void
    private var stream: FSEventStreamRef?
    private var cursors: [String: (inode: UInt64, offset: UInt64)] = [:]
    private var fingerprints: [String: Data] = [:]
    private var fileSources: [String: any DispatchSourceFileSystemObject] = [:]
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    init(root: URL, onChange: @escaping @Sendable (Date) -> Void) {
        self.root = root; self.onChange = onChange
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start() -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<ClientLogMonitor>.fromOpaque(info).takeUnretainedValue()
            let strings = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var overflow = false
            for index in 0..<count {
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 { overflow = true }
            }
            if overflow { owner.onChange(Date()) }
            owner.scan(strings)
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return false }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        if !FSEventStreamStart(created) { FSEventStreamInvalidate(created); FSEventStreamRelease(created); stream = nil; return false }
        queue.async { [weak self] in self?.watchRecentFiles() }
        return true
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
            queue.sync {
                fileSources.values.forEach { $0.cancel() }
                fileSources.removeAll()
            }
            FSEventStreamRelease(stream); self.stream = nil
        }
    }

    private func scan(_ paths: [String]) {
        var latestChange: Date?
        for path in Set(paths) where path.hasPrefix(root.path + "/") && path.hasSuffix(".jsonl") {
            watchFile(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let file = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? file.close() }
            let previous = cursors[path]
            var offset = previous?.inode == inode && (previous?.offset ?? 0) <= size ? previous!.offset : 0
            let cap: UInt64 = 2 * 1024 * 1024
            var skipFirst = false
            if size > offset + cap { offset = size - cap; skipFirst = true; latestChange = Date() }
            guard size > offset else { continue }
            do {
                try file.seek(toOffset: offset)
                let bytes = try file.read(upToCount: Int(min(size - offset, cap))) ?? Data()
                guard let last = bytes.lastIndex(of: 10) else { continue }
                var consumed = Data(bytes.prefix(through: last))
                cursors[path] = (inode, offset + UInt64(consumed.count))
                if skipFirst, let first = consumed.firstIndex(of: 10) { consumed.removeSubrange(...first) }
                for line in consumed.split(separator: 10) {
                    guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          event["type"] as? String == "event_msg", let payload = event["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count", let rate = payload["rate_limits"] as? [String: Any],
                          let stamp = event["timestamp"] as? String,
                          let date = fractional.date(from: stamp) ?? plain.date(from: stamp),
                          date.timeIntervalSinceNow >= -120, date.timeIntervalSinceNow <= 60,
                          let fingerprint = try? JSONSerialization.data(withJSONObject: rate, options: [.sortedKeys]) else { continue }
                    let id = rate["limit_id"] as? String ?? "legacy"
                    guard fingerprints[id] != fingerprint else { continue }
                    fingerprints[id] = fingerprint
                    latestChange = max(latestChange ?? date, date)
                }
            } catch { latestChange = Date() }
        }
        if let latestChange { onChange(latestChange) }
        if cursors.count > 128 { cursors.removeAll(keepingCapacity: true) }
    }

    private func watchRecentFiles() {
        for url in Self.recentFiles(in: root) { watchFile(url.path) }
    }

    /// Retain only the newest candidates, rather than every historical log URL
    /// (and its cached resource values). The per-entry pool bounds ObjC temporaries.
    static func recentFiles(in root: URL, limit: Int = 24) -> [URL] {
        guard limit > 0,
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var recent: [(URL, Date)] = []
        recent.reserveCapacity(limit)
        while autoreleasepool(invoking: {
            guard let item = files.nextObject() else { return false }
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return true }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let index = recent.firstIndex { date > $0.1 || (date == $0.1 && url.path < $0.0.path) } ?? recent.endIndex
            if index < limit {
                if recent.count == limit { recent.removeLast() }
                recent.insert((url, date), at: index)
            }
            return true
        }) {}
        return recent.map { $0.0 }
    }

    private func watchFile(_ path: String) {
        guard fileSources[path] == nil else { return }
        if fileSources.count >= 32, let old = fileSources.keys.first { fileSources.removeValue(forKey: old)?.cancel() }
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = self.fileSources[path]?.data ?? []
            if !mask.intersection([.rename, .delete]).isEmpty {
                self.fileSources.removeValue(forKey: path)?.cancel(); self.cursors.removeValue(forKey: path)
            }
            self.scan([path])
        }
        source.setCancelHandler { Darwin.close(fd) }
        fileSources[path] = source; source.resume()
    }
}
