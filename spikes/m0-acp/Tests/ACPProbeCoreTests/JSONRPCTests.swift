import ACPProbeCore

func runJSONRPCTests() {
    test("testEncodeRequestIsOneNewlineTerminatedJSONLine") {
        let data = try JSONRPC.encodeRequest(id: 1, method: "initialize", params: ["protocolVersion": 1])
        let text = String(decoding: data, as: UTF8.self)
        check(text == #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":1}}"# + "\n", "encoded request does not match expected JSON")
    }

    test("testEncodeResponseKeepsStringID") {
        let data = try JSONRPC.encodeResponse(id: "p1", result: ["ok": true])
        let text = String(decoding: data, as: UTF8.self)
        check(text == #"{"id":"p1","jsonrpc":"2.0","result":{"ok":true}}"# + "\n", "encoded response does not match expected JSON")
    }

    test("testDecodeResponse") {
        let message = try JSONRPC.decode(#"{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s1"}}"#)
        guard case let .response(id, result, error) = message else {
            check(false, "expected response, got \(message)")
            return
        }
        check(id == 3, "response id should be 3")
        check(result?["sessionId"] as? String == "s1", "response result sessionId should be s1")
        check(error == nil, "response error should be nil")
    }

    test("testDecodeErrorResponse") {
        let message = try JSONRPC.decode(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"auth required"}}"#)
        guard case let .response(id, _, error) = message else {
            check(false, "expected response, got \(message)")
            return
        }
        check(id == 4, "error response id should be 4")
        check(error?["message"] as? String == "auth required", "error message should be 'auth required'")
    }

    test("testDecodeNotification") {
        let message = try JSONRPC.decode(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1"}}"#)
        guard case let .notification(method, params) = message else {
            check(false, "expected notification, got \(message)")
            return
        }
        check(method == "session/update", "notification method should be 'session/update'")
        check(params["sessionId"] as? String == "s1", "notification params sessionId should be s1")
    }

    test("testDecodeAgentToClientRequest") {
        let message = try JSONRPC.decode(#"{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{}}"#)
        guard case let .request(id, method, _) = message else {
            check(false, "expected request, got \(message)")
            return
        }
        check(id as? String == "p1", "request id should be 'p1'")
        check(method == "session/request_permission", "request method should be 'session/request_permission'")
    }

    test("testDecodeRejectsNonJSONLogLine") {
        do {
            _ = try JSONRPC.decode("Loading config...")
            check(false, "should have thrown JSONRPCError")
        } catch is JSONRPCError {
            check(true, "correctly threw JSONRPCError")
        }
    }
}
