import Foundation

/// iAP2 车机配置消息（0x1D00）。
///
/// 配对与认证完成后，把驾驶位、外观、显示尺寸、编码、图标大小等
/// 车机能力一次性告知 iPhone；这些值全部来自设置页。
enum IAP2Configuration {
    static let messageID: UInt16 = 0x1D00

    private enum Parameter: UInt16 {
        case vehicleName = 0x01
        case nightMode = 0x02
        case drivingSide = 0x03
        case displaySize = 0x04
        case videoCodec = 0x05
        case iconSize = 0x06
        case frameRate = 0x07
        case aspectRatio = 0x08
        case vehicleButton = 0x09
        case soundOutput = 0x0A
    }

    private static func text(_ value: String) -> Data { Data(value.utf8) }
    private static func byte(_ value: Int) -> Data { Data([UInt8(value & 0xFF)]) }

    static func message() -> IAP2Message {
        let parameters: [IAP2Parameter] = [
            .init(id: Parameter.vehicleName.rawValue, value: text(CarPlayConfiguration.vehicleName)),
            .init(id: Parameter.nightMode.rawValue, value: byte(CarPlayConfiguration.nightMode)),
            .init(id: Parameter.drivingSide.rawValue,
                  value: text(CarPlayConfiguration.rightHandDrive ? "right" : "left")),
            .init(id: Parameter.displaySize.rawValue,
                  value: text("\(CarPlayConfiguration.displayWidth)x\(CarPlayConfiguration.displayHeight)")),
            .init(id: Parameter.videoCodec.rawValue, value: text(CarPlayConfiguration.codecName)),
            .init(id: Parameter.iconSize.rawValue, value: text("\(CarPlayConfiguration.iconMillimeters)")),
            .init(id: Parameter.frameRate.rawValue, value: text("\(CarPlayConfiguration.fps)")),
            .init(id: Parameter.aspectRatio.rawValue, value: text(CarPlayConfiguration.aspectRatioText)),
            .init(id: Parameter.vehicleButton.rawValue,
                  value: byte(CarPlayConfiguration.showVehicleButton ? 1 : 0)),
            .init(id: Parameter.soundOutput.rawValue,
                  value: text(CarPlayConfiguration.audioOverWiFi ? "wifi" : "iphone")),
        ]
        return IAP2Message(id: messageID, parameters: parameters)
    }

    static func summary() -> String {
        let data = message().encoded()
        return "0x1D00 车机配置已构造（\(data.count)B，\(CarPlayConfiguration.codecName) / \(CarPlayConfiguration.displayWidth)×\(CarPlayConfiguration.displayHeight) / \(CarPlayConfiguration.aspectRatioText)）"
    }
}
