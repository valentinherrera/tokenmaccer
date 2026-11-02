import Foundation

/// `os.path.join(a, b)` for a relative `b`.
func joinPath(_ a: String, _ b: String) -> String { a.hasSuffix("/") ? a + b : a + "/" + b }

/// `os.walk(top, followlinks=True)`, top-down, entries in directory order (readdir, like os.scandir):
/// `visit(dirpath, fileNames)` for a directory, then its subdirectories in order.
/// Unlike Python, a symlink loop is not followed (Python recurses until the path gets too long).
func walk(_ top: String, ancestors: Set<[UInt64]> = [], _ visit: (String, [String]) -> Void) {
    var st = stat()
    guard stat(top, &st) == 0 else { return }
    let id: [UInt64] = [UInt64(UInt32(bitPattern: st.st_dev)), st.st_ino]
    guard !ancestors.contains(id), let dir = opendir(top) else { return }
    var dirs: [String] = []
    var files: [String] = []
    while let e = readdir(dir) {
        let name = withUnsafeBytes(of: &e.pointee.d_name) { raw in
            String(decoding: UnsafeRawBufferPointer(rebasing: raw[0..<Int(e.pointee.d_namlen)]), as: UTF8.self)
        }
        if name == "." || name == ".." { continue }
        var isDir = false
        switch Int32(e.pointee.d_type) {
        case DT_DIR: isDir = true
        case DT_LNK, DT_UNKNOWN:
            var s = stat()
            isDir = stat(joinPath(top, name), &s) == 0 && (s.st_mode & S_IFMT) == S_IFDIR
        default: isDir = false
        }
        if isDir { dirs.append(name) } else { files.append(name) }
    }
    closedir(dir)
    visit(top, files)
    var inner = ancestors
    inner.insert(id)
    for d in dirs { walk(joinPath(top, d), ancestors: inner, visit) }
}

/// Complete lines from `offset` on, in constant memory; `offset` advances past each complete line.
/// A half-written last line (no newline yet) is left for the next run.
func forEachCompleteLine(_ path: String, offset: inout Int, _ body: (UnsafeRawBufferPointer) -> Void) {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return }  // unreadable or just moved: next run
    defer { close(fd) }
    guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { return }
    var buf = [UInt8](repeating: 0, count: 1 << 20)
    var filled = 0
    while true {
        if filled == buf.count { buf += [UInt8](repeating: 0, count: buf.count) }  // a very long line
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + filled, $0.count - filled) }
        if n <= 0 { return }
        filled += n
        var start = 0
        buf.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while start < filled, let nl = memchr(base + start, 0x0A, filled - start) {
                let end = base.distance(to: UnsafeRawPointer(nl)) + 1
                body(UnsafeRawBufferPointer(rebasing: raw[start..<end]))
                offset += end - start
                start = end
            }
        }
        if start > 0 {
            buf.withUnsafeMutableBytes { raw in
                _ = memmove(raw.baseAddress!, raw.baseAddress! + start, filled - start)
            }
            filled -= start
        }
    }
}

private let usageNeedle = Array("\"usage\"".utf8)

/// Reads new transcript lines into the store; returns the number of new turns.
func ingest(_ store: inout Store, sources: [String], today: CivilDate) -> Int {
    let hourCutoff = today.adding(days: -hourDays).iso
    var newTurns = 0
    for base in sources {
        walk(base) { dirpath, names in
            for name in names where name.hasSuffix(".jsonl") {
                let path = joinPath(dirpath, name)
                // os.path.relpath(path, base), '/' -> '__'
                var rel = String(path.dropFirst(base.count))
                while rel.hasPrefix("/") { rel.removeFirst() }
                let key = rel.replacingOccurrences(of: "/", with: "__")
                let isSub = key.replacingOccurrences(of: "__", with: "/").contains("/subagents/")
                var st = stat()
                guard stat(path, &st) == 0 else { continue }
                let size = Int(st.st_size)
                var offset = store.files[key] ?? 0
                if offset > size { offset = 0 }  // file was rewritten: start over, `seen` catches duplicates
                if offset == size { continue }
                forEachCompleteLine(path, offset: &offset) { line in
                    if let turn = parseTurn(line, isSub: isSub) {
                        if let k = turn.dedupKey {
                            if store.seen.contains(k) { return }
                            store.seen[k] = turn.time.date.iso
                        }
                        let day = turn.time.date.iso
                        Store.add(&store.days, day, turn.model, turn.values)
                        if day >= hourCutoff { Store.add(&store.hours, turn.time.hourKey, turn.model, turn.values) }
                        newTurns += 1
                    }
                }
                store.files[key] = offset
            }
        }
    }
    let seenCutoff = today.adding(days: -seenDays).iso
    store.seen.removeAll { _, day in day < seenCutoff }
    store.hours.removeAll { key, _ in String(key.prefix(10)) < hourCutoff }
    return newTurns
}

struct Turn {
    let time: LocalTime
    let model: String
    let dedupKey: String?
    let values: [Int]
}

/// One transcript line -> one assistant turn with usage, or nil (same filters as the Python collector).
func parseTurn(_ line: UnsafeRawBufferPointer, isSub: Bool) -> Turn? {
    let hasUsage = usageNeedle.withUnsafeBytes { needle in
        memmem(line.baseAddress, line.count, needle.baseAddress, needle.count) != nil
    }
    guard hasUsage, let d = try? JSONParser.parse(line), case .object(let obj) = d else { return nil }
    guard obj["type"]?.string == "assistant" else { return nil }
    let messageValue = obj["message"].flatMap { $0.truthy ? $0 : nil } ?? .object(OrderedDict())
    guard case .object(let m) = messageValue, let u = m["usage"], u.truthy, case .object(let usage) = u,
        let timestamp = obj["timestamp"], timestamp.truthy
    else { return nil }
    let model = m["model"].flatMap { $0.truthy ? $0.pythonStr : nil } ?? "?"
    if model == "<synthetic>" { return nil }
    guard case .string(let ts) = timestamp, let time = LocalTime.parseISO(ts) else { return nil }
    var key: String?
    if (m["id"]?.truthy ?? false) || (obj["requestId"]?.truthy ?? false) {
        key = (m["id"]?.pythonStr ?? "None") + "|" + (obj["requestId"]?.pythonStr ?? "None")
    }
    let cc = usage["cache_creation"].flatMap { $0.truthy ? $0.object : nil } ?? OrderedDict()
    let wTotal = usage["cache_creation_input_tokens"]?.intValue ?? 0
    let w1h = cc["ephemeral_1h_input_tokens"]?.intValue ?? 0
    var w5 = max(wTotal - w1h, 0)
    if let explicit = cc["ephemeral_5m_input_tokens"] {
        if case .null = explicit {} else { w5 = explicit.intValue }
    }
    let raw = usage["input_tokens"]?.intValue ?? 0
    let cr = usage["cache_read_input_tokens"]?.intValue ?? 0
    let out = usage["output_tokens"]?.intValue ?? 0
    let values = [raw, out, cr, w5, w1h, 1, isSub ? raw + cr + w5 + w1h : 0]
    return Turn(time: time, model: model, dedupKey: key, values: values)
}
