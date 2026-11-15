import AppKit
import Common

@MainActor
private final class MouseMoveGesture {
    let generation: UInt64
    var window: Window
    var parent: NonLeafTreeNodeObject?
    var candidates: [OpaqueWindowId: (Window, NonLeafTreeNodeObject?)]
    var accepted = false
    var pending = true
    var releaseLocation: Point?
    var task: Task<(), any Error>?

    init(_ window: Window) {
        generation = mouseDownGeneration
        self.window = window
        parent = window.parent
        candidates = [window.windowId: (window, window.parent)]
    }

    var belongsToCurrentPress: Bool {
        mouseMoveGesture === self && generation == mouseDownGeneration && TrayMenuModel.shared.isEnabled
    }

    var isCurrent: Bool {
        belongsToCurrentPress && window.lifeStatus != .dead &&
            window.parent != nil && window.parent === parent && Window.get(byId: window.windowId) === window
    }
}

@MainActor private var mouseMoveGesture: MouseMoveGesture?

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let nativeWindowId = ax.containingNativeWindowId()
    let notif = notif as String
    let pid = ax.pid
    Task.startUnstructured { @MainActor in
        let window = nativeWindowId.flatMap { id in pid.flatMap { Window.get(byNativeId: id, pid: $0) } }
        _ = try await onWindowMoved(window, notif: notif)
    }
}

@MainActor
@discardableResult
func onWindowMoved(_ window: Window?, notif: String = kAXMovedNotification) async throws -> Task<(), any Error>? {
    guard let token: RunSessionGuard = .isServerEnabled else { return nil }
    guard let window, canBeManipulatedWithMouse(window) else {
        scheduleCancellableCompleteRefreshSession(.ax(notif))
        return nil
    }
    if let gesture = mouseMoveGesture {
        guard gesture.belongsToCurrentPress, gesture.releaseLocation == nil else { return gesture.task }
        if gesture.accepted {
            guard gesture.isCurrent, gesture.window === window else { return gesture.task }
        } else {
            gesture.candidates[window.windowId] = (window, window.parent)
        }
        gesture.pending = true
        return startMoveWithMouseTask(gesture, notif: notif, token)
    }
    switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer: break
        default: return nil
    }
    let gesture = MouseMoveGesture(window)
    mouseMoveGesture = gesture
    return startMoveWithMouseTask(gesture, notif: notif, token)
}

@MainActor
private func startMoveWithMouseTask(_ gesture: MouseMoveGesture, notif: String, _ token: RunSessionGuard) -> Task<(), any Error> {
    if let task = gesture.task { return task }
    let task = Task.startUnstructured {
        defer {
            gesture.task = nil
            if mouseMoveGesture === gesture && !gesture.isCurrent {
                mouseMoveGesture = nil
                resetManipulatedWithMouseIfPossible(scheduleRefresh: false)
            }
        }
        if !gesture.accepted {
            guard let focused = try await getNativeFocusedWindow(.cancellable),
                  gesture.belongsToCurrentPress,
                  let (candidate, parent) = gesture.candidates[focused.windowId], candidate === focused,
                  focused.parent != nil, focused.parent === parent, focused.lifeStatus != .dead,
                  Window.get(byId: focused.windowId) === focused
            else {
                if mouseMoveGesture === gesture {
                    if gesture.belongsToCurrentPress { scheduleCancellableCompleteRefreshSession(.ax(notif)) }
                    mouseMoveGesture = nil
                }
                return
            }
            gesture.window = focused
            gesture.parent = parent
            gesture.candidates.removeAll()
            gesture.accepted = true
            currentlyManipulatedWithMouseWindowId = focused.windowId
        }
        let window = gesture.window
        while gesture.pending && gesture.isCurrent {
            gesture.pending = false
            try await runLightSession(.ax(notif), token) {
                guard gesture.isCurrent else { return }
                try await moveWithMouse(window, at: gesture.releaseLocation ?? mouseLocation, gesture: gesture)
            }
        }
    }
    gesture.task = task
    return task
}

@MainActor
func cancelMoveWithMouse() {
    let previous = mouseMoveGesture
    mouseMoveGesture = nil
    previous?.task?.cancel()
}

/// Capture release before yielding: a suspended eligibility/layout read belongs to this gesture until it drains.
@MainActor
func endMoveWithMouse(at location: Point) -> Task<(), any Error> {
    if RunSessionGuard.isServerEnabled == nil {
        cancelMoveWithMouse()
        resetManipulatedWithMouseIfPossible(scheduleRefresh: false)
        return Task.startUnstructured {}
    }
    let generation = mouseDownGeneration
    let gesture = mouseMoveGesture
    gesture?.releaseLocation = location
    gesture?.pending = true
    let task: Task<(), any Error>? = if let gesture, gesture.isCurrent, let token = RunSessionGuard.isServerEnabled {
        startMoveWithMouseTask(gesture, notif: kAXMovedNotification, token)
    } else {
        gesture?.task
    }
    return Task.startUnstructured {
        defer {
            if generation == mouseDownGeneration {
                if mouseMoveGesture === gesture { mouseMoveGesture = nil }
                resetManipulatedWithMouseIfPossible()
            }
        }
        try await task?.value
    }
}

@MainActor
private func moveWithMouse(_ window: Window, at location: Point, gesture: MouseMoveGesture) async throws {
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            try await moveFloatingWindow(window, gesture: gesture)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            moveTilingWindow(window, at: location)
            gesture.parent = window.parent
        case nil: return
    }
    if gesture.isCurrent { _ = window.focusWindow() }
}

@MainActor
private func moveFloatingWindow(_ window: Window, gesture: MouseMoveGesture) async throws {
    guard let targetWorkspace = try await window.getCenter(.cancellable)?.monitorApproximation.visibleWorkspace else { return }
    guard gesture.isCurrent, let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
        gesture.parent = window.parent
    }
}

@MainActor
private func moveTilingWindow(_ window: Window, at mouseLocation: Point) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    let targetWorkspace = mouseLocation.monitorApproximation.visibleWorkspace
    let swapTarget = mouseLocation
        .findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
        .takeIf { $0 != window }
    if targetWorkspace != window.nodeWorkspace { // Move window to a different monitor
        let parent: TilingContainer
        let index: Int
        if let swapTarget,
           let (_parent, _index) = swapTarget.nearestAliveTilingParent(),
           let targetRect = swapTarget.lastAppliedLayoutPhysicalRect
        {
            parent = _parent
            index = mouseLocation.getProjection(_parent.orientation) >= targetRect.center.getProjection(_parent.orientation)
                ? _index + 1
                : _index
        } else {
            parent = targetWorkspace.rootTilingContainer
            index = 0
        }
        window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
    } else if let swapTarget {
        swapWindows(mruDominant: window, swapTarget)
    }
}

@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    if window1 == window2 { return }

    let binding2 = window2.unbindFromParent()
    let binding1 = window1.unbindFromParent()

    window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}

extension Point {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles:
                tree.inhabitedChildren.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentInhabitedChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
