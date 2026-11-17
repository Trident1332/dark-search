import XCTest
@testable import Search

final class OSINTFactsTests: XCTestCase {
    func testHTMLExtractionReadsDescriptionsAndStructuredProfileFields() {
        let html=#"""
        <title>Alice Example</title><meta content="Independent researcher and software developer." name="description">
        <script type="application/ld+json">{"@type":"Person","name":"Alice Example","description":"Open-source developer","url":"https://alice.example","sameAs":["https://github.com/alice"]}</script>
        """#
        let facts=OSINTFacts.html(html)
        XCTAssertEqual(facts["Name"],"Alice Example")
        XCTAssertEqual(facts["Description"],"Independent researcher and software developer.")
        XCTAssertEqual(facts["About"],"Open-source developer")
        XCTAssertEqual(facts["Website"],"https://alice.example")
        XCTAssertEqual(facts["Linked profiles"],"https://github.com/alice")
    }
    func testSearchLinksAndBareTitlesAreNotRetrievedFacts() {
        XCTAssertFalse(OSINTFinding(category:"More sources",title:"Search",detail:"Open search",source:"https://example.com",state:.reference).isSubstantive)
        XCTAssertFalse(OSINTFinding(category:"Web results",title:"A result",detail:"A link",source:"https://example.com",state:.possible).isSubstantive)
        XCTAssertFalse(OSINTFinding(category:"Retrieved pages",title:"Login",detail:"No details",source:"https://example.com",facts:["Page title":"Login"]).isSubstantive)
        XCTAssertFalse(OSINTFinding(category:"Retrieved pages",title:"Loading",detail:"Page retrieved",source:"https://example.com",facts:["Page title":"Loading","Canonical URL":"https://example.com","Match basis":"Retrieved the requested profile URL","Match meaning":"Public connection"]).isSubstantive)
        XCTAssertTrue(OSINTFinding(category:"Public profiles",title:"GitHub",detail:"Alice",source:"https://example.com",state:.possible,facts:["Name":"Alice"]).isSubstantive)
    }
    func testRegistrationSummaryShowsRegistrarAndDates() {
        let j: [String:Any]=["ldhName":"EXAMPLE.COM","events":[["eventAction":"registration","eventDate":"2000-01-01"],["eventAction":"expiration","eventDate":"2030-01-01"]],"entities":[["roles":["registrar"],"vcardArray":["vcard",[["fn",[:],"text","Example Registrar"]]]]]]
        let facts=OSINTFacts.registration(j)
        XCTAssertEqual(facts["Registrar"],"Example Registrar")
        XCTAssertEqual(facts["Registered"],"2000-01-01")
        XCTAssertTrue(OSINTFacts.summary(facts,fallback:"").contains("2030-01-01"))
    }
    func testPublicGitHubLookupReturnsFactsInsteadOfOnlyAProfileLink() async {
        let collector=FactsCollector()
        let service=OSINTService(fetch: { url in
            let json: [String:Any]
            if url.host=="raw.githubusercontent.com" {
                json=["GitHub":["url":"https://github.com/{}","errorType":"status_code"]]
            } else if url.host=="api.github.com" {
                XCTAssertEqual(url.absoluteString,"https://api.github.com/users/alice")
                json=["login":"alice","name":"Alice Example","bio":"Public profile biography","company":"Example Labs","blog":"https://alice.example","followers":12,"public_repos":7]
            } else {
                return .init(data:Data("null".utf8),status:404,url:url)
            }
            return .init(data:try JSONSerialization.data(withJSONObject:json),status:200,url:url)
        })
        await service.usernames("alice") { await collector.append($0) }
        let rows=await collector.values.filter { $0.title=="GitHub" }
        XCTAssertEqual(rows.count,1)
        XCTAssertEqual(rows[0].facts?["Name"],"Alice Example")
        XCTAssertTrue(rows[0].detail.contains("Public profile biography"))
        XCTAssertTrue(rows[0].detail.contains("Example Labs"))
        XCTAssertTrue(rows[0].isSubstantive)
        XCTAssertEqual(rows[0].source,"https://github.com/alice")
    }
    func testWebSearchActuallyDownloadsTheResultPage() async {
        let collector=FactsCollector()
        let service=OSINTService(fetch: { url in
            if url.host=="search.example" {
                return .init(data:Data(#"{"results":[{"title":"Alice","url":"https://alice.example/about","content":"Search snippet"}]}"#.utf8),status:200,url:url)
            }
            XCTAssertEqual(url.absoluteString,"https://alice.example/about")
            return .init(data:Data(#"<title>Alice</title><meta name="description" content="A biography retrieved from the actual website.">"#.utf8),status:200,url:url)
        },searx:"https://search.example")
        await service.web("Alice") { await collector.append($0) }
        let rows=await collector.values
        let page=rows.first { $0.category=="Retrieved pages" }
        XCTAssertEqual(page?.facts?["Description"],"A biography retrieved from the actual website.")
        XCTAssertTrue(page?.isSubstantive == true)
        XCTAssertTrue(rows.contains { $0.category=="Web results" && !$0.isSubstantive })
    }
    func testNameAndPhoneCollectorsReturnActualPublicMentions() async {
        for (query,kind) in [("Jane Example",OSINTKind.person),("4165550100",.phone)] {
            let collector=FactsCollector()
            let service=OSINTService(fetch: { url in
                let body: String
                if url.host=="search.example" { body=#"{"results":[{"title":"Example office","url":"https://office.example/contact","content":"A search result"}]}"# }
                else if url.host=="www.wikidata.org" { body=#"{"search":[]}"# }
                else { body="<title>Example office</title><p>Jane Example is the public contact for this fictional office. Its published phone number is (416) 555-0100.</p>" }
                return .init(data:Data(body.utf8),status:200,url:url)
            },searx:"https://search.example",phoneRegion:"CA")
            await service.collect(OSINTContext(text:query),kind:kind) { await collector.append($0) }
            let rows=await collector.values
            let mention=rows.first { $0.category=="Retrieved pages" && $0.isSubstantive }
            XCTAssertNotNil(mention,query)
            XCTAssertTrue(mention?.facts?["Matched passage"]?.contains("published phone number") == true)
            XCTAssertEqual(mention?.source,"https://office.example/contact")
        }
    }
    func testNameSearchReturnsAnActualMatchingPassage() {
        let source="<p>Jane Example joined the Example Research Institute in 2022.</p>"
        let passage=OSINTFacts.passage(source,subject:"Jane Example",kind:.person,facts:[:])
        XCTAssertTrue(passage?.contains("joined the Example Research Institute") == true)
        XCTAssertNil(OSINTFacts.passage(source,subject:"Different Person",kind:.person,facts:[:]))
    }
    func testPhoneSearchMatchesFormattingAndNationalPrefixesWithoutConfusingOtherCountryCodes() {
        XCTAssertNotNil(OSINTFacts.passage("<p>Example business: (416) 555-0100. Call during office hours.</p>",subject:"+14165550100",kind:.phone,facts:[:]))
        XCTAssertNotNil(OSINTFacts.passage("<p>London office: 020 7946 0958.</p>",subject:"+442079460958",kind:.phone,facts:[:]))
        XCTAssertNil(OSINTFacts.passage("<p>Different international number: +44 416 555 0100.</p>",subject:"+14165550100",kind:.phone,facts:[:]))
        XCTAssertTrue(OSINTPhone.searchQuery("4165550100",region:"CA").contains("416-555-0100"))
    }
    func testNationalPhoneInputCanBeInterpretedWithAnExplicitRegion() {
        XCTAssertEqual(OSINTKind.detect("4165550100"), .phone)
        XCTAssertEqual(OSINTKind.detect("2025550100"), .phone)
        XCTAssertEqual(OSINTKind.detect("192.0.2.1"), .ip)
        XCTAssertEqual(OSINTKind.detect("2001:db8::1"), .ip)
        XCTAssertEqual(OSINTPhone.describe("4165550100",region:"CA")["international"] as? String,"+14165550100")
        XCTAssertEqual(OSINTService.decode("Jane&#32;Example&#39;s profile"),"Jane Example's profile")
    }
    func testPhoneDiscoveryTriesSimpleExactFormatsAndFetchesTheResult() async {
        let collector=FactsCollector()
        let service=OSINTService(fetch: { url in
            let body: String
            if url.host=="html.duckduckgo.com" {
                let query=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name=="q" }?.value ?? ""
                XCTAssertFalse(query.contains(" OR "))
                body=query=="\"416-555-0100\"" ? "No results" : #"<a class="result__a" href="https://office.example/contact">Office contact</a>"#
            } else {
                body="<p>Example Office publishes (416) 555-0100 for public research enquiries.</p>"
            }
            return .init(data:Data(body.utf8),status:200,url:url)
        },phoneRegion:"CA")
        await service.collect(OSINTContext(text:"4165550100"),kind:.phone) { await collector.append($0) }
        let rows=await collector.values
        XCTAssertTrue(rows.contains { $0.category=="Retrieved pages" && $0.facts?["Matched passage"]?.contains("public research enquiries") == true })
    }
    func testOlderSavedEvidenceCanAcquireFactsWithoutLosingRawData() {
        var report=OSINTReport(context:OSINTContext(text:"example.com"),kind:.domain)
        let raw=#"{"ldhName":"EXAMPLE.COM","events":[{"eventAction":"registration","eventDate":"2000-01-01"}]}"#
        report.findings=[OSINTFinding(category:"Domains & networks",title:"Domain registration",detail:"EXAMPLE.COM · RDAP",source:"https://rdap.example",evidence:raw)]
        let upgraded=OSINTFacts.upgrade(report)
        XCTAssertEqual(upgraded.findings.first?.evidence,raw)
        XCTAssertEqual(upgraded.findings.first?.facts?["Registered"],"2000-01-01")
        XCTAssertTrue(upgraded.findings.first?.isSubstantive == true)
    }
}

private actor FactsCollector {
    var values: [OSINTFinding]=[]
    func append(_ row: OSINTFinding) { values.append(row) }
}
