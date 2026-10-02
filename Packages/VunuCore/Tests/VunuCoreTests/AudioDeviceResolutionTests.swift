import XCTest
@testable import VunuCore

final class AudioDeviceResolutionTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 1, uid: "BuiltInMicrophoneDevice", modelUID: "imic", name: "MacBook Pro Microphone", transport: .builtIn, isInternalMic: true)
    private let jack = AudioInputDevice(id: 2, uid: "BuiltInHeadsetDevice", name: "External Microphone", transport: .builtIn, isInternalMic: false)
    private let usb = AudioInputDevice(id: 3, uid: "AppleUSBAudioEngine:Shure:MV7:1", modelUID: "MV7:Shure", name: "Shure MV7", transport: .usb)
    private let sony = AudioInputDevice(id: 4, uid: "AC-80-0A-11-22-33:input", name: "WH-1000XM5", transport: .bluetooth)
    private let iphone = AudioInputDevice(id: 5, uid: "continuity-iphone", name: "iPhone Microphone", transport: .continuity)
    private let krisp = AudioInputDevice(id: 6, uid: "krisp", name: "Krisp Microphone", transport: .virtual)
    private let aggregate = AudioInputDevice(id: 7, uid: "agg", name: "Aggregate Device", transport: .aggregate)

    private func pick(_ devices: [AudioInputDevice], default def: AudioInputDevice?, preferred: String? = nil, model: String? = nil, lidClosed: Bool = false) -> InputChoice? {
        AudioDevices.resolveInput(preferredUID: preferred, preferredModelUID: model, devices: devices, defaultID: def?.id, clamshellClosed: lidClosed)
    }

    func testBluetoothDefaultUsesBuiltInMic() {
        let c = pick([builtIn, sony], default: sony)
        XCTAssertEqual(c?.device, builtIn)
        XCTAssertEqual(c?.reason, .avoidedRemoteDefault)
    }

    func testContinuityDefaultUsesBuiltInMic() {
        XCTAssertEqual(pick([builtIn, iphone], default: iphone)?.device, builtIn)
    }

    func testLocalDefaultIsKept() {
        XCTAssertEqual(pick([builtIn, usb, sony], default: usb)?.device, usb)
        XCTAssertEqual(pick([builtIn, jack, sony], default: jack)?.device, jack)
    }

    func testVirtualDefaultIsRespected() {
        XCTAssertEqual(pick([builtIn, krisp, sony], default: krisp)?.device, krisp)
    }

    func testAggregateNeverChosenAutomatically() {
        XCTAssertEqual(pick([builtIn, aggregate], default: aggregate)?.device, builtIn)
    }

    func testExplicitBluetoothChoiceWins() {
        let c = pick([builtIn, sony], default: builtIn, preferred: sony.uid)
        XCTAssertEqual(c?.device, sony)
        XCTAssertEqual(c?.reason, .preferred)
    }

    func testMissingPreferredFallsBackToAutomatic() {
        XCTAssertEqual(pick([builtIn, sony], default: sony, preferred: "unplugged-usb")?.device, builtIn)
    }

    func testPreferredModelMatchesSameModelOnAnotherPort() {
        let moved = AudioInputDevice(id: 9, uid: "AppleUSBAudioEngine:Shure:MV7:2", modelUID: "MV7:Shure", name: "Shure MV7", transport: .usb)
        let c = pick([builtIn, moved], default: builtIn, preferred: usb.uid, model: usb.modelUID)
        XCTAssertEqual(c?.device, moved)
        XCTAssertEqual(c?.reason, .preferredModel)
    }

    func testLidClosedSkipsInternalMic() {
        XCTAssertEqual(pick([builtIn, usb, sony], default: builtIn, lidClosed: true)?.device, usb)
        XCTAssertEqual(pick([builtIn, sony], default: sony, lidClosed: true)?.device, sony)
        XCTAssertEqual(pick([builtIn, jack, sony], default: sony, lidClosed: true)?.device, jack)
    }

    func testOnlyBluetoothIsUsed() {
        XCTAssertEqual(pick([sony], default: sony)?.device, sony)
    }

    func testLastResortStillReturnsSomething() {
        // Lid closed and nothing else: the internal mic is all there is (the silence watchdog explains it).
        XCTAssertEqual(pick([builtIn], default: builtIn, lidClosed: true)?.device, builtIn)
        XCTAssertNil(pick([], default: nil))
    }

    func testRankPrefersInternalThenJackThenUSB() {
        XCTAssertEqual(pick([usb, jack, builtIn, sony], default: sony)?.device, builtIn)
        XCTAssertEqual(pick([usb, jack, sony], default: sony)?.device, jack)
    }
}
