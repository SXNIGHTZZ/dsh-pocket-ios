
import XCTest
@testable import DSHKit

/// `RPCRequest.ok(from:)` 的宽松解析：命令式接口只关心成功与否，
/// 返回体里 value 可能是 null / 数组 / 缺失（userQuestions/answer 就是这样）。
final class RPCOkParsingTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testAcceptsMissingOrNonDictionaryValue() {
        XCTAssertNoThrow(try RPCRequest.ok(from: data(#"{"result":{"ok":true}}"#)))
        XCTAssertNoThrow(try RPCRequest.ok(from: data(#"{"result":{"ok":true,"value":null}}"#)))
        XCTAssertNoThrow(try RPCRequest.ok(from: data(#"{"result":{"ok":true,"value":[]}}"#)))
        XCTAssertNoThrow(try RPCRequest.ok(from: data(#"{"result":{"ok":true,"value":"done"}}"#)))
    }

    func testRejectsBusinessFailure() {
        XCTAssertThrowsError(try RPCRequest.ok(from: data(
            #"{"result":{"ok":false,"error":{"message":"boom","status":400}}}"#)))
    }

    func testRejectsTransportError() {
        XCTAssertThrowsError(try RPCRequest.ok(from: data(
            #"{"error":{"message":"unauthorized","status":401}}"#)))
    }

    func testRejectsMalformed() {
        XCTAssertThrowsError(try RPCRequest.ok(from: data("not json")))
    }

    /// 对照：严格解析仍然要求 value 是字典（保持原有行为不被放松）。
    func testStrictValueStillRequiresDictionary() {
        XCTAssertThrowsError(try RPCRequest.value(from: data(#"{"result":{"ok":true,"value":null}}"#)))
        XCTAssertNoThrow(try RPCRequest.value(from: data(#"{"result":{"ok":true,"value":{"a":1}}}"#)))
    }
}
