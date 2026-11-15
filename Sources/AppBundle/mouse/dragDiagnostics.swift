#if DRAG_DIAGNOSTICS
    import AppKit
    import Common

    @MainActor private var dragDiagnosticSeen: Set<String> = []
    @MainActor private var dragDiagnosticCounts: [String: Int] = [:]
    @MainActor private let dragDiagnosticFile: FileHandle? = {
        let file = "/Users/matt/Projects/AeroSpace-builds/drag-performance-20261114/drag-lifecycle-diagnostic.log"
        if !FileManager.default.fileExists(atPath: file) { FileManager.default.createFile(atPath: file, contents: nil) }
        let handle = FileHandle(forWritingAtPath: file)
        handle?.seekToEndOfFile()
        return handle
    }()

    @MainActor
    func dragDiagnostic(_ phase: String, _ window: Window? = nil, generation: UInt64? = nil, details: String = "", always: Bool = false) {
        let generation = generation ?? mouseDownGeneration
        let key = "\(generation):\(phase):\(window?.windowId.rawId ?? 0)"
        dragDiagnosticCounts[key, default: 0] += 1
        if !always && !dragDiagnosticSeen.insert(key).inserted { return }
        let parent = window?.parent.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        let workspace = window?.nodeWorkspace?.name ?? "nil"
        let rect = window?.lastAppliedLayoutPhysicalRect.map { "\($0.topLeftX),\($0.topLeftY),\($0.width),\($0.height)" } ?? "nil"
        let text = "DRAG-LIFECYCLE \(ProcessInfo.processInfo.systemUptime) pid=\(ProcessInfo.processInfo.processIdentifier) phase=\(phase) gen=\(generation) currentGen=\(mouseDownGeneration) down=\(isLeftMouseButtonDown) manipulated=\(currentlyManipulatedWithMouseWindowId?.rawId.description ?? "nil") window=\(window?.windowId.rawId.description ?? "nil") workspace=\(workspace) parent=\(parent) fullscreen=\(window?.isFullscreen.description ?? "nil") rect=\(rect) \(details)\n"
        dragDiagnosticFile?.write(Data(text.utf8))
    }

    @MainActor
    func dragDiagnosticBeginPress(_ location: Point, ids: Set<OpaqueWindowId>, windows: [Window]) {
        dragDiagnosticSeen.removeAll()
        dragDiagnosticCounts.removeAll()
        dragDiagnostic("down", details: "cursor=\(location.x),\(location.y) attributed=\(ids.map(\.rawId).sorted())", always: true)
        for window in windows.prefix(64) { dragDiagnostic("down-window", window) }
    }

    @MainActor
    func dragDiagnosticCounters() -> String {
        dragDiagnosticCounts.sorted { $0.key < $1.key }.lazy.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
#endif
