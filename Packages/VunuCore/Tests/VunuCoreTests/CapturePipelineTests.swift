import XCTest
@testable import VunuCore

final class CapturePipelineTests: XCTestCase {
    // MARK: SampleRing

    func testRingWrapsAround() {
        let ring = SampleRing(capacity: 8)
        var out = [Float](repeating: 0, count: 8)
        XCTAssertTrue(ring.write([1, 2, 3, 4, 5, 6], count: 6))
        XCTAssertEqual(ring.read(into: &out, max: 4), 4)
        XCTAssertEqual(Array(out[0..<4]), [1, 2, 3, 4])
        XCTAssertTrue(ring.write([7, 8, 9, 10, 11], count: 5))   // wraps past the end
        XCTAssertEqual(ring.available, 7)
        XCTAssertEqual(ring.read(into: &out, max: 8), 7)
        XCTAssertEqual(Array(out[0..<7]), [5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(ring.available, 0)
    }

    func testRingRefusesOverrunWithoutSplittingFrames() {
        let ring = SampleRing(capacity: 4)
        XCTAssertTrue(ring.write([1, 2, 3], count: 3))
        XCTAssertFalse(ring.write([4, 5], count: 2))   // only 1 free: nothing written
        var out = [Float](repeating: 0, count: 4)
        XCTAssertEqual(ring.read(into: &out, max: 4), 3)
        XCTAssertEqual(Array(out[0..<3]), [1, 2, 3])
    }

    // MARK: CaptureProcessor

    private func sine(frames: Int, rate: Double, freq: Double = 440, amp: Float = 0.3, channels: Int, silentChannel: Int? = nil) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let v = amp * Float(sin(2 * .pi * freq * Double(i) / rate))
            for c in 0..<channels { out[i * channels + c] = c == silentChannel ? 0 : v }
        }
        return out
    }

    private func run(_ p: CaptureProcessor, _ input: [Float], chunk: Int) -> [Float] {
        var out: [Float] = []
        var offset = 0
        input.withUnsafeBufferPointer { buf in
            while offset < input.count / p.channels {
                let n = min(chunk, input.count / p.channels - offset)
                out += p.process(interleaved: buf.baseAddress! + offset * p.channels, frames: n)
                offset += n
            }
        }
        return out + p.flush()
    }

    func testResamples48kTo16kAcrossBackToBackSessions() throws {
        for session in 0..<2 {
            let p = try XCTUnwrap(CaptureProcessor(hwRate: 48_000, channels: 1))
            let out = run(p, sine(frames: 48_000, rate: 48_000, channels: 1), chunk: 512)
            XCTAssertEqual(Double(out.count), 16_000, accuracy: 64, "session \(session)")
            let rms = sqrt(out.dropFirst(200).map { $0 * $0 }.reduce(0, +) / Float(out.count - 200))
            XCTAssertEqual(rms, 0.3 / sqrt(2), accuracy: 0.02, "session \(session)")
        }
    }

    func testFlushEndsProcessor() throws {
        let p = try XCTUnwrap(CaptureProcessor(hwRate: 44_100, channels: 1))
        _ = run(p, sine(frames: 4_410, rate: 44_100, channels: 1), chunk: 441)
        let more = sine(frames: 441, rate: 44_100, channels: 1)
        XCTAssertTrue(more.withUnsafeBufferPointer { p.process(interleaved: $0.baseAddress!, frames: 441) }.isEmpty)
    }

    func testStereoWithOneSilentChannelUsesTheLiveSide() throws {
        let p = try XCTUnwrap(CaptureProcessor(hwRate: 48_000, channels: 2))
        let out = run(p, sine(frames: 48_000, rate: 48_000, channels: 2, silentChannel: 0), chunk: 1024)
        XCTAssertEqual(p.channelMode, .only(1))
        // After the 0.5 s decision the level is the full sine, not half of it.
        let tail = out.suffix(4_000)
        let rms = sqrt(tail.map { $0 * $0 }.reduce(0, +) / Float(tail.count))
        XCTAssertEqual(rms, 0.3 / sqrt(2), accuracy: 0.02)
    }

    func testStereoWithBothChannelsAverages() throws {
        let p = try XCTUnwrap(CaptureProcessor(hwRate: 48_000, channels: 2))
        _ = run(p, sine(frames: 48_000, rate: 48_000, channels: 2), chunk: 1024)
        XCTAssertEqual(p.channelMode, .average)
    }

    func testDigitalSilenceIsDetectedAndSignalResetsIt() throws {
        let p = try XCTUnwrap(CaptureProcessor(hwRate: 48_000, channels: 1))
        let zeros = [Float](repeating: 0, count: 48_000 * 2)
        _ = zeros.withUnsafeBufferPointer { p.process(interleaved: $0.baseAddress!, frames: 48_000 * 2) }
        XCTAssertEqual(p.silentSeconds, 2, accuracy: 0.01)
        XCTAssertFalse(p.heardSignal)
        // A real (even very quiet) mic is never exactly zero for long.
        let quiet = sine(frames: 4_800, rate: 48_000, amp: 0.001, channels: 1)
        _ = quiet.withUnsafeBufferPointer { p.process(interleaved: $0.baseAddress!, frames: 4_800) }
        XCTAssertTrue(p.heardSignal)
        XCTAssertLessThan(p.silentSeconds, 0.05)
    }
}
