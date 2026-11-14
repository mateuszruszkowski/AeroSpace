@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct MoveWithMouseTest {
    init() {
        setUpWorkspacesForTests()
        onCompleteRefreshScheduledForTests = {}
        unsafe isLeftMouseButtonDownForTests = true
        mouseLocationForTests = Point(x: 100, y: 100)
    }

    @Test func testEligibilityCompletingAfterMouseUpCannotLeaveWindowManipulated() async throws {
        defer { resetInput() }
        let window = TestWindow.new(id: 1, parent: mainMonitorInfo.visibleWorkspace.rootTilingContainer)
        window.nativeFocus()
        onLeftMouseDown(mouseLocation)
        let suspended = AwaitableOneTimeBroadcastLatch()
        let resume = AwaitableOneTimeBroadcastLatch()
        TestApp.shared.onNextGetFocusedWindowForTest = {
            await suspended.signalToAll()
            try await resume.await(.cancellable)
        }
        var move: Task<(), any Error>?
        let eligibility = Task.startUnstructured { move = try await onWindowMoved(window) }
        try await suspended.await(.cancellable)
        unsafe isLeftMouseButtonDownForTests = false
        let release = endMoveWithMouse(at: mouseLocation)
        await resume.signalToAll()
        try await eligibility.value
        try await move?.value
        try await release.value
        #expect(currentlyManipulatedWithMouseWindowId == nil)
        let before = window.appliedFramesForTest.count
        try await window.nodeWorkspace?.layoutWorkspace()
        #expect(window.appliedFramesForTest.count == before + 1)
    }

    @Test func testPendingSessionDrainsBurstAndFinalizesAtCapturedReleasePoint() async throws {
        defer { resetInput() }
        let (window, source, target) = fixture()
        window.isFullscreen = true
        let (suspended, resume) = suspendNextSession()
        let first = try await onWindowMoved(window)
        try await suspended.await(.cancellable)
        let reads = TestApp.shared.focusedWindowReadCountForTest
        for _ in 0 ..< 40 { _ = try await onWindowMoved(window) }
        #expect(TestApp.shared.focusedWindowReadCountForTest == reads)
        unsafe isLeftMouseButtonDownForTests = false
        let release = endMoveWithMouse(at: Point(x: 2200, y: 100))
        #expect(currentlyManipulatedWithMouseWindowId == window.windowId)
        let before = window.appliedFramesForTest.count
        try await source.layoutWorkspace()
        #expect(window.appliedFramesForTest.count == before)
        mouseLocationForTests = Point(x: 100, y: 100)
        await resume.signalToAll()
        try await first?.value
        try await release.value
        #expect(window.nodeWorkspace === target)
        #expect(currentlyManipulatedWithMouseWindowId == nil)
        #expect(TestApp.shared.focusedWindowReadCountForTest <= reads + 1)
        let settled = window.appliedFramesForTest.count
        try await target.layoutWorkspace()
        #expect(window.appliedFramesForTest.count == settled + 1)
        #expect(window.isFullscreen)
        #expect(window.appliedFramesForTest.last?.0 == target.workspaceMonitorInfo.visibleRect.topLeftCorner)
        #expect(window.appliedFramesForTest.last?.1?.width == target.workspaceMonitorInfo.visibleRect.width)
    }

    @Test func testNotificationAfterPreviousDrainAndReleaseBothRun() async throws {
        defer { resetInput() }
        let (window, _, target) = fixture()
        try await onWindowMoved(window)?.value
        #expect(window.nodeWorkspace !== target)
        mouseLocationForTests = Point(x: 2200, y: 100)
        try await onWindowMoved(window)?.value
        #expect(window.nodeWorkspace === target)
        unsafe isLeftMouseButtonDownForTests = false
        try await endMoveWithMouse(at: Point(x: 100, y: 100)).value
        #expect(window.nodeWorkspace === mainMonitorInfo.visibleWorkspace)
        #expect(currentlyManipulatedWithMouseWindowId == nil)
    }

    @Test func testFloatingWindowRemainsUntouchedWhileSessionIsPending() async throws {
        defer { resetInput() }
        let (window, source, target) = fixture(floating: true)
        let (suspended, resume) = suspendNextSession()
        let move = try await onWindowMoved(window)
        try await suspended.await(.cancellable)
        try await source.layoutWorkspace()
        #expect(window.appliedFramesForTest.isEmpty)
        unsafe isLeftMouseButtonDownForTests = false
        let release = endMoveWithMouse(at: Point(x: 2200, y: 100))
        await resume.signalToAll()
        try await move?.value
        try await release.value
        #expect(window.parent === target.floatingWindowsContainer)
        #expect(currentlyManipulatedWithMouseWindowId == nil)
    }

    @Test func testReparentedFloatingWindowIsNotReboundAfterCenterRead() async throws {
        defer { resetInput() }
        let (window, _, _) = fixture(floating: true)
        let destination = Workspace.get(byName: "external-command")
        let suspended = AwaitableOneTimeBroadcastLatch()
        let resume = AwaitableOneTimeBroadcastLatch()
        window.onNextGetAxRectForTest = {
            await suspended.signalToAll()
            try await resume.await(.cancellable)
        }
        let move = try await onWindowMoved(window)
        try await suspended.await(.cancellable)
        window.bindAsFloatingWindow(to: destination)
        unsafe isLeftMouseButtonDownForTests = false
        let release = endMoveWithMouse(at: Point(x: 2200, y: 100))
        await resume.signalToAll()
        try await move?.value
        try await release.value
        #expect(window.parent === destination.floatingWindowsContainer)
        #expect(currentlyManipulatedWithMouseWindowId == nil)
    }

    @Test func testDestroyedTargetCannotBeMovedByPendingSession() async throws {
        defer { resetInput() }
        let (window, _, _) = fixture()
        let (suspended, resume) = suspendNextSession()
        let move = try await onWindowMoved(window)
        try await suspended.await(.cancellable)
        window.closeAxWindow()
        unsafe isLeftMouseButtonDownForTests = false
        let release = endMoveWithMouse(at: Point(x: 2200, y: 100))
        await resume.signalToAll()
        try await move?.value
        try await release.value
        #expect(window.parent == nil)
        #expect(currentlyManipulatedWithMouseWindowId == nil)
    }

    @Test func testOldReleaseCannotResetNewPress() async throws {
        defer { resetInput() }
        let (old, source, target) = fixture()
        let (suspended, resume) = suspendNextSession(cancellationMode: .nonCancellable)
        let first = try await onWindowMoved(old)
        try await suspended.await(.cancellable)
        unsafe isLeftMouseButtonDownForTests = false
        let oldRelease = endMoveWithMouse(at: Point(x: 2200, y: 100))
        unsafe isLeftMouseButtonDownForTests = true
        let current = TestWindow.new(id: 2, parent: source.rootTilingContainer)
        current.nativeFocus()
        onLeftMouseDown(Point(x: 100, y: 100))
        try await onWindowMoved(current)?.value
        #expect(currentlyManipulatedWithMouseWindowId == current.windowId)
        await resume.signalToAll()
        _ = try? await first?.value
        _ = try? await oldRelease.value
        #expect(currentlyManipulatedWithMouseWindowId == current.windowId)
        #expect(old.nodeWorkspace === source)
        unsafe isLeftMouseButtonDownForTests = false
        try await endMoveWithMouse(at: Point(x: 2200, y: 100)).value
        #expect(current.nodeWorkspace === target)
        #expect(currentlyManipulatedWithMouseWindowId == nil)
    }

    @Test func testDisablingServerDuringPendingSessionPreventsRebind() async throws {
        defer { resetInput() }
        let (window, source, _) = fixture()
        let (suspended, resume) = suspendNextSession()
        let move = try await onWindowMoved(window)
        try await suspended.await(.cancellable)
        TrayMenuModel.shared.isEnabled = false
        mouseLocationForTests = Point(x: 2200, y: 100)
        await resume.signalToAll()
        try await move?.value
        #expect(window.nodeWorkspace === source)
        #expect(currentlyManipulatedWithMouseWindowId == nil)
        #expect(try await onWindowMoved(window) == nil)
    }

    @Test func testPlainClickAndUnattributedMovesLeaveTreeUntouched() async throws {
        defer { resetInput() }
        let (window, source, _) = fixture()
        window.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 500)
        onLeftMouseDown(Point(x: 2200, y: 100))
        #expect(try await onWindowMoved(window) == nil)
        unsafe isLeftMouseButtonDownForTests = false
        try await endMoveWithMouse(at: Point(x: 2200, y: 100)).value
        #expect(try await onWindowMoved(window) == nil)
        #expect(window.nodeWorkspace === source)
        #expect(currentlyManipulatedWithMouseWindowId == nil)
        #expect(TestApp.shared.focusedWindowReadCountForTest == 0)
    }

    @Test func testResizeEligibilityIsInvalidatedByRelease() async throws {
        defer { resetInput() }
        let (window, _, _) = fixture()
        let suspended = AwaitableOneTimeBroadcastLatch()
        let resume = AwaitableOneTimeBroadcastLatch()
        TestApp.shared.onNextGetFocusedWindowForTest = {
            await suspended.signalToAll()
            try await resume.await(.cancellable)
        }
        var eligible = true
        let check = Task.startUnstructured { eligible = try await isManipulatedWithMouse(window) }
        try await suspended.await(.cancellable)
        unsafe isLeftMouseButtonDownForTests = false
        await resume.signalToAll()
        try await check.value
        #expect(!eligible)
    }

    @Test func testEligibilityCoalescesCandidatesWithoutLosingFocusedWindow() async throws {
        defer { resetInput() }
        let (unrelated, source, target) = fixture(floating: true)
        let dragged = TestWindow.new(id: 2, parent: source.floatingWindowsContainer,
                                     rect: Rect(topLeftX: 2100, topLeftY: 100, width: 200, height: 200))
        dragged.nativeFocus()
        let suspended = AwaitableOneTimeBroadcastLatch()
        let resume = AwaitableOneTimeBroadcastLatch()
        TestApp.shared.onNextGetFocusedWindowForTest = {
            await suspended.signalToAll()
            try await resume.await(.cancellable)
        }
        let first = try await onWindowMoved(unrelated)
        try await suspended.await(.cancellable)
        _ = try await onWindowMoved(dragged)
        #expect(TestApp.shared.focusedWindowReadCountForTest == 1)
        unsafe isLeftMouseButtonDownForTests = false
        let release = endMoveWithMouse(at: Point(x: 2200, y: 100))
        await resume.signalToAll()
        try await first?.value
        try await release.value
        #expect(unrelated.nodeWorkspace === source)
        #expect(dragged.nodeWorkspace === target)
        #expect(currentlyManipulatedWithMouseWindowId == nil)
    }

    @Test func testReleaseWhileDisabledClearsCompletedGesture() async throws {
        defer { resetInput() }
        let (window, source, _) = fixture()
        try await onWindowMoved(window)?.value
        #expect(currentlyManipulatedWithMouseWindowId == window.windowId)
        TrayMenuModel.shared.isEnabled = false
        unsafe isLeftMouseButtonDownForTests = false
        try await endMoveWithMouse(at: Point(x: 2200, y: 100)).value
        #expect(currentlyManipulatedWithMouseWindowId == nil)
        #expect(window.nodeWorkspace === source)
    }

    private func fixture(floating: Bool = false) -> (TestWindow, Workspace, Workspace) {
        unsafe monitorInfosForTests = [mainMonitorInfo, SecondaryMonitor()]
        let source = mainMonitorInfo.visibleWorkspace
        let target = globalUnsortedMonitorInfos[1].visibleWorkspace
        let window = TestWindow.new(
            id: 1, parent: floating ? source.floatingWindowsContainer : source.rootTilingContainer,
            rect: Rect(topLeftX: floating ? 2100 : 100, topLeftY: 100, width: 200, height: 200),
        )
        window.nativeFocus()
        onLeftMouseDown(Point(x: 100, y: 100))
        return (window, source, target)
    }

    private func suspendNextSession(cancellationMode: CancellationMode = .cancellable)
        -> (AwaitableOneTimeBroadcastLatch, AwaitableOneTimeBroadcastLatch)
    {
        let suspended = AwaitableOneTimeBroadcastLatch()
        let resume = AwaitableOneTimeBroadcastLatch()
        TestApp.shared.onNextGetFocusedWindowForTest = {
            TestApp.shared.onNextGetFocusedWindowForTest = {
                await suspended.signalToAll()
                try await resume.await(cancellationMode)
            }
        }
        return (suspended, resume)
    }

    private func resetInput() {
        cancelMoveWithMouse()
        resetManipulatedWithMouseIfPossible(scheduleRefresh: false)
        unsafe isLeftMouseButtonDownForTests = nil
        mouseLocationForTests = nil
        onCompleteRefreshScheduledForTests = nil
        TestApp.shared.onNextGetFocusedWindowForTest = nil
        TrayMenuModel.shared.isEnabled = true
        unsafe monitorInfosForTests = nil
        gcMonitors()
    }
}

private struct SecondaryMonitor: MonitorInfo {
    let monitorAppKitNsScreenScreensId = 2
    let name = "Second Test Monitor"
    let rect = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)
    let visibleRect = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)
    let width: CGFloat = 1920
    let height: CGFloat = 1080
    let isMain = false
}
