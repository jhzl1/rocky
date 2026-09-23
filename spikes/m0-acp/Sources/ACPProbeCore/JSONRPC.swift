import Foundation

public typealias JSONObject = [String: Any]

public enum JSONRPCMessage {
    case response(id: Int, result: JSONObject?, error: JSONObject?)
    case request(id: Any, method: String, params: JSONObject)
    case notification(method: String, params: JSONObject)
}

public enum JSONRPCError: Error {
    case invalidLine(String)
}

/// ACP frames are newline-delimited JSON-RPC 2.0 objects.
public enum JSONRPC {
    public static func encodeRequest(id: Int, method: String, params: JSONObject) throws -> Data {
        try line(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    public static func encodeResponse(id: Any, result: JSONObject) throws -> Data {
        try line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    public static func decode(_ line: String) throws -> JSONRPCMessage {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            throw JSONRPCError.invalidLine(line)
        }
        let method = object["method"] as? String
        let params = object["params"] as? JSONObject ?? [:]
        switch (object["id"], method) {
        case let (id?, method?):
            return .request(id: id, method: method, params: params)
        case let (nil, method?):
            return .notification(method: method, params: params)
        case let (id as Int, nil):
            return .response(id: id, result: object["result"] as? JSONObject, error: object["error"] as? JSONObject)
        default:
            throw JSONRPCError.invalidLine(line)
        }
    }

    private static func line(_ object: JSONObject) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
