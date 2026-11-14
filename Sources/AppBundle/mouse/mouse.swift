import AppKit
import Common

@MainActor var currentlyManipulatedWithMouseWindowId: OpaqueWindowId? = nil
@MainActor private(set) var mouseDownGeneration: UInt64 = 0
nonisolated(unsafe) var isLeftMouseButtonDownForTests: Bool? = nil
@MainActor var mouseLocationForTests: Point? = nil
var isLeftMouseButtonDown: Bool { unsafe isLeftMouseButtonDownForTests ?? (NSEvent.pressedMouseButtons == 1) }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    let generation = mouseDownGeneration
    guard canBeManipulatedWithMouse(window) else { return false }
    return try await getNativeFocusedWindow(.cancellable) == window &&
        generation == mouseDownGeneration && isLeftMouseButtonDown
}

@MainActor
func canBeManipulatedWithMouse(_ window: Window) -> Bool {
    !window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        isUnderLeftMouseDown(window) &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId)
}

/// Tiling windows whose layout rect, widened by resizeBorderWidth, contained the last left mouse down location.
/// A move or resize that comes while the button is down counts as a mouse drag only for these windows. Otherwise
/// AeroSpace's own moves look like drags: when an app activates a window of a hidden workspace during a click
/// elsewhere, unhiding the window moves it, and the window was moved to the workspace under the mouse.
/// The snapshot is taken at mouse down, because the rects change while the window is resized
@MainActor private var windowIdsUnderLeftMouseDown: Set<OpaqueWindowId> = []

/// macOS lets you grab the resize edge a few points outside the window frame
private let resizeBorderWidth: CGFloat = 10

@MainActor func onLeftMouseDown(_ location: Point) {
    mouseDownGeneration &+= 1
    cancelMoveWithMouse()
    resetManipulatedWithMouseIfPossible(scheduleRefresh: false)
    windowIdsUnderLeftMouseDown = windowIdsUnder(location, in: Workspace.all.filter(\.isVisible))
}

@MainActor func windowIdsUnder(_ location: Point, in workspaces: [Workspace]) -> Set<OpaqueWindowId> {
    workspaces.flatMap(\.rootTilingContainer.allLeafWindowsRecursive)
        .filter { $0.lastAppliedLayoutPhysicalRect?.widened(by: resizeBorderWidth).contains(location) == true }
        .map(\.windowId)
        .toSet()
}

/// Windows without a layout rect (floating, fullscreen, or already moved with the mouse) can't be checked and pass.
/// A floating window moved this way stays on the workspace under its own center, so a false positive is harmless
@MainActor private func isUnderLeftMouseDown(_ window: Window) -> Bool {
    window.lastAppliedLayoutPhysicalRect == nil || windowIdsUnderLeftMouseDown.contains(window.windowId)
}

/// Same motivation as in monitorFrameNormalized
@MainActor var mouseLocation: Point { mouseLocationForTests ?? NSEvent.mouseLocation.asMyPoint.withYAxisFlipped }

/// nil if the accessibility hit test fails, e.g. the app under the mouse doesn't respond
@concurrent
nonisolated func isAxWindowUnderMouse(_ location: Point) async -> Bool? {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }
    let parentWindow = element.get(Ax.parentWindowRecursive)
    return isAxWindowHit(
        role: parentWindow == nil ? element.get(Ax.roleAttr) : nil,
        subrole: element.get(Ax.subroleAttr),
        parentWindowSubrole: parentWindow?.get(Ax.subroleAttr),
        hasParentWindow: parentWindow != nil,
    )
}

func isAxWindowHit(role: String?, subrole: String?, parentWindowSubrole: String?, hasParentWindow: Bool) -> Bool {
    // Finder's desktop can be returned by AXWindow despite not being a real window.
    if subrole == "AXDesktop" || parentWindowSubrole == "AXDesktop" { return false }
    return hasParentWindow || role == kAXWindowRole
}
