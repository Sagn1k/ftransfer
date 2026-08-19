// Streaming ZIP writer (store-only, zip64-capable).
//
// Produces archive bytes incrementally so a multi-gigabyte folder can be sent
// straight to a socket with no temp file and no buffering: local header →
// file bytes → data descriptor, repeated, then the central directory.
//
// Sizes and CRCs aren't known until each file has been read, so entries use
// the data-descriptor flag (bit 3) rather than seeking back to patch headers.

import Foundation

// MARK: - CRC32

enum CRC32 {
    private static let table: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 == 1) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = crc ^ 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - little-endian helpers

private extension Data {
    mutating func u16(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }
    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
    mutating func u64(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { append(UInt8((v >> UInt64(shift)) & 0xFF)) }
    }
}

// MARK: - Streaming producer

/// Pull-based byte source: `next()` returns the following chunk, or nil at end.
protocol ChunkProducer {
    func next() -> Data?
}

/// Emits an open file in chunks, honouring an optional byte range.
final class FileChunks: ChunkProducer {
    private let handle: FileHandle
    private var remaining: Int
    private let chunkSize: Int

    init?(path: String, offset: UInt64 = 0, length: Int? = nil, chunkSize: Int = 256 * 1024) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = h
        self.chunkSize = chunkSize
        let size = (try? h.seekToEnd()) ?? 0
        let start = min(offset, size)
        let want = length ?? Int(size - start)
        self.remaining = max(0, want)
        try? h.seek(toOffset: start)
    }

    func next() -> Data? {
        guard remaining > 0 else { try? handle.close(); return nil }
        guard let chunk = try? handle.read(upToCount: min(chunkSize, remaining)),
              !chunk.isEmpty else {
            try? handle.close()
            return nil
        }
        remaining -= chunk.count
        return chunk
    }
}

/// One file to place in the archive.
struct ZipEntry {
    let arcname: String
    let path: String
}

/// Streams a ZIP archive built from `entries`.
final class ZipChunks: ChunkProducer {
    private struct Written {
        let arcname: String
        let crc: UInt32
        let size: UInt64
        let offset: UInt64
        let dosTime: UInt16
        let dosDate: UInt16
        var needsZip64: Bool { size >= 0xFFFF_FFFF || offset >= 0xFFFF_FFFF }
    }

    private var pending: [ZipEntry]
    private var done: [Written] = []
    private var offset: UInt64 = 0

    // in-flight entry state
    private var body: FileChunks?
    private var current: (arcname: String, offset: UInt64, dosTime: UInt16, dosDate: UInt16)?
    private var crc: UInt32 = 0
    private var written: UInt64 = 0
    private var declaredZip64 = false
    private var finished = false

    init(entries: [ZipEntry]) {
        self.pending = entries.reversed()  // popLast() walks them in order
    }

