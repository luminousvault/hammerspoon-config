//------------------------------------------------------------------------------
// ble-adv-watch.swift
//
// 특정 기기의 BLE 광고를 감시하는 CLI. bluetooth_device.lua 의 자동 재연결이
// hs.task 로 상시 실행하며, 매칭되는 광고를 볼 때마다 한 줄씩 출력합니다.
//
// 기기 식별: Shokz OpenFit 류 이어버드는 광고의 제조사 데이터 앞 6바이트에
// 자기 Classic MAC 주소를 역순(리틀엔디언)으로 싣습니다. BLE 주소는 macOS 가
// 숨기고(랜덤화) 로컬 이름은 충전 케이스도 같은 값을 쓰므로, 이 임베디드 MAC
// 이 유일하게 신뢰할 수 있는 식별 키입니다.
//
// 사용법
//   ble-adv-watch <mac> [--rssi <min>]
//     <mac>   : 기기 Classic MAC (c0:86:b3:a9:41:27 또는 c0-86-b3-a9-41-27)
//     --rssi  : 이 값(dBm) 미만의 약한 광고는 무시 (기본 -127 = 전부)
//
// 출력: 매칭 광고마다 "<unix epoch> <rssi>" 한 줄 (라인 버퍼드)
// 종료: 데몬처럼 계속 돌며, 호출자가 terminate 할 때까지 실행
//
// 빌드: swiftc -O -o helpers/ble-adv-watch helpers/ble-adv-watch.swift
//------------------------------------------------------------------------------

import CoreBluetooth
import Foundation

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(("ble-adv-watch: " + msg + "\n").data(using: .utf8)!)
  exit(1)
}

// 인자 파싱 ------------------------------------------------------------------

var macArg: String?
var minRSSI = -127
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
  let a = args.removeFirst()
  if a == "--rssi" {
    guard !args.isEmpty, let v = Int(args.removeFirst()) else { fail("--rssi needs an integer") }
    minRSSI = v
  } else if macArg == nil {
    macArg = a
  } else {
    fail("unexpected argument: " + a)
  }
}
guard let macStr = macArg else {
  fail("usage: ble-adv-watch <mac> [--rssi <min>]")
}

let macBytes = macStr.lowercased()
  .split(whereSeparator: { $0 == ":" || $0 == "-" })
  .compactMap { UInt8($0, radix: 16) }
guard macBytes.count == 6 else { fail("invalid MAC address: " + macStr) }

// 광고의 제조사 데이터 앞 6바이트는 MAC 역순
let needle = Data(macBytes.reversed())

// 스캔 ------------------------------------------------------------------------

final class Scanner: NSObject, CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      // 같은 광고를 반복 수신해야 "재등장"을 제때 알 수 있으므로 중복 허용
      central.scanForPeripherals(withServices: nil,
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    case .unauthorized:
      fail("Bluetooth permission denied for the responsible app (check System Settings > Privacy > Bluetooth)")
    case .poweredOff:
      fail("Bluetooth is powered off")
    case .unsupported:
      fail("BLE unsupported on this machine")
    default:
      break   // resetting / unknown 은 다음 상태 변화를 기다림
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    guard let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
          mfr.count >= 6, mfr.prefix(6) == needle,
          RSSI.intValue >= minRSSI, RSSI.intValue < 0   // 127 = 유효하지 않은 RSSI
    else { return }
    print("\(Int(Date().timeIntervalSince1970)) \(RSSI.intValue)")
    fflush(stdout)
  }
}

setvbuf(stdout, nil, _IOLBF, 0)
let scanner = Scanner()
let central = CBCentralManager(delegate: scanner, queue: nil)
RunLoop.main.run()
