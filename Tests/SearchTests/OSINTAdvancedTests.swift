import XCTest
import CryptoKit
@testable import Search

final class OSINTAdvancedTests: XCTestCase {
    func testEmailASNAndFocusedQueryPlanning() {
        XCTAssertEqual(OSINTKind.detect("contact@Example.org"),.email)
        XCTAssertEqual(OSINTKind.detect("AS13335"),.asn)
        XCTAssertEqual(OSINTKind.detect("mailto:press%40fixture.example?subject=Hello"),.email)
        XCTAssertEqual(OSINTIdentity.email("mailto:press%40fixture.example?subject=Hello"),"press@fixture.example")
        XCTAssertEqual(OSINTIdentity.email("name@example.org.attacker"),"name@example.org.attacker")
        XCTAssertNil(OSINTIdentity.email("name@example.org/contact"))
        for kind in [OSINTKind.person,.company,.username,.domain,.email] {
            XCTAssertGreaterThanOrEqual(OSINTIdentity.queries("Fixture Example",kind:kind).count,3)
        }
        XCTAssertFalse(OSINTIdentity.queries("+14165550100",kind:.phone).contains { $0.contains(" OR ") })
    }
    func testNestedStructuredContactsAndExactMentionBoundaries() {
        let html=#"""
        <title>Fixture researcher</title><a href="mailto:press%40fixture.example?subject=Hello">Contact</a>
        <script type="application/ld+json">{"@type":"ProfilePage","mainEntity":{"@type":["Person","Thing"],"name":"Jane Example","jobTitle":"Researcher","worksFor":{"name":"Fixture Institute"},"sameAs":["https://github.com/fixture"],"contactPoint":{"telephone":"+14165550100"}}}</script>
        <p>Jane Example writes public research for the fictional Fixture Institute.</p>
        """#
        let facts=OSINTFacts.html(html)
        XCTAssertEqual(facts["Name"],"Jane Example")
        XCTAssertEqual(facts["Company"],"Fixture Institute")
        XCTAssertEqual(facts["Role"],"Researcher")
        XCTAssertEqual(facts["Published email"],"press@fixture.example")
        XCTAssertEqual(facts["Published phone"],"+14165550100")
        XCTAssertNil(OSINTFacts.passage("<p>Jane Exampleson works here.</p>",subject:"Jane Example",kind:.person,facts:[:]))
        XCTAssertNil(OSINTFacts.passage("<p>Not the same mailbox: otherpress@fixture.example</p>",subject:"press@fixture.example",kind:.email,facts:[:]))
        XCTAssertNotNil(OSINTFacts.passage("<p>Contact press@fixture.example for research.</p>",subject:"press@fixture.example",kind:.email,facts:[:]))
        XCTAssertNotNil(OSINTFacts.passage("<p>For public research enquiries, email press@fixture.example.</p>",subject:"press@fixture.example",kind:.email,facts:[:]))
        XCTAssertNil(OSINTFacts.passage("<p>Different domain: press@fixture.example.attacker</p>",subject:"press@fixture.example",kind:.email,facts:[:]))
    }
    func testProfileAndWebsiteRelevanceRejectsUnrelatedSearchPages() {
        let page=URL(string:"https://brand.example/logo")!,profile="https://github.com/fixture"
        XCTAssertNil(OSINTService.relevance("<p>A generic logo and brand toolkit.</p>",facts:["Description":"Platform branding"],page:page,subject:profile,kind:.social))
        XCTAssertNotNil(OSINTService.relevance("<a href='https://github.com/fixture'>Public account</a>",facts:[:],page:page,subject:profile,kind:.social))
        XCTAssertNotNil(OSINTService.relevance("<p>Profile</p>",facts:[:],page:URL(string:profile)!,subject:profile,kind:.social))
        XCTAssertNil(OSINTService.relevance("<p>Not the same domain: fixture.example.attacker</p>",facts:[:],page:page,subject:"fixture.example",kind:.domain))
        XCTAssertNotNil(OSINTService.relevance("<p>A page from the requested site.</p>",facts:[:],page:URL(string:"https://contact.fixture.example/about")!,subject:"fixture.example",kind:.website))
        XCTAssertNil(OSINTService.relevance("<p>Different network AS133350</p>",facts:[:],page:page,subject:"AS13335",kind:.asn))
    }
    func testSubjectConnectionsExcludePublisherFootersAndNamesakes() {
        let html=#"""
        <script type="application/ld+json">[{"@type":"Person","name":"Jane Example","email":"jane@fixture.example","sameAs":["https://github.com/jane"]},{"@type":"Organization","name":"Publisher","email":"publisher@fixture.example","sameAs":["https://github.com/publisher"]}]</script>
        <a href="mailto:footer@fixture.example">Website support</a>
        """#
        let person=OSINTFinding(category:"Retrieved pages",title:"Jane Example",detail:"Biography",source:"https://fixture.example/jane",facts:OSINTFacts.html(html))
        let namesake=OSINTFinding(category:"Retrieved pages",title:"Jane Example Institute",detail:"Organization named after the person",source:"https://institute.example",facts:["Name":"Jane Example Institute","Entity type":"Organization","Published email":"office@institute.example","Linked profiles":"https://github.com/institute"])
        let scoped=OSINTAnalysis.subjectSources([person,namesake],kind:.person,subject:"Jane Example")
        let connections=OSINTAnalysis.connections(scoped)
        XCTAssertEqual(scoped.count,1)
        XCTAssertTrue(connections.contains { $0.value=="jane@fixture.example" })
        XCTAssertTrue(connections.contains { $0.value=="https://github.com/jane" })
        XCTAssertFalse(connections.contains { $0.value.contains("footer") || $0.value.contains("publisher") || $0.value.contains("institute") })
        let mixed=#"<script type='application/ld+json'>{"@type":"Person","name":"Alice","telephone":"+14165550100"}</script><script type='application/ld+json'>{"@type":"Person","name":"Jane Example"}</script>"#
        XCTAssertNil(OSINTFacts.html(mixed)["Entity Published phone"])
    }
    func testMultiQueryRetrievalDeduplicatesAndFollowsContactPages() async {
        let calls=AdvancedCalls(),rows=AdvancedRows()
        let service=OSINTService(fetch: { url in
            await calls.add(url)
            if url.host=="search.example" {
                let results=(0..<8).map { ["title":"Jane Example \($0)","url":"https://source\($0).example/bio","content":"Index snippet"] }
                    + [["title":"Duplicate","url":"https://source0.example/bio?utm_source=test"],["title":"Unsafe","url":"http://127.0.0.1/private"]]
                return try reply(url,["results":results])
            }
            if url.host=="www.wikidata.org" { return try reply(url,["search":[]]) }
            let content="<title>Jane Example</title><p>Jane Example is a fictional researcher. Public research contact details are provided here.</p><a href='/contact'>Contact</a><a href='http://127.0.0.1/secret'>Private link</a><a href='mailto:research@fixture.example'>Email</a>"
            return textReply(url,content)
        },searx:"https://search.example")
        await service.collect(OSINTContext(text:"Jane Example"),kind:.person) { await rows.add($0) }
        let fetched=await calls.urls,findings=await rows.rows
        XCTAssertEqual(fetched.filter { $0.host=="search.example" }.count,3)
        XCTAssertEqual(fetched.filter { $0.path=="/bio" }.count,8)
        XCTAssertEqual(fetched.filter { $0.path=="/contact" }.count,4)
        XCTAssertFalse(fetched.contains { $0.host=="127.0.0.1" })
        XCTAssertEqual(findings.filter { $0.category=="Retrieved pages" && $0.isSubstantive }.count,12)
        XCTAssertTrue(findings.contains { $0.facts?["Linked from"] != nil })
        XCTAssertFalse(findings.filter { $0.category=="Web results" }.contains(where:\.isSubstantive))
        let connection=OSINTAnalysis.connections(findings).first { $0.value=="research@fixture.example" }
        XCTAssertEqual(connection?.domains,8)
        XCTAssertEqual(connection?.sources.count,12)
    }
    func testRSSFallbackRetrievesPagesAndRejectsUnmatchedIndexSnippets() async {
        let rows=AdvancedRows()
        let service=OSINTService(fetch: { url in
            switch url.host {
            case "html.duckduckgo.com":return textReply(url,"blocked",status:403)
            case "www.bing.com":return textReply(url,"<rss><channel><item><title>Jane Example</title><description>Jane Example index snippet</description><link>https://fixture.example/bio</link></item><item><title>Not a match</title><link>https://other.example/about</link></item></channel></rss>")
            case "fixture.example":return textReply(url,"<p>Jane Example is the fictional author of this retrieved biography and research page.</p>")
            default:return textReply(url,"<p>Completely different author; this page does not mention the requested subject.</p>")
            }
        })
        await service.web("Jane Example",subject:"Jane Example",kind:.person) { await rows.add($0) }
        let found=await rows.rows
        XCTAssertEqual(found.filter { $0.category=="Retrieved pages" && $0.isSubstantive }.count,1)
        XCTAssertTrue(found.contains { $0.source=="https://other.example/about" && $0.state == .notFound })
    }
    func testEmailInvestigationChecksMailRecordsAndActualMentions() async {
        let rows=AdvancedRows(),calls=AdvancedCalls()
        let service=OSINTService(fetch: { url in
            await calls.add(url)
            if url.host=="dns.google" { return try reply(url,["Status":0,"AD":true,"Answer":[["data":"10 mail.fixture.example."]]]) }
            if url.host=="search.example" { return try reply(url,["results":[["url":"https://fixture.example/contact","title":"Press office"]]]) }
            return textReply(url,"<p>For public press enquiries, email press@fixture.example at the fictional office.</p><a href='mailto:press@fixture.example'>Email</a>")
        },searx:"https://search.example")
        await service.collect(OSINTContext(text:"press@fixture.example"),kind:.email) { await rows.add($0) }
        let found=await rows.rows,urls=await calls.urls
        XCTAssertTrue(found.contains { $0.facts?["Matched passage"]?.contains("press@fixture.example")==true })
        XCTAssertTrue(found.contains { $0.title=="Mail delivery" && $0.isSubstantive })
        XCTAssertTrue(found.contains { $0.title=="DMARC policy" })
        XCTAssertFalse(urls.contains { $0.scheme=="smtp" || $0.path.contains("password") })
    }
    func testPublicKnowledgeRecordIncludesNamedAffiliationsAndPublishedProfiles() async {
        let rows=AdvancedRows()
        func claim(_ value: Any) -> [[String:Any]] { [["mainsnak":["datavalue":["value":value]]]] }
        let service=OSINTService(fetch: { url in
            if url.path.contains("Special:EntityData") {
                return try reply(url,["entities":["Q123":["labels":["en":["value":"Fixture Labs"]],"claims":["P749":claim(["id":"Q456"]),"P856":claim("https://fixture.example"),"P571":claim(["time":"+2001-01-01T00:00:00Z"]),"P2037":claim("fixture")]]]])
            }
            let params=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            if params.contains(where: { $0.value=="wbgetentities" }) { return try reply(url,["entities":["Q456":["labels":["en":["value":"Fixture Parent"]]]]]) }
            return try reply(url,["search":[["id":"Q123","label":"Fixture Labs","description":"Fictional organization"]]])
        })
        await service.entities("Fixture Labs") { await rows.add($0) }
        let result=await rows.rows.first { $0.facts?["Parent organization"] != nil }
        XCTAssertEqual(result?.facts?["Parent organization"],"Fixture Parent (Q456)")
        XCTAssertEqual(result?.facts?["Linked profiles"],"https://github.com/fixture")
        XCTAssertEqual(result?.facts?["Website"],"https://fixture.example")
        XCTAssertEqual(result?.state,.possible)
    }
    func testPlatformAPIsStillWorkWhenUsernameCatalogFails() async {
        let rows=AdvancedRows()
        let service=OSINTService(fetch: { url in
            if url.host=="api.github.com" { return try reply(url,["login":"fixture","name":"Fixture Research","bio":"Public profile","blog":"https://fixture.example","email":"hello@fixture.example"]) }
            return textReply(url,"unavailable",status:503)
        })
        await service.usernames("fixture") { await rows.add($0) }
        let found=await rows.rows
        XCTAssertTrue(found.contains { $0.title=="GitHub" && $0.facts?["Published email"]=="hello@fixture.example" })
        XCTAssertTrue(found.contains { $0.title=="Username source catalog" && $0.state == .unavailable })
    }
    func testPersonKnowledgeLookupKeepsBooksAndPlacesAsLeads() async {
        let rows=AdvancedRows()
        let service=OSINTService(fetch: { url in
            if url.path.contains("Special:EntityData") {
                let id=url.lastPathComponent.replacingOccurrences(of:".json",with:"")
                return try reply(url,["entities":[id:["labels":["en":["value":id=="Q111" ? "Jane Example" : "Jane Example College"]],"claims":["P31":[["mainsnak":["datavalue":["value":["id":id=="Q111" ? "Q5" : "Q3918"]]]]]]]]])
            }
            let query=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            if query.contains(where: { $0.value=="wbgetentities" }) { return try reply(url,["entities":[:]]) }
            return try reply(url,["search":[["id":"Q111","label":"Jane Example","description":"Researcher"],["id":"Q222","label":"Jane Example College","description":"University"]]])
        })
        await service.entities("Jane Example",kind:.person) { await rows.add($0) }
        let found=await rows.rows
        XCTAssertEqual(found.filter(\.isSubstantive).count,1)
        XCTAssertEqual(found.first(where:\.isSubstantive)?.title,"Jane Example")
        XCTAssertTrue(found.filter { $0.title=="Jane Example College" }.allSatisfy { $0.state == .reference })
    }
    func testWrongAPIIdentityAndGenericSoft404AreNotProfileMatches() async {
        let rows=AdvancedRows()
        let service=OSINTService(fetch: { url in
            if url==OSINTService.catalogURL { return try reply(url,["Fixture":["url":"https://profiles.example/{}","errorType":"status_code"]]) }
            if url.host=="api.github.com" { return try reply(url,["login":"different-person","name":"Wrong account"]) }
            if url.host=="profiles.example" { return textReply(url,"<title>Profiles</title><p>This is a generic landing page without any user account information.</p>") }
            return textReply(url,"null",status:404)
        })
        await service.usernames("fixture") { await rows.add($0) }
        let found=await rows.rows
        XCTAssertFalse(found.contains(where:\.isSubstantive))
        XCTAssertEqual(found.first { $0.title=="Fixture" }?.state,.unavailable)
        XCTAssertEqual(found.first { $0.title=="GitHub" }?.state,.unavailable)
    }
    func testAutomaticLeadsRejectLocalAndCredentialURLs() {
        for raw in ["http://127.0.0.1/x","http://10.0.0.1","http://[::1]","http://[::127.0.0.1]","http://[::ffff:127.0.0.1]","http://169.254.169.254/latest","https://device.local","http://localhost","https://user:password@example.org","file:///etc/passwd","http://2130706433"] {
            XCTAssertFalse(OSINTIdentity.publicLead(URL(string:raw)!),raw)
        }
        XCTAssertTrue(OSINTIdentity.publicLead(URL(string:"https://www.example.org/contact")!))
    }
    func testRedirectPolicyKeepsAutomaticCollectionOnPublicDestinations() {
        let initial=URL(string:"https://fixture.example/start")!,delegate=OSINTRedirects(initial:initial)
        let session=URLSession(configuration:.ephemeral),task=session.dataTask(with:initial)
        defer { task.cancel();session.invalidateAndCancel() }
        let response=HTTPURLResponse(url:initial,statusCode:302,httpVersion:"HTTP/1.1",headerFields:[:])!
        var accepted:URLRequest?
        delegate.urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"http://169.254.169.254/latest")!)) { accepted=$0 }
        XCTAssertNil(accepted)
        delegate.urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"https://another.example/public")!)) { accepted=$0 }
        XCTAssertEqual(accepted?.url?.host,"another.example")
        let local=OSINTRedirects(initial:URL(string:"http://localhost:8080/search")!)
        local.urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"http://localhost:9090/private")!)) { accepted=$0 }
        XCTAssertNil(accepted)
    }
    func testSearchFeedRejectsDTDAndPrivateResultURLs() {
        XCTAssertTrue(OSINTSearchFeed.results(Data("<!DOCTYPE rss [<!ENTITY xxe SYSTEM 'file:///etc/passwd'>]><rss><channel><item><title>&xxe;</title><link>https://fixture.example</link></item></channel></rss>".utf8)).isEmpty)
        XCTAssertTrue(OSINTSearchFeed.results(Data("<rss><channel><item><title>Private</title><link>http://127.0.0.1/private</link></item></channel></rss>".utf8)).isEmpty)
    }
    func testLedgerCoalescesRequestsAndEnforcesInvestigationBudget() async throws {
        let calls=AdvancedCalls(),ledger=OSINTRequestLedger(limit:2),url=URL(string:"https://fixture.example/page")!
        let fetch:OSINTService.Fetch={ url in await calls.add(url);try await Task.sleep(for:.milliseconds(30));return textReply(url,"one response") }
        async let a=ledger.response(url,fetch:fetch)
        async let b=ledger.response(URL(string:url.absoluteString+"#fragment")!,fetch:fetch)
        let responses=try await [a,b]
        XCTAssertEqual(responses.map(\.text),["one response","one response"])
        _=try await ledger.response(URL(string:"https://fixture.example/two")!,fetch:fetch)
        do { _=try await ledger.response(URL(string:"https://fixture.example/three")!,fetch:fetch);XCTFail("Budget must stop additional requests") } catch { XCTAssertTrue(error is OSINTRequestLedger.Failure) }
        let count=await calls.urls.count;XCTAssertEqual(count,2)
    }
    func testLedgerCancellationStopsItsOwnedFetch() async throws {
        let ledger=OSINTRequestLedger()
        let task=Task { try await ledger.response(URL(string:"https://fixture.example/slow")!,fetch: { url in try await Task.sleep(for:.seconds(30));return textReply(url,"late") }) }
        try await Task.sleep(for:.milliseconds(30));task.cancel()
        do { _=try await task.value;XCTFail("Cancelled investigation must not return evidence") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testAutomaticProfileExpansionDoesNotFollowNamesakePublishers() async throws {
        let calls=AdvancedCalls(),rows=AdvancedRows()
        let service=OSINTService(fetch: { url in await calls.add(url);return try reply(url,["login":"jane","name":"Jane Example"]) })
        let person=OSINTFinding(category:"Retrieved pages",title:"Jane Example",detail:"Biography",source:"https://person.example",facts:["Name":"Jane Example","Entity type":"Person","Linked profiles":"https://github.com/jane","Entity Linked profiles":"https://github.com/jane"])
        let publisher=OSINTFinding(category:"Retrieved pages",title:"Jane Example Institute",detail:"Namesake organization",source:"https://institute.example",facts:["Name":"Jane Example Institute","Entity type":"Organization","Linked profiles":"https://github.com/institute"])
        await service.follow(pages:[person,publisher],subject:"Jane Example",kind:.person) { await rows.add($0) }
        let urls=await calls.urls
        XCTAssertEqual(urls.map(\.absoluteString),["https://api.github.com/users/jane"])
        let found=await rows.rows
        XCTAssertEqual(found.first?.facts?["Linked from"],"https://person.example")
    }
    func testEvidenceHashSurvivesTruncationAndExportContainsCitedConnections() throws {
        let raw=String(repeating:"long evidence ",count:20_000)
        let first=OSINTIdentity.bounded(OSINTFinding(category:"Retrieved pages",title:"Office",detail:"Published contact",source:"https://fixture.example/contact",evidence:raw,facts:["Published email":"press@fixture.example","Joined":"2020-01-01"]))
        let second=OSINTIdentity.bounded(first)
        XCTAssertEqual(first.evidenceSHA256,SHA256.hash(data:Data(raw.utf8)).map { String(format:"%02x",$0) }.joined())
        XCTAssertEqual(first.evidenceSHA256,second.evidenceSHA256)
        XCTAssertEqual(second.evidenceTruncated,true)
        var report=OSINTReport(context:OSINTContext(text:"press@fixture.example"),kind:.email)
        report.findings=[first,OSINTFinding(category:"Retrieved pages",title:"Other source",detail:"Contact",source:"https://other.example/",facts:["Published email":"press@fixture.example","Captured":"20240102123456"])]
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:OSINTAnalysis.export(report)) as? [String:Any])
        let connections=try XCTUnwrap(object["connections"] as? [[String:Any]])
        XCTAssertEqual(connections.first?["distinctHosts"] as? Int,2)
        XCTAssertEqual((connections.first?["sourceIDs"] as? [String])?.count,2)
        XCTAssertEqual(OSINTAnalysis.timeline(report.findings).last?.date,"2024-01-02T12:34:56Z")
        XCTAssertEqual((object["findings"] as? [[String:Any]])?.count,2)
    }
}

private func textReply(_ url: URL,_ text: String,status: Int = 200) -> OSINTHTTP.Response { .init(data:Data(text.utf8),status:status,url:url) }
private func reply(_ url: URL,_ json: Any) throws -> OSINTHTTP.Response { .init(data:try JSONSerialization.data(withJSONObject:json),status:200,url:url) }
private actor AdvancedRows { var rows:[OSINTFinding]=[];func add(_ row:OSINTFinding) { rows.append(row) } }
private actor AdvancedCalls { var urls:[URL]=[];func add(_ url:URL) { urls.append(url) } }
