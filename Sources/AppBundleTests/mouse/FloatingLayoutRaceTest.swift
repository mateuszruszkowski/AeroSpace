@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FloatingLayoutRaceTest {
    init() { setUpWorkspacesForTests() }

    @Test func testPendingFloatingLayoutDoesNotClearLayoutAfterWindowChangesParent() async throws {
        let source = mainMonitorInfo.visibleWorkspace
        let target = Workspace.get(byName: "target")
        let moving = TestWindow.new(
            id: 1, parent: source.floatingWindowsContainer,
            rect: Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 200),
        )
        let slow = TestWindow.new(
            id: 2, parent: source.floatingWindowsContainer,
            rect: Rect(topLeftX: 400, topLeftY: 100, width: 200, height: 200),
        )
        let suspended = AwaitableOneTimeBroadcastLatch()
        let resume = AwaitableOneTimeBroadcastLatch()
        slow.onNextGetAxRectForTest = {
            await suspended.signalToAll()
            try await resume.await(.cancellable)
        }

        let layout = Task.startUnstructured { try await source.layoutWorkspace() }
        try await suspended.await(.cancellable)

        // A command moves and lays out the window while a sibling's AX read holds the old batch open.
        moving.bind(to: target.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let targetRect = Rect(topLeftX: 700, topLeftY: 300, width: 500, height: 400)
        moving.lastAppliedLayoutPhysicalRect = targetRect
        moving.lastAppliedLayoutVirtualRect = targetRect

        await resume.signalToAll()
        try await layout.value

        #expect(moving.parent === target.rootTilingContainer)
        #expect(moving.lastAppliedLayoutPhysicalRect?.topLeftCorner == targetRect.topLeftCorner)
        #expect(moving.lastAppliedLayoutVirtualRect?.topLeftCorner == targetRect.topLeftCorner)
    }
}