    func next() -> Data? {
        if finished { return nil }

        // Continue / close out the entry currently streaming.
        if let body {
            if let chunk = body.next() {
                crc = CRC32.update(crc, chunk)
                written += UInt64(chunk.count)
                offset += UInt64(chunk.count)
                return chunk
            }
            self.body = nil
            guard let cur = current else { return next() }
            var out = Data()
            out.u32(0x0807_4B50)          // data descriptor signature
            out.u32(crc)
            if declaredZip64 {
                out.u64(written); out.u64(written)
            } else {
                out.u32(UInt32(truncatingIfNeeded: written))
                out.u32(UInt32(truncatingIfNeeded: written))
            }
            done.append(Written(arcname: cur.arcname, crc: crc, size: written,
                                offset: cur.offset, dosTime: cur.dosTime, dosDate: cur.dosDate))
            offset += UInt64(out.count)
            current = nil
            return out
        }

        // Start the next entry.
        while let entry = pending.popLast() {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let handle = FileChunks(path: entry.path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let (dosTime, dosDate) = Self.dosTimestamp(modified)

            declaredZip64 = size >= 0xFFFF_FFFF || offset >= 0xFFFF_FFFF
            crc = 0
            written = 0
            body = handle
            current = (entry.arcname, offset, dosTime, dosDate)

            let nameBytes = Array(entry.arcname.utf8)
            var out = Data()
            out.u32(0x0403_4B50)                            // local file header
            out.u16(declaredZip64 ? 45 : 20)                // version needed
            out.u16(0x0008 | 0x0800)                        // data descriptor + UTF-8 names
            out.u16(0)                                      // stored
            out.u16(dosTime); out.u16(dosDate)
            out.u32(0); out.u32(0); out.u32(0)              // crc + sizes follow the data
            out.u16(UInt16(nameBytes.count))
            out.u16(declaredZip64 ? 20 : 0)                 // extra length
            out.append(contentsOf: nameBytes)
            if declaredZip64 {
                out.u16(0x0001); out.u16(16); out.u64(0); out.u64(0)
            }
            offset += UInt64(out.count)
            return out
        }

        // Nothing left to stream: emit the central directory.
        finished = true
        return centralDirectory()
    }

    private func centralDirectory() -> Data {
        var out = Data()
        let cdStart = offset
        for e in done {
            let nameBytes = Array(e.arcname.utf8)
            var extra = Data()
            if e.needsZip64 {
                extra.u16(0x0001)
                extra.u16(24)
                extra.u64(e.size); extra.u64(e.size); extra.u64(e.offset)
            }
            out.u32(0x0201_4B50)                       // central directory header
            out.u16(0x031E)                            // made by: unix, zip 3.0
            out.u16(e.needsZip64 ? 45 : 20)
            out.u16(0x0008 | 0x0800)
            out.u16(0)                                 // stored
            out.u16(e.dosTime); out.u16(e.dosDate)
            out.u32(e.crc)
            let sizeField: UInt32 = e.needsZip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: e.size)
            out.u32(sizeField); out.u32(sizeField)
            out.u16(UInt16(nameBytes.count))
            out.u16(UInt16(extra.count))
            out.u16(0)                                 // comment length
            out.u16(0)                                 // disk number
            out.u16(0)                                 // internal attrs
            out.u32(0o100644 << 16)                    // external attrs: -rw-r--r--
            out.u32(e.needsZip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: e.offset))
            out.append(contentsOf: nameBytes)
            out.append(extra)
        }
        let cdSize = UInt64(out.count)
        let count = done.count
        let needsZip64 = count > 0xFFFF || cdStart >= 0xFFFF_FFFF || cdSize >= 0xFFFF_FFFF

        if needsZip64 {
            let z64Offset = cdStart + cdSize
            out.u32(0x0606_4B50)                       // zip64 end of central directory
            out.u64(44)                                // size of this record minus 12
            out.u16(0x031E); out.u16(45)
            out.u32(0); out.u32(0)                     // disk numbers
            out.u64(UInt64(count)); out.u64(UInt64(count))
            out.u64(cdSize); out.u64(cdStart)
            out.u32(0x0706_4B50)                       // zip64 locator
            out.u32(0)
            out.u64(z64Offset)
            out.u32(1)
        }

        out.u32(0x0605_4B50)                           // end of central directory
        out.u16(0); out.u16(0)
        let entryField: UInt16 = needsZip64 ? 0xFFFF : UInt16(count)
        out.u16(entryField); out.u16(entryField)
        out.u32(needsZip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: cdSize))
        out.u32(needsZip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: cdStart))
        out.u16(0)                                     // comment length
        return out
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian)
        let p = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = p.year ?? 1980
        guard year >= 1980, year <= 2107 else { return (0, 0x0021) }  // 1980-01-01
        let hour: Int = p.hour ?? 0
        let minute: Int = p.minute ?? 0
        let second: Int = p.second ?? 0
        let month: Int = p.month ?? 1
        let day: Int = p.day ?? 1
        let timeField: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dateField: Int = ((year - 1980) << 9) | (month << 5) | day
        return (UInt16(timeField), UInt16(dateField))
    }
}
