@testable import AppBundle
import Common
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
        defer {
            unsafe isLeftMouseButtonDownForTests = nil
            mouseLocationForTests = nil
            onCompleteRefreshScheduledForTests = nil
            currentlyManipulatedWithMouseWindowId = nil
        }
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
        try await resetManipulatedWithMouseIfPossible()
        await resume.signalToAll()
        try await eligibility.value
        try await move?.value
        #expect(currentlyManipulatedWithMouseWindowId == nil)
        let before = window.appliedFramesForTest.count
        try await window.nodeWorkspace?.layoutWorkspace()
        #expect(window.appliedFramesForTest.count == before + 1)
    }
}
