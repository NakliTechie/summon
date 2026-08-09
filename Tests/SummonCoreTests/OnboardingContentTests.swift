import XCTest
@testable import SummonCore

final class OnboardingContentTests: XCTestCase {
    func testScriptIsFourStepsEndingOnSetup() {
        XCTAssertEqual(OnboardingScript.steps.count, 4)
        XCTAssertEqual(OnboardingScript.steps.last?.visual, .setup)
        XCTAssertEqual(OnboardingScript.steps.first?.visual, .launcher)
        XCTAssertEqual(OnboardingScript.steps.map(\.visual), [.launcher, .answer, .actions, .setup])
        for step in OnboardingScript.steps {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.subtitle.isEmpty)
        }
    }

    func testSeenKeyStable() {
        XCTAssertEqual(OnboardingScript.seenKey, "onboarding.intro.seen")
    }

    func testPhaseStatusTextAndFlags() {
        XCTAssertTrue(WebSearchInstaller.Phase.detecting.isRunning)
        XCTAssertTrue(WebSearchInstaller.Phase.installingRuntime.isRunning)
        XCTAssertFalse(WebSearchInstaller.Phase.enabled(baseURL: "x").isRunning)

        XCTAssertTrue(WebSearchInstaller.Phase.failed(reason: "boom").isError)
        XCTAssertTrue(WebSearchInstaller.Phase.needsRuntime(hint: "install it").isError)
        XCTAssertFalse(WebSearchInstaller.Phase.enabled(baseURL: "x").isError)

        XCTAssertEqual(WebSearchInstaller.Phase.enabled(baseURL: "x").statusText, "Web search is ready.")
        XCTAssertEqual(WebSearchInstaller.Phase.failed(reason: "boom").statusText, "boom")
        XCTAssertEqual(WebSearchInstaller.Phase.needsRuntime(hint: "install it").statusText, "install it")
        XCTAssertFalse(WebSearchInstaller.Phase.detecting.statusText.isEmpty)
    }
}
