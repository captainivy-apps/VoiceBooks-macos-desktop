import XCTest
@testable import VoiceBooks

final class PlaybackHeadWaitPolicyTests: XCTestCase {
    func testScalesWithDuration() {
        XCTAssertEqual(PlaybackHeadWaitPolicy.expectedTimeoutMs(framesToPlay: 22_050, sampleRate: 22_050), 2_000)
    }

    func testMinimumForZeroFrames() {
        XCTAssertEqual(PlaybackHeadWaitPolicy.expectedTimeoutMs(framesToPlay: 0, sampleRate: 22_050), PlaybackHeadWaitPolicy.minTimeoutMs)
    }

    func testCapsAtMaximum() {
        XCTAssertEqual(PlaybackHeadWaitPolicy.expectedTimeoutMs(framesToPlay: 10_000_000, sampleRate: 22_050), PlaybackHeadWaitPolicy.maxTimeoutMs)
    }

    func testLongSentenceWithinCap() {
        let timeout = PlaybackHeadWaitPolicy.expectedTimeoutMs(framesToPlay: 154_350, sampleRate: 22_050)
        XCTAssertGreaterThan(timeout, 10_000)
        XCTAssertLessThanOrEqual(timeout, PlaybackHeadWaitPolicy.maxTimeoutMs)
    }
}

final class SentencePlaybackPositionTests: XCTestCase {
    func testFalseWhenPositionZero() {
        XCTAssertFalse(SentencePlaybackPosition.isSentencePositionAtEnd(0, 5000))
    }

    func testFalseWhenDurationZero() {
        XCTAssertFalse(SentencePlaybackPosition.isSentencePositionAtEnd(1000, 0))
    }

    func testFalseWhenMidSentence() {
        XCTAssertFalse(SentencePlaybackPosition.isSentencePositionAtEnd(2500, 5000))
    }

    func testTrueAtExactEnd() {
        XCTAssertTrue(SentencePlaybackPosition.isSentencePositionAtEnd(5000, 5000))
    }

    func testTrueWithinTolerance() {
        XCTAssertTrue(SentencePlaybackPosition.isSentencePositionAtEnd(4950, 5000))
    }

    func testFalseJustOutsideTolerance() {
        XCTAssertFalse(SentencePlaybackPosition.isSentencePositionAtEnd(4849, 5000, tolerance: 100))
    }

    func testTrueWhenPastDuration() {
        XCTAssertTrue(SentencePlaybackPosition.isSentencePositionAtEnd(5200, 5000))
    }

    func testKeepsMidSentencePosition() {
        XCTAssertEqual(SentencePlaybackPosition.sanitizePositionForSentence(2300, durationMs: 5000), 2300)
    }

    func testKeepsNearEndPosition() {
        XCTAssertEqual(SentencePlaybackPosition.sanitizePositionForSentence(4950, durationMs: 5000), 4950)
    }

    func testResetsCrossSentenceCorruption() {
        XCTAssertEqual(SentencePlaybackPosition.sanitizePositionForSentence(6200, durationMs: 5000, tolerance: 100), 0)
    }

    func testKeepsSlightlyOverDurationWithinTolerance() {
        XCTAssertEqual(SentencePlaybackPosition.sanitizePositionForSentence(5050, durationMs: 5000, tolerance: 100), 5050)
    }

    func testKeepsUnknownDuration() {
        XCTAssertEqual(SentencePlaybackPosition.sanitizePositionForSentence(1800, durationMs: nil), 1800)
    }
}

final class PlaybackTransitionGuardsTests: XCTestCase {
    func testSkipWhenResumed() {
        XCTAssertTrue(PlaybackTransitionGuards.shouldSkipPauseFinalize(isPlaying: true, pauseSessionAtStart: 5, currentSession: 5))
    }

    func testSkipWhenSessionAdvanced() {
        XCTAssertTrue(PlaybackTransitionGuards.shouldSkipPauseFinalize(isPlaying: false, pauseSessionAtStart: 5, currentSession: 7))
    }

    func testDoNotSkipWhenStillPaused() {
        XCTAssertFalse(PlaybackTransitionGuards.shouldSkipPauseFinalize(isPlaying: false, pauseSessionAtStart: 5, currentSession: 5))
    }
}
