// 入力デバイスの接続方式。診断ログの transport= と設定画面のマイク一覧で同じ分類を使う。

import CoreAudio
import Foundation
import Testing
import VoxCore

@Suite("Audio: 入力デバイスの接続方式")
struct AudioTransportTests {
  @Test("CoreAudio の transport type が診断ログのラベルになる")
  func knownTransportTypesBecomeLogLabels() {
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeBuiltIn).logLabel == "builtin",
      "built-in transport was not labelled")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeBluetooth).logLabel == "bluetooth",
      "bluetooth transport was not labelled")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeBluetoothLE).logLabel == "bluetoothle",
      "bluetooth LE transport was not labelled")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeUSB).logLabel == "usb",
      "usb transport was not labelled")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeAggregate).logLabel == "aggregate",
      "aggregate transport was not labelled")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeVirtual).logLabel == "virtual",
      "virtual transport was not labelled")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeUnknown).logLabel == "unknown",
      "the CoreAudio unknown transport was not labelled")
  }

  @Test("分類していない transport type は数値のまま出す")
  func unclassifiedTransportTypesKeepTheirNumber() {
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeHDMI)
        == .other(kAudioDeviceTransportTypeHDMI),
      "an unclassified transport was folded into a known case")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeHDMI).logLabel
        == String(kAudioDeviceTransportTypeHDMI),
      "an unclassified transport did not fall back to its number")
  }

  @Test("設定画面に出す分類は、利用者が見分けられる接続方式だけ")
  func onlyRecognisableTransportsAreShownInSettings() {
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeBuiltIn).displayLabel == "内蔵",
      "the built-in microphone had no label for the settings list")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeBluetooth).displayLabel == "Bluetooth",
      "the bluetooth microphone had no label for the settings list")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeUSB).displayLabel == "USB",
      "the usb microphone had no label for the settings list")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeUnknown).displayLabel == nil,
      "an unknown transport invented a label for the settings list")
    #expect(
      AudioTransport(rawValue: kAudioDeviceTransportTypeHDMI).displayLabel == nil,
      "an unclassified transport invented a label for the settings list")
  }
}
