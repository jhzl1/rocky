import Foundation
import Testing
@testable import RockyKit

struct RPCCodecTests {
    @Test func encodesRequestAsOneSortedNewlineTerminatedLine() throws {
        let data = try RPCCodec.encode(.request(id: .int(1), method: "initialize", params: ["protocolVersion": 1]))
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":1}}"# + "\n")
    }

    @Test func encodesResponseKeepingStringID() throws {
        let data = try RPCCodec.encode(.response(id: .string("p1"), result: ["ok": true]))
        #expect(String(decoding: data, as: UTF8.self) == #"{"id":"p1","jsonrpc":"2.0","result":{"ok":true}}"# + "\n")
    }

    @Test func decodesResponse() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s1"}}"#)
        #expect(message == .response(id: .int(3), result: ["sessionId": "s1"]))
    }

    @Test func decodesErrorResponse() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"Authentication required"}}"#)
        #expect(message == .errorResponse(id: .int(4), code: -32000, message: "Authentication required"))
    }

    @Test func decodesNotification() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1"}}"#)
        #expect(message == .notification(method: "session/update", params: ["sessionId": "s1"]))
    }

    @Test func decodesAgentToClientRequestWithStringID() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{}}"#)
        #expect(message == .request(id: .string("perm-1"), method: "session/request_permission", params: [:]))
    }

    @Test func decodesNullResultAsNull() throws {
        #expect(try RPCCodec.decode(#"{"jsonrpc":"2.0","id":5,"result":null}"#) == .response(id: .int(5), result: .null))
    }

    @Test func keepsBooleansAsBooleans() throws {
        let message = try RPCCodec.decode(#"{"jsonrpc":"2.0","id":6,"result":{"loadSession":true}}"#)
        #expect(message == .response(id: .int(6), result: ["loadSession": .bool(true)]))
    }

    @Test(arguments: ["Loading config...", "", #"{"jsonrpc":"2.0"}"#, "[1,2]"])
    func rejectsLinesThatAreNotJSONRPC(line: String) {
        #expect(throws: RPCCodecError.self) { try RPCCodec.decode(line) }
    }
}
