import Foundation

public enum DNSMessageError: Error, Equatable {
    case truncated
    case malformedName
    case pointerLoop
    case unsupportedQuestionCount
}

public enum DNSRecordType: UInt16, Codable, Sendable {
    case a = 1
    case cname = 5
    case aaaa = 28
    case unknown = 0

    public init(raw: UInt16) {
        self = DNSRecordType(rawValue: raw) ?? .unknown
    }
}

public enum DNSRCode: UInt8, Codable, Sendable {
    case noError = 0
    case formErr = 1
    case servFail = 2
    case nxDomain = 3
    case notImp = 4
    case refused = 5
    case other = 255

    public init(raw: UInt8) {
        self = DNSRCode(rawValue: raw) ?? .other
    }
}

public struct DNSQuestion: Codable, Equatable, Sendable {
    public var name: String
    public var type: UInt16
    public var qclass: UInt16

    public var normalizedName: String {
        DNSMessage.normalizeName(name)
    }
}

public struct DNSAnswer: Codable, Equatable, Sendable {
    public var name: String
    public var type: DNSRecordType
    public var rawType: UInt16
    public var ttl: UInt32
    public var value: String
}

public struct DNSMessage: Equatable, Sendable {
    public var id: UInt16
    public var flags: UInt16
    public var question: DNSQuestion
    public var rcode: DNSRCode
    public var answers: [DNSAnswer]
    public var raw: Data

    public var hasAnswers: Bool {
        !answers.isEmpty
    }

    public var minimumAnswerTTL: UInt32? {
        answers.map(\.ttl).min()
    }

    public static func parse(_ data: Data) throws -> DNSMessage {
        var reader = DNSWireReader(data: data)
        let id = try reader.readUInt16()
        let flags = try reader.readUInt16()
        let qdCount = try reader.readUInt16()
        let anCount = try reader.readUInt16()
        _ = try reader.readUInt16()
        _ = try reader.readUInt16()

        guard qdCount == 1 else {
            throw DNSMessageError.unsupportedQuestionCount
        }

        let qname = try reader.readName()
        let qtype = try reader.readUInt16()
        let qclass = try reader.readUInt16()
        let question = DNSQuestion(name: qname, type: qtype, qclass: qclass)

        var answers: [DNSAnswer] = []
        for _ in 0..<anCount {
            let name = try reader.readName()
            let rawType = try reader.readUInt16()
            let recordClass = try reader.readUInt16()
            let ttl = try reader.readUInt32()
            let rdLength = Int(try reader.readUInt16())
            let rdataOffset = reader.offset
            let rdata = try reader.readData(count: rdLength)
            guard recordClass == 1 else { continue }

            let type = DNSRecordType(raw: rawType)
            let value: String
            switch type {
            case .a where rdata.count == 4:
                value = rdata.map(String.init).joined(separator: ".")
            case .aaaa where rdata.count == 16:
                value = stride(from: 0, to: 16, by: 2).map { idx in
                    String(format: "%02x%02x", rdata[idx], rdata[idx + 1])
                }.joined(separator: ":")
            case .cname:
                var nameReader = DNSWireReader(data: data, offset: rdataOffset)
                value = try nameReader.readName()
            default:
                value = rdata.map { String(format: "%02x", $0) }.joined()
            }
            answers.append(DNSAnswer(name: name, type: type, rawType: rawType, ttl: ttl, value: value))
        }

        return DNSMessage(
            id: id,
            flags: flags,
            question: question,
            rcode: DNSRCode(raw: UInt8(flags & 0x000F)),
            answers: answers,
            raw: data
        )
    }

    public static func normalizeName(_ name: String) -> String {
        var lower = name.lowercased()
        if lower.hasSuffix(".") {
            lower.removeLast()
        }
        return lower
    }

    public static func makeErrorResponse(for request: Data, rcode: DNSRCode) -> Data {
        guard request.count >= 12 else { return Data() }
        var response = Data()
        response.append(request[0])
        response.append(request[1])
        let code = UInt16(rcode.rawValue == DNSRCode.other.rawValue ? DNSRCode.servFail.rawValue : rcode.rawValue)
        let flags: UInt16 = 0x8000 | 0x0080 | code
        response.appendUInt16(flags)
        response.append(request[4..<6])
        response.appendUInt16(0)
        response.appendUInt16(0)
        response.appendUInt16(0)
        if request.count > 12 {
            response.append(request[12...])
        }
        return response
    }
}

struct DNSWireReader {
    let data: Data
    var offset: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw DNSMessageError.truncated
        }
        let out = data[offset..<(offset + count)]
        offset += count
        return Data(out)
    }

    mutating func readName() throws -> String {
        var labels: [String] = []
        var cursor = offset
        var jumped = false
        var seenPointers = Set<Int>()

        while true {
            guard cursor < data.count else { throw DNSMessageError.truncated }
            let length = data[cursor]
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < data.count else { throw DNSMessageError.truncated }
                let pointer = (Int(length & 0x3F) << 8) | Int(data[cursor + 1])
                guard !seenPointers.contains(pointer) else { throw DNSMessageError.pointerLoop }
                seenPointers.insert(pointer)
                if !jumped {
                    offset = cursor + 2
                    jumped = true
                }
                cursor = pointer
                continue
            }

            if length == 0 {
                if !jumped {
                    offset = cursor + 1
                }
                return labels.joined(separator: ".") + "."
            }

            guard length & 0xC0 == 0 else { throw DNSMessageError.malformedName }
            cursor += 1
            let end = cursor + Int(length)
            guard end <= data.count else { throw DNSMessageError.truncated }
            let labelData = data[cursor..<end]
            guard let label = String(data: labelData, encoding: .utf8) else {
                throw DNSMessageError.malformedName
            }
            labels.append(label)
            cursor = end
        }
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendQName(_ name: String) {
        let trimmed = DNSMessage.normalizeName(name)
        for label in trimmed.split(separator: ".") {
            let bytes = Array(label.utf8)
            append(UInt8(bytes.count))
            append(contentsOf: bytes)
        }
        append(0)
    }

    public static func makeQuery(id: UInt16 = 0x1234, name: String, type: UInt16 = 1) -> Data {
        var data = Data()
        data.appendUInt16(id)
        data.appendUInt16(0x0100)
        data.appendUInt16(1)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendQName(name)
        data.appendUInt16(type)
        data.appendUInt16(1)
        return data
    }
}
