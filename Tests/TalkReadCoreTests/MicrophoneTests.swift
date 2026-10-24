import XCTest
@testable import TalkReadCore

/// Device choice with an injected device list, plus a headless listing of this Mac's inputs. Nothing records.
final class MicrophoneTests: XCTestCase {
    private let builtIn = InputDevice(uid: "BuiltInMic", name: "MacBook Pro Microphone", isDefault: true)
    private let usb = InputDevice(uid: "UsbMic", name: "Shure MV7", isDefault: false)

    func testNilFollowsTheSystemDefault() {
        let r = Microphone.resolve(nil, in: [builtIn, usb])
        XCTAssertNil(r.device); XCTAssertNil(r.notice)
    }

    func testSavedDeviceIsSelected() {
        let r = Microphone.resolve("UsbMic", in: [builtIn, usb])
        XCTAssertEqual(r.device, usb); XCTAssertNil(r.notice)
    }

    func testMissingDeviceFallsBackToTheDefaultWithANotice() {
        let r = Microphone.resolve("UsbMic", in: [builtIn])
        XCTAssertNil(r.device, "the system default is used")
        XCTAssertEqual(r.notice, "Mic not found, using MacBook Pro Microphone")
        XCTAssertEqual(Microphone.resolve("UsbMic", in: []).notice, "Mic not found, using the system default")
    }

    func testDefaultLabel() {
        XCTAssertEqual(Microphone.defaultLabel([usb, builtIn]), "System default (MacBook Pro Microphone)")
        XCTAssertEqual(Microphone.defaultLabel([]), "System default")
    }

    func testThisMacHasAnInputAndResolvesItsUID() throws {
        let inputs = Microphone.inputs()
        let first = try XCTUnwrap(inputs.first, "no input device on this Mac")
        XCTAssertEqual(Set(inputs.map(\.uid)).count, inputs.count, "UIDs are unique")
        XCTAssertNotNil(Microphone.deviceID(uid: first.uid))
        XCTAssertNil(Microphone.deviceID(uid: "no-such-device"))
        XCTAssertLessThanOrEqual(inputs.filter(\.isDefault).count, 1)
    }

    func testSettingRoundTripsAndIsTolerant() throws {
        var s = Settings()
        XCTAssertNil(s.dictationMicrophone)
        s.dictationMicrophone = "UsbMic"
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).dictationMicrophone, "UsbMic")
        XCTAssertNil(try JSONDecoder().decode(Settings.self, from: Data(#"{"voiceID":"bf_emma"}"#.utf8)).dictationMicrophone)
        XCTAssertNil(try JSONDecoder().decode(Settings.self, from: Data(#"{"dictationMicrophone":7}"#.utf8)).dictationMicrophone)
        s.dictationMicrophone = ""
        XCTAssertNil(s.validated().dictationMicrophone)
        XCTAssertThrowsError(try s.set("dictationMicrophone", to: "UsbMic"))
    }
}
