@testable import AppBundle
import ApplicationServices
import Testing

struct AxMouseHitTest {
    @Test func testFinderDesktopWithWindowAttributeIsNotAWindow() {
        #expect(!isAxWindowHit(
            role: kAXGroupRole, subrole: "AXDesktop", parentWindowSubrole: "AXDesktop", hasParentWindow: true,
        ))
    }

    @Test func testControlWithDesktopWindowAttributeIsNotAWindow() {
        #expect(!isAxWindowHit(
            role: kAXButtonRole, subrole: nil, parentWindowSubrole: "AXDesktop", hasParentWindow: true,
        ))
    }

    @Test func testDesktopHitIsRejectedEvenWhenEnclosingSubroleIsUnavailable() {
        #expect(!isAxWindowHit(
            role: kAXGroupRole, subrole: "AXDesktop", parentWindowSubrole: nil, hasParentWindow: true,
        ))
    }

    @Test func testRealWindowWithoutWindowAttributeIsAWindow() {
        #expect(isAxWindowHit(
            role: kAXWindowRole, subrole: kAXStandardWindowSubrole, parentWindowSubrole: nil, hasParentWindow: false,
        ))
    }

    @Test func testControlWithRealWindowAttributeIsAWindow() {
        #expect(isAxWindowHit(
            role: kAXButtonRole, subrole: nil, parentWindowSubrole: kAXStandardWindowSubrole, hasParentWindow: true,
        ))
    }

    @Test func testOtherPopupAndMenuMetadataKeepsLegacyClassification() {
        #expect(isAxWindowHit(
            role: kAXMenuRole, subrole: nil, parentWindowSubrole: kAXFloatingWindowSubrole, hasParentWindow: true,
        ))
        #expect(isAxWindowHit(role: nil, subrole: nil, parentWindowSubrole: nil, hasParentWindow: true))
        #expect(!isAxWindowHit(role: kAXMenuRole, subrole: nil, parentWindowSubrole: nil, hasParentWindow: false))
    }
}
