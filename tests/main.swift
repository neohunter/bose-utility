import Foundation
func check(_ value: Bool, _ message: String) { precondition(value, message) }
let address: [UInt8] = [1, 2, 3, 4, 5, 6]
check(BoseProtocol.connect(address) == [4, 1, 5, 7, 0, 1, 2, 3, 4, 5, 6], "connect bytes")
check(BoseProtocol.disconnect(address) == [4, 2, 5, 6, 1, 2, 3, 4, 5, 6], "disconnect bytes")
check(BoseProtocol.connect([1]) == nil, "bad address")
check(BoseProtocol.addresses([]) == nil, "empty payload")
check(BoseProtocol.addresses([1, 2]) == nil, "truncated list")
check(BoseProtocol.addresses([0])?.isEmpty == true, "no devices")
check(BoseProtocol.addresses([3] + address + address)?.count == 2, "two addresses")
let payload = address + [UInt8(3), 0, 0] + Array("My Mac".utf8)
check(BoseSource.parse(payload)?.name == "My Mac", "name")
check(BoseSource.parse(payload)?.status == 3, "this Mac status")
check(BoseSource.parse([1,2]) == nil, "short info")
let wire = [UInt8(4), 5, 3, UInt8(payload.count)] + payload
for split in 0...wire.count {
    var parser = BoseProtocol()
    let frames = parser.receive(Array(wire.prefix(split))) + parser.receive(Array(wire.dropFirst(split)))
    check(frames.count == 1 && frames[0].payload == payload, "fragmented response")
}
var parser = BoseProtocol()
check(parser.receive(wire + wire).count == 2, "coalesced response")
print("Protocol checks passed")
