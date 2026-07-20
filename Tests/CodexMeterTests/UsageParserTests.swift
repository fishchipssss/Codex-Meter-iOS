import Foundation
import XCTest
@testable import CodexMeterCore

final class UsageParserTests: XCTestCase {
    func testParsesFiveHourAndWeeklyWindows() throws {
        let payload = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 32.4,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 5400,
              "reset_at": 1900000000
            },
            "secondary_window": {
              "used_percent": 71,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 86000,
              "reset_at": 1900100000
            }
          },
          "rate_limit_reset_credits": { "available_count": 2 }
        }
        """

        let snapshot = try UsageParser.parse(Data(payload.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 32)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 68)
        XCTAssertEqual(snapshot.weekly?.windowSeconds, 604_800)
        XCTAssertEqual(snapshot.resetCreditsAvailable, 2)
    }

    func testRejectsPayloadWithoutUsageWindows() {
        XCTAssertThrowsError(try UsageParser.parse(Data("{\"plan_type\":\"plus\"}".utf8)))
    }

    func testWeeklyOnlyPayloadDoesNotBecomeFiveHourWindow() throws {
        let payload = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 46,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 90000,
              "reset_at": 1900100000
            }
          }
        }
        """

        let snapshot = try UsageParser.parse(Data(payload.utf8))
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 54)
    }

    func testEffectiveFiveHourRejectsMissingLongAndDuplicateResets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = UsageWindow(
            usedPercent: 20, windowSeconds: 18_000, resetAfterSeconds: 3_600,
            resetAtEpochSeconds: Int(now.addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let tooLong = UsageWindow(
            usedPercent: 20, windowSeconds: 18_000, resetAfterSeconds: 18_001,
            resetAtEpochSeconds: Int(now.addingTimeInterval(18_001).timeIntervalSince1970)
        )
        let missingReset = UsageWindow(
            usedPercent: 20, windowSeconds: 18_000, resetAfterSeconds: 0, resetAtEpochSeconds: 0
        )

        func snapshot(fiveHour: UsageWindow, weeklyReset: Date? = nil) -> UsageSnapshot {
            let weekly = weeklyReset.map {
                UsageWindow(
                    usedPercent: 50, windowSeconds: 604_800, resetAfterSeconds: 3_600,
                    resetAtEpochSeconds: Int($0.timeIntervalSince1970)
                )
            }
            return UsageSnapshot(
                planType: "plus", allowed: true, limitReached: false,
                fiveHour: fiveHour, weekly: weekly, resetCreditsAvailable: nil, fetchedAt: now
            )
        }

        XCTAssertEqual(snapshot(fiveHour: valid).effectiveFiveHour(at: now), valid)
        XCTAssertNil(snapshot(fiveHour: tooLong).effectiveFiveHour(at: now))
        XCTAssertNil(snapshot(fiveHour: missingReset).effectiveFiveHour(at: now))
        XCTAssertNil(snapshot(fiveHour: valid, weeklyReset: valid.resetDate).effectiveFiveHour(at: now))
    }
}

final class UsageResetDetectorTests: XCTestCase {
    func testDetectsFiveHourAndWeeklyResetsBeforeExpectedTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = snapshot(
            fetchedAt: now, fiveUsed: 64, fiveReset: now.addingTimeInterval(4 * 3_600),
            weeklyUsed: 81, weeklyReset: now.addingTimeInterval(3 * 86_400)
        )
        let refreshedAt = now.addingTimeInterval(30 * 60)
        let current = snapshot(
            fetchedAt: refreshedAt, fiveUsed: 2, fiveReset: now.addingTimeInterval(5 * 3_600),
            weeklyUsed: 4, weeklyReset: now.addingTimeInterval(7 * 86_400)
        )

