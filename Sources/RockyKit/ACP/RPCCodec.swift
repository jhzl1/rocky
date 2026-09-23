import Foundation

public enum RPCID: Sendable, Hashable {
    case int(Int)
    case string(String)

    var json: JSONValue {
        switch self {
        case .int(let value): .number(Double(value))
        case .string(let value): .string(value)
        }
    }

    init?(_ json: JSONValue?) {
        if let value = json?.intValue {
            self = .int(value)
        } else if let value = json?.stringValue {
            self = .string(value)
        } else {
            return nil
        }
    }
}

public enum RPCMessage: Sendable, Equatable {
    case request(id: RPCID, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: RPCID, result: JSONValue)
    case errorResponse(id: RPCID, code: Int, message: String)
}

public enum RPCCodecError: Error, Equatable {
    case notJSONRPC(String)
}

/// ACP frames are newline-delimited JSON-RPC 2.0 objects.
public enum RPCCodec {
    public static func encode(_ message: RPCMessage) throws -> Data {
        var object: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch message {
        case let .request(id, method, params):
            object["id"] = id.json
            object["method"] = .string(method)
            object["params"] = params
        case let .notification(method, params):
            object["method"] = .string(method)
            object["params"] = params
        case let .response(id, result):
            object["id"] = id.json
            object["result"] = result
        case let .errorResponse(id, code, message):
            object["id"] = id.json
            object["error"] = ["code": .number(Double(code)), "message": .string(message)]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: String) throws -> RPCMessage {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else {
            throw RPCCodecError.notJSONRPC(line)
        }
        let id = RPCID(object["id"])
        let params = object["params"] ?? .null
        if let method = object["method"]?.stringValue {
            if let id { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard let id else { throw RPCCodecError.notJSONRPC(line) }
        if let error = object["error"] {
            return .errorResponse(id: id, code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? "")
        }
        return .response(id: id, result: object["result"] ?? .null)
    }
}
