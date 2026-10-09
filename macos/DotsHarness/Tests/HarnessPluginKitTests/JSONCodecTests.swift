import XCTest
import HarnessPluginKit
@testable import DotsHarnessCore

final class JSONCodecTests: XCTestCase {
    func testNumericZeroAndOneRemainDistinctFromBooleans() throws {
        let value = try JSONCodec.parse(Data(#"{"zero":0,"one":1,"fraction":0.5,"yes":true,"no":false}"#.utf8))
        XCTAssertEqual(value["zero"], .number(0))
        XCTAssertEqual(value["one"], .number(1))
        XCTAssertEqual(value["fraction"], .number(0.5))
        XCTAssertEqual(value["yes"], .bool(true))
        XCTAssertEqual(value["no"], .bool(false))
    }

    func testTerminalSSEPreservesReportedZeroCacheCounters() throws {
        let sse = #"data: {"type":"response.completed","response":{"id":"r","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":14640,"output_tokens":1,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens_details":{"reasoning_tokens":0}}}}"#
        let response = try NativeAgentClient.responseFromSSE(Data(sse.utf8))
        XCTAssertEqual(response.usage?.cachedTokens, 0)
        XCTAssertEqual(response.usage?.cacheWriteTokens, 0)
        XCTAssertEqual(response.usage?.outputTokens, 1)
        XCTAssertEqual(response.usage?.reasoningTokens, 0)
    }

    func testMissingCountersRemainUnknown() throws {
        let json = #"{"output":[],"usage":{"input_tokens":50,"output_tokens":2}}"#
        let response = try NativeAgentClient.response(from: JSONCodec.parse(Data(json.utf8)))
        XCTAssertNil(response.usage?.cachedTokens)
        XCTAssertNil(response.usage?.cacheWriteTokens)
    }

    func testFirstOutputDeltaLineIgnoresEchoedInstructions() {
        func isDelta(_ line: String) -> Bool { NativeAgentClient.isOutputDeltaLine(Data(line.utf8)) }
        XCTAssertTrue(isDelta(#"data: {"type":"response.output_text.delta","delta":"OK"}"#))
        XCTAssertTrue(isDelta(#"data: {"type":"content_block_delta","index":0}"#))
        XCTAssertFalse(isDelta("event: response.output_text.delta"))
        XCTAssertFalse(isDelta(#"data: {"type":"response.created","response":{"id":"resp_1","object":"response","created_at":1,"status":"in_progress","instructions":"say \"delta\""}}"#))
    }

    func testStreamDeltaCarriesOnlyProse() {
        func delta(_ line: String) -> NativeAgentClient.StreamDelta? {
            NativeAgentClient.streamDelta(fromLine: Data((line + "\r\n").utf8))
        }
        XCTAssertEqual(delta(#"data: {"type":"response.output_text.delta","delta":"OK"}"#), .text("OK"))
        XCTAssertEqual(delta(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#), .text("Hi"))
        XCTAssertEqual(delta(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}"#), .thinking("hm"))
        XCTAssertNil(delta(#"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\""}}"#))
        XCTAssertNil(delta(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#))
        XCTAssertNil(delta(#"data: {"type":"response.output_text.delta","delta":""}"#))
    }
}
