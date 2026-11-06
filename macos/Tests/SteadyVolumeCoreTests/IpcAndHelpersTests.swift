import XCTest
@testable import SteadyVolumeCore

final class IpcTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRequestRoundTripsThroughASocket() throws {
        let (a, b) = try UnixSocket.pair()
        try IpcFraming.write(IpcRequest(command: .lock, password: "pw", level: 42), to: a)
        let read = try IpcFraming.read(IpcRequest.self, from: b)
        XCTAssertEqual(read.command, .lock)
        XCTAssertEqual(read.level, 42)
        XCTAssertEqual(read.password, "pw")
    }

    func testWireFormatIsLittleEndianLengthPlusCamelCaseJson() throws {
        let frame = try IpcFraming.frame(IpcRequest(command: .changePassword, newPassword: "x"))
        let length = Int(frame[0]) | Int(frame[1]) << 8 | Int(frame[2]) << 16 | Int(frame[3]) << 24
        XCTAssertEqual(length, frame.count - 4)
        let body = try json(frame.dropFirst(4))
        XCTAssertEqual(body["command"] as? String, "changePassword")
        XCTAssertEqual(body["protocolVersion"] as? Int, 1)
        XCTAssertEqual(body["newPassword"] as? String, "x")
        XCTAssertNil(body["password"]) // nils omitted
    }

    func testLockAtCurrentLevelsIsALockRequestWithoutALevel() throws {
        let body = try json(IpcFraming.payload(IpcRequest(command: .lock, password: "pw")))
        XCTAssertEqual(body["command"] as? String, "lock")
        XCTAssertNil(body["level"])
    }

    func testErrorCodesAndModesSerialiseAsCamelCaseStrings() throws {
        let body = try json(IpcFraming.payload(IpcResponse.failure(.lockedOut, "wait")))
        XCTAssertEqual(body["error"] as? String, "lockedOut")
        XCTAssertEqual(try json(IpcFraming.payload(IpcResponse.failure(.internal, "x")))["error"] as? String, "internal")

        let status = StatusInfo(locked: true, mode: .currentLevels, level: 50,
                                devices: [DeviceStatus(id: "a", name: nil, level: 40)],
                                passwordSet: true, protected: true, serviceVersion: "1.0.0")
        let statusBody = try XCTUnwrap(json(IpcFraming.payload(IpcResponse.success(status)))["status"] as? [String: Any])
        XCTAssertEqual(statusBody["mode"] as? String, "currentLevels")
        XCTAssertEqual(statusBody["passwordSet"] as? Bool, true)
        XCTAssertEqual(statusBody["protected"] as? Bool, true)
    }

    /// Exactly what the Windows service sends (System.Text.Json, camelCase, nulls omitted).
    func testDecodesAWindowsResponse() throws {
        let text = #"""
        {"ok":true,"error":"none","message":"Locked 1 output device(s) at their current levels. Nothing was changed.",
         "status":{"locked":true,"mode":"currentLevels","level":50,
         "devices":[{"name":"Speakers","id":"{0.0.0.00000000}.{abc}","level":50}],
         "passwordSet":true,"protected":true,"serviceVersion":"1.0.0"}}
        """#
        let response = try IpcFraming.decode(IpcResponse.self, payload: Data(text.utf8))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.status?.mode, .currentLevels)
        XCTAssertEqual(response.status?.devices?.first?.level, 50)

        let refused = try IpcFraming.decode(IpcResponse.self,
                                            payload: Data(#"{"ok":false,"error":"wrongPassword","message":"Wrong password.","attemptsRemaining":4}"#.utf8))
        XCTAssertEqual(refused.error, .wrongPassword)
        XCTAssertEqual(refused.attemptsRemaining, 4)
    }

    func testDecodesAWindowsRequest() throws {
        let request = try IpcFraming.decode(IpcRequest.self,
                                            payload: Data(#"{"protocolVersion":1,"command":"unprotect","password":"pw"}"#.utf8))
        XCTAssertEqual(request, IpcRequest(command: .unprotect, password: "pw"))
    }

    func testInvalidLengthPrefixIsRejected() {
        for length: Int32 in [0, -1, Int32(IpcFraming.maxMessageBytes + 1)] {
            var le = length.littleEndian
            XCTAssertThrowsError(try IpcFraming.payloadLength(header: Data(bytes: &le, count: 4)), "\(length)")
        }
    }

    func testTruncatedMessageIsRejected() throws {
        let (a, b) = try UnixSocket.pair()
        let frame = try IpcFraming.frame(IpcRequest(command: .status))
        try a.writeAll(frame.dropLast(3))
        a.close()
        XCTAssertThrowsError(try IpcFraming.read(IpcRequest.self, from: b))
    }

    func testReadIfAnyReturnsNilWhenThePeerSendsNothing() throws {
        // steadyvol status connects only to read the daemon's PID, then closes.
        let (a, b) = try UnixSocket.pair()
        a.close()
        XCTAssertNil(try IpcFraming.readIfAny(IpcRequest.self, from: b))
        XCTAssertThrowsError(try IpcFraming.read(IpcRequest.self, from: b))
    }

    func testReadIfAnyStillRejectsATruncatedMessage() throws {
        let (a, b) = try UnixSocket.pair()
        let frame = try IpcFraming.frame(IpcRequest(command: .status))
        try a.writeAll(frame.dropLast(3))
        a.close()
        XCTAssertThrowsError(try IpcFraming.readIfAny(IpcRequest.self, from: b))
    }

    func testReadIfAnyReadsAWholeMessage() throws {
        let (a, b) = try UnixSocket.pair()
        try IpcFraming.write(IpcRequest(command: .status), to: a)
        XCTAssertEqual(try IpcFraming.readIfAny(IpcRequest.self, from: b), IpcRequest(command: .status))
    }

    func testMalformedJsonAndNumericEnumsAreRejected() {
        for body in ["{nope", #"{"command": 2}"#, #"{"command": "explode"}"#, #"{}"#] {
            XCTAssertThrowsError(try IpcFraming.decode(IpcRequest.self, payload: Data(body.utf8)), body)
        }
    }

    func testMissingProtocolVersionDefaultsToOne() throws {
        let request = try IpcFraming.decode(IpcRequest.self, payload: Data(#"{"command":"status"}"#.utf8))
        XCTAssertEqual(request.protocolVersion, 1)
    }

    func testPeerIdentityIsReadable() throws {
        let (a, b) = try UnixSocket.pair()
        XCTAssertEqual(try a.peerUID(), getuid())
        XCTAssertEqual(try a.peerPID(), getpid())
        withExtendedLifetime(b) {}
    }

    func testListenRefusesToReplaceSomethingThatIsNotASocket() throws {
        let path = NSTemporaryDirectory() + "sv-not-a-socket-\(getpid())"
        try "x".write(toFile: path, atomically: false, encoding: .utf8)
        defer { unlink(path) }
        XCTAssertThrowsError(try UnixSocket.listen(path: path, mode: 0o666))
    }

    func testListenConnectAndModeAndStaleSocketCleanup() throws {
        let path = "/tmp/sv-test-\(getpid()).sock"
        defer { unlink(path) }
        _ = try UnixSocket.listen(path: path, mode: 0o666) // leaves a stale socket file behind
        let server = try UnixSocket.listen(path: path, mode: 0o666)
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o666)

        let done = expectation(description: "served")
        DispatchQueue.global().async {
            let client = try! server.accept()!
            let request = try! IpcFraming.read(IpcRequest.self, from: client)
            try! IpcFraming.write(IpcResponse.failure(.badRequest, "echo \(request.command.rawValue)"), to: client)
            done.fulfill()
        }
        let client = try UnixSocket.connect(path: path, timeout: 5)
        try IpcFraming.write(IpcRequest(command: .status), to: client)
        XCTAssertEqual(try IpcFraming.read(IpcResponse.self, from: client).message, "echo status")
        wait(for: [done], timeout: 5)
    }
}

final class HelperTests: XCTestCase {
    func testEveryWholePercentSurvivesARoundTrip() {
        for p in 0...100 { XCTAssertEqual(VolumeMath.toPercent(VolumeMath.toScalar(p)), p) }
    }

    func testScalarsRoundToWholePercents() {
        let cases: [(Float32, Int)] = [(0, 0), (0.004, 0), (0.0051, 1), (0.4998, 50), (0.5625, 56), (0.999, 100),
                                       (1, 100), (-0.5, 0), (1.5, 100), (.nan, 0)]
        for (scalar, expected) in cases { XCTAssertEqual(VolumeMath.toPercent(scalar), expected, "\(scalar)") }
    }

    func testTinyFloatNoiseDoesNotChangeThePercent() {
        let base = VolumeMath.toScalar(37)
        XCTAssertEqual(VolumeMath.toPercent(base.nextUp), 37)
        XCTAssertEqual(VolumeMath.toPercent(base.nextDown), 37)
    }

    func testValidLevels() {
        XCTAssertFalse(VolumeMath.isValidLevel(-1))
        XCTAssertFalse(VolumeMath.isValidLevel(101))
        XCTAssertTrue(VolumeMath.isValidLevel(0))
        XCTAssertTrue(VolumeMath.isValidLevel(100))
    }

    func testFirstRevertIsReportedAndBurstsAreSummarised() {
        let clock = TestClock()
        let throttle = RevertLogThrottle(window: 10, now: clock.provider)
        XCTAssertEqual(throttle.register("speakers"), 1)
        for _ in 0..<50 { XCTAssertNil(throttle.register("speakers")) }
        XCTAssertTrue(throttle.drainExpired().isEmpty)
        clock.advance(10)
        let drained = throttle.drainExpired()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.key, "speakers")
        XCTAssertEqual(drained.first?.count, 50)
    }

    func testThrottleKeysAreIndependent() {
        let throttle = RevertLogThrottle(window: 10, now: TestClock().provider)
        XCTAssertEqual(throttle.register("speakers"), 1)
        XCTAssertEqual(throttle.register("headphones"), 1)
    }

    func testARevertAfterTheWindowIncludesSuppressedCount() {
        let clock = TestClock()
        let throttle = RevertLogThrottle(window: 10, now: clock.provider)
        _ = throttle.register("speakers")
        _ = throttle.register("speakers")
        _ = throttle.register("speakers")
        clock.advance(11)
        XCTAssertEqual(throttle.register("speakers"), 3)
    }
}

final class EnforcementTargetTests: XCTestCase {
    func testUnlockedConfigHasNoTarget() {
        XCTAssertNil(EnforcementTarget.from(SteadyVolumeConfig()))
    }

    func testUniformTargetGivesEveryDeviceTheSameLevelAndAdoptsNothing() throws {
        var config = SteadyVolumeConfig()
        config.locked = true
        config.level = 35
        let target = try XCTUnwrap(EnforcementTarget.from(config))
        XCTAssertEqual(target.scalar(for: "any"), 0.35)
        XCTAssertFalse(target.captureNewDevices)
    }

    func testCurrentLevelsTargetGivesEachDeviceItsOwnExactLevel() throws {
        var config = SteadyVolumeConfig()
        config.locked = true
        config.mode = .currentLevels
        config.deviceLevels = [DeviceLevel(id: "a", name: nil, scalar: 0.4998), DeviceLevel(id: "b", name: nil, scalar: 1)]
        let target = try XCTUnwrap(EnforcementTarget.from(config))
        XCTAssertEqual(target.scalar(for: "a"), 0.4998)
        XCTAssertEqual(target.scalar(for: "b"), 1)
        XCTAssertNil(target.scalar(for: "c"))
        XCTAssertTrue(target.captureNewDevices)
    }

    func testTargetIsASnapshotOfTheConfig() throws {
        var config = SteadyVolumeConfig()
        config.locked = true
        config.mode = .currentLevels
        config.deviceLevels = [DeviceLevel(id: "a", name: nil, scalar: 0.2)]
        let target = try XCTUnwrap(EnforcementTarget.from(config))
        config.deviceLevels[0].scalar = 0.9
        XCTAssertEqual(target.scalar(for: "a"), 0.2)
    }
}
