import Foundation

// BMAP wire format independently implemented from protocol observations:
// https://github.com/bosefirmware/BoseConnect-Linux_based-connect
struct BoseFrame {
    let group: UInt8
    let command: UInt8
    let kind: UInt8
    let payload: [UInt8]
}

struct BoseProtocol {
    private var buffer: [UInt8] = []
    mutating func receive(_ bytes: [UInt8]) -> [BoseFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [BoseFrame] = []
        while buffer.count >= 4 {
            let size = 4 + Int(buffer[3])
            guard buffer.count >= size else { break }
            frames.append(BoseFrame(group: buffer[0], command: buffer[1], kind: buffer[2],
                                    payload: Array(buffer[4..<size])))
            buffer.removeFirst(size)
        }
        return frames
    }
    static func addresses(_ payload: [UInt8]) -> [[UInt8]]? {
        guard !payload.isEmpty, (payload.count - 1) % 6 == 0 else { return nil }
        return stride(from: 1, to: payload.count, by: 6).map { Array(payload[$0..<$0+6]) }
    }
    static func connect(_ address: [UInt8]) -> [UInt8]? {
        guard address.count == 6 else { return nil }
        return [4, 1, 5, 7, 0] + address
    }
    static func disconnect(_ address: [UInt8]) -> [UInt8]? {
        guard address.count == 6 else { return nil }
        return [4, 2, 5, 6] + address
    }
}

struct BoseSource {
    let address: [UInt8]
    let status: UInt8
    let name: String
    static func parse(_ payload: [UInt8]) -> BoseSource? {
        guard payload.count >= 9 else { return nil }
        let name = String(decoding: payload.dropFirst(9), as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters)
        let address = Array(payload.prefix(6))
        return BoseSource(address: address, status: payload[6],
                          name: name.isEmpty ? address.map { String(format: "%02X", $0) }.joined(separator: ":") : name)
    }
}