        XCTAssertEqual(
            UsageResetDetector.unexpectedResets(previous: previous, current: current),
            [.fiveHour, .weekly]
        )
    }

    func testIgnoresNormalResetAtReportedTimeAndSmallCorrections() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(30 * 60)
        let previous = snapshot(
            fetchedAt: now, fiveUsed: 60, fiveReset: reset,
            weeklyUsed: 70, weeklyReset: now.addingTimeInterval(3 * 86_400)
        )
        let afterScheduledReset = snapshot(
            fetchedAt: reset.addingTimeInterval(1), fiveUsed: 0, fiveReset: reset.addingTimeInterval(5 * 3_600),
            weeklyUsed: 65, weeklyReset: now.addingTimeInterval(3 * 86_400)
        )

        XCTAssertEqual(
            UsageResetDetector.unexpectedResets(previous: previous, current: afterScheduledReset),
            []
        )
    }

    private func snapshot(
        fetchedAt: Date,
        fiveUsed: Int,
        fiveReset: Date,
        weeklyUsed: Int,
        weeklyReset: Date
    ) -> UsageSnapshot {
        func window(used: Int, duration: Int, reset: Date) -> UsageWindow {
            UsageWindow(
                usedPercent: used,
                windowSeconds: duration,
                resetAfterSeconds: max(0, Int(reset.timeIntervalSince(fetchedAt))),
                resetAtEpochSeconds: Int(reset.timeIntervalSince1970)
            )
        }
        return UsageSnapshot(
            planType: "plus", allowed: true, limitReached: false,
            fiveHour: window(used: fiveUsed, duration: 18_000, reset: fiveReset),
            weekly: window(used: weeklyUsed, duration: 604_800, reset: weeklyReset),
            resetCreditsAvailable: nil, fetchedAt: fetchedAt
        )
    }
}

final class ProxyParserTests: XCTestCase {
    func testParsesSetupCode() throws {
        let code = "codexmeter://proxy/add?v=1&id=e675d48e-38c3-433f-aa40-c41a7699d544&name=Mac%20mini&url=https%3A%2F%2Fmini.example.ts.net%3A8443&token=abcdefghijklmnopqrstuvwxyz1234567890ABCDEFG"
        let setup = try ProxySetupCode(code)
        XCTAssertEqual(setup.name, "Mac mini")
        XCTAssertEqual(setup.baseURL.absoluteString, "https://mini.example.ts.net:8443")
    }

    func testRejectsInsecureSetupCode() {
        let code = "codexmeter://proxy/add?v=1&id=e675d48e-38c3-433f-aa40-c41a7699d544&url=http%3A%2F%2Fmini&token=abcdefghijklmnopqrstuvwxyz1234567890ABCDEFG"
        XCTAssertThrowsError(try ProxySetupCode(code))
    }

    func testParsesProxyWindowsAndCredits() throws {
        let payload = """
        {
          "schema_version": 1,
          "proxy": {"id":"e675d48e-38c3-433f-aa40-c41a7699d544","name":"Mini"},
          "account": {"type":"chatgpt","email":"person@example.com","plan_type":"plus"},
          "rate_limit": {
            "limit_id":"codex",
            "rate_limit_reached_type":null,
            "primary":{"used_percent":20,"window_duration_minutes":300,"resets_at":1900000000},
            "secondary":{"used_percent":70,"window_duration_minutes":10080,"resets_at":1900500000}
          },
          "reset_credits":{"available_count":1,"credits":[{"id":"credit","reset_type":"codexRateLimits","status":"available","granted_at":1800000000,"expires_at":1900000000,"title":"Reset","description":"Ready"}]},
          "fetched_at":"2026-07-13T21:00:00Z"
        }
        """
        let parsed = try ProxySnapshotParser.parse(Data(payload.utf8))
        XCTAssertEqual(parsed.email, "person@example.com")
        XCTAssertEqual(parsed.usage.fiveHour?.remainingPercent, 80)
        XCTAssertEqual(parsed.usage.weekly?.remainingPercent, 30)
        XCTAssertEqual(parsed.resetCredits.availableCount, 1)
    }
}
