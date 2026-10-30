import XCTest
@testable import Search

final class AIInspectionSnapshotTests: XCTestCase {
    func testSuccessfulResponsesWithNullErrorAreNotFailures() {
        XCTAssertNil(AIClient.failure(["status":"completed","error":NSNull(),"output":[]],event:"",hiding:nil))
        XCTAssertNotNil(AIClient.failure(["error":["message":"Actual provider failure"]],event:"",hiding:nil))
    }
    private func fixture(_ body: String) throws -> AIInspectionSnapshot {
        let network: [String:Any] = ["records":[["id":"1","url":"https://fixture.invalid/api?token=raw-secret",
            "request":["method":"POST","headers":["Authorization":"Bearer fixture-token","Cookie":"session=fixture-cookie"],"postData":"password=fixture-password"],
            "response":["status":200,"headers":["Set-Cookie":"private=fixture-value; HttpOnly"]],
            "body":body,"base64Encoded":false,"bodyState":"available"]]]
        return try AIInspectionSnapshot(networkJSON:AIInspectionSnapshot.json(network),pageJSON:AIInspectionSnapshot.json(["dom":"<input value='fixture-password'>","url":"https://fixture.invalid/?token=raw-secret"]))
    }
    private func json(_ value: String) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(value.utf8)) as? [String:Any])
    }
    func testRequestHeadersBodiesCookiesAndURLStayUnredacted() throws {
        let snapshot = try fixture("response-secret")
        let request = try json(snapshot.read(part:"request",id:"1"))["data"] as? String ?? ""
        XCTAssertTrue(request.contains("fixture-token"))
        XCTAssertTrue(request.contains("fixture-cookie"))
        XCTAssertTrue(request.contains("fixture-password"))
        XCTAssertTrue(snapshot.index.contains("raw-secret"))
        XCTAssertTrue(snapshot.index.contains("private=fixture-value; HttpOnly"))
        XCTAssertEqual(try json(snapshot.read(part:"body",id:"1"))["data"] as? String,"response-secret")
    }
    func testUnicodeChunksReconstructTheEntireResponseWithoutLoss() throws {
        let body = "🙂a𝄞\n秘密" + String(repeating:"data-",count:20)
        let snapshot = try fixture(body)
        var offset=0, reconstructed=""
        repeat {
            let value = try json(snapshot.read(part:"body",id:"1",offset:offset,count:1))
            reconstructed += value["data"] as? String ?? ""
            let next = try XCTUnwrap(value["nextOffset"] as? Int)
            XCTAssertGreaterThan(next,offset)
            offset=next
            if value["more"] as? Bool != true { break }
        } while offset < body.utf16.count
        XCTAssertEqual(reconstructed,body)
    }
    func testUnknownRequestAndUnavailableBodyAreExplicitErrors() throws {
        let snapshot = try fixture("body")
        XCTAssertNotNil(try json(snapshot.read(part:"body",id:"missing"))["error"])
        let unavailable = try AIInspectionSnapshot(networkJSON:"{\"records\":[{\"id\":\"1\",\"body\":null,\"bodyState\":\"unavailable\",\"bodyError\":\"Evicted by WebKit\"}]}",pageJSON:"{}")
        XCTAssertEqual(try json(unavailable.read(part:"body",id:"1"))["error"] as? String,"Evicted by WebKit")
    }
    func testBodyPagingIsExplicitAndDoesNotModifyCapturedBody() throws {
        let body=String(repeating:"raw-credential\n",count:3000)
        let snapshot = try fixture(body)
        let value=try json(snapshot.read(part:"body",id:"1",count:999999))
        XCTAssertEqual(value["nextOffset"] as? Int,12000)
        XCTAssertEqual(value["more"] as? Bool,true)
        XCTAssertEqual((snapshot.network["records"] as? [[String:Any]])?.first?["body"] as? String,body)
    }
}
