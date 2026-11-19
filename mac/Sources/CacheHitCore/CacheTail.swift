import Foundation

struct TailStat: Equatable {
    var device: UInt64
    var inode: UInt64
    var size: UInt64
    var modified: Date?
}

enum TailStatResult: Equatable {
    case missing
    case unreadable
    case stat(TailStat)
}

enum TailReadResult: Equatable {
    case missing
    case unreadable
    case data(Data)
}

protocol TailStore {
    func stat(_ path: String) -> TailStatResult
    func read(_ path: String, offset: UInt64, maxBytes: Int) -> TailReadResult
}

struct LiveTailStore: TailStore {
    func stat(_ path: String) -> TailStatResult {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            if type != .typeRegular { return .unreadable }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let modified = attributes[.modificationDate] as? Date
            return .stat(TailStat(device: 0, inode: inode, size: size, modified: modified))
        } catch {
            let code = (error as NSError).code
            if code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError {
                return .missing
            }
            return .unreadable
        }
    }

    func read(_ path: String, offset: UInt64, maxBytes: Int) -> TailReadResult {
        guard maxBytes > 0, let handle = FileHandle(forReadingAtPath: path) else {
            return FileManager.default.fileExists(atPath: path) ? .unreadable : .missing
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: maxBytes) ?? Data()
            return .data(data)
        } catch {
            return .unreadable
        }
    }
}

struct TailBatch: Equatable {
    var lines: [String] = []
    var reset = false
    var missing = false
    var unreadable = false
    var rotated = false
    var truncated = false
    var openedAtTail = false
}

final class LineTail {
    let path: String
    private let store: any TailStore
    private let initialTailBytes: Int
    private let maxPartial: Int
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var partial = Data()
    private var primed = false
    private var skipHead = false
    private var backupPath: String?
    private var backupOffset: UInt64 = 0
    private var backupInode: UInt64?
    private var pendingInode: UInt64?

    init(path: String, store: any TailStore, initialTailBytes: Int, maxPartial: Int = 256 * 1024) {
        self.path = path
        self.store = store
        self.initialTailBytes = initialTailBytes
        self.maxPartial = maxPartial
    }

    func poll(maxBytes: Int) -> TailBatch {
        var batch = TailBatch()
        var budget = max(1, maxBytes)
        if backupPath != nil {
            drainBackup(&batch, budget: &budget)
            if budget <= 0 || backupPath != nil { return batch }
        }
        switch store.stat(path) {
        case .missing:
            batch.missing = true
            return batch
        case .unreadable:
            batch.unreadable = true
            return batch
        case .stat(let info):
            if !primed {
                primed = true
                inode = info.inode
                if info.size > UInt64(initialTailBytes) {
                    offset = info.size - UInt64(initialTailBytes)
                    skipHead = true
                    batch.openedAtTail = true
                }
            } else if let inode, inode != info.inode {
                let backup = path + ".1"
                if case .stat(let previous) = store.stat(backup), previous.inode == inode {
                    batch.rotated = true
                    backupPath = backup
                    backupOffset = offset
                    backupInode = inode
                    pendingInode = info.inode
                    drainBackup(&batch, budget: &budget)
                    if budget <= 0 || backupPath != nil { return batch }
                } else {
                    batch.reset = true
                    partial.removeAll()
                    offset = 0
                    skipHead = false
                    self.inode = info.inode
                }
            } else if info.size < offset {
                batch.reset = true
                batch.truncated = true
                partial.removeAll()
                offset = 0
                skipHead = false
                self.inode = info.inode
            }
            consume(path: path, fileOffset: &offset, budget: &budget, into: &batch)
            return batch
        }
    }

    private func drainBackup(_ batch: inout TailBatch, budget: inout Int) {
        guard let backup = backupPath else { return }
        let eof = consume(path: backup, fileOffset: &backupOffset, budget: &budget, into: &batch, stopAtEOF: true)
        if eof {
            partial.removeAll()
            backupPath = nil
            offset = 0
            inode = pendingInode
            pendingInode = nil
            skipHead = false
            primed = true
        }
    }

    @discardableResult
    private func consume(
        path: String,
        fileOffset: inout UInt64,
        budget: inout Int,
        into batch: inout TailBatch,
        stopAtEOF: Bool = false
    ) -> Bool {
        guard budget > 0 else { return false }
        switch store.read(path, offset: fileOffset, maxBytes: budget) {
        case .missing:
            batch.missing = true
            return true
        case .unreadable:
            batch.unreadable = true
            return true
        case .data(let data):
            if data.isEmpty { return true }
            budget -= data.count
            fileOffset += UInt64(data.count)
            var chunk = data
            if skipHead {
                if let newline = chunk.firstIndex(of: 0x0A) {
                    chunk = Data(chunk[(newline + 1)...])
                    skipHead = false
                } else {
                    return false
                }
            }
            partial.append(chunk)
            if partial.count > maxPartial, partial.firstIndex(of: 0x0A) == nil {
                partial.removeAll()
                batch.reset = false
                return false
            }
            while let newline = partial.firstIndex(of: 0x0A) {
                let piece = partial[..<newline]
                partial.removeSubrange(...newline)
                if let text = String(data: piece, encoding: .utf8) {
                    batch.lines.append(text)
                }
            }
            if stopAtEOF, case .stat(let info) = store.stat(path), fileOffset >= info.size {
                return true
            }
            return data.isEmpty
        }
    }
}
