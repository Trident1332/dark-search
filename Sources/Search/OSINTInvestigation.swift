import Foundation
import Network
import CryptoKit

/// Query planning and relationships are deterministic. Shared names/handles
/// never become a claim that two accounts belong to the same person.
enum OSINTIdentity {
    static func email(_ input: String) -> String? {
        var value=input.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.lowercased().hasPrefix("mailto:") { value=String(value.dropFirst(7)).components(separatedBy:"?")[0].removingPercentEncoding ?? String(value.dropFirst(7)) }
        guard value.range(of:#"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,63}$"#,options:[.regularExpression,.caseInsensitive]) != nil else { return nil }
        let parts=value.split(separator:"@",maxSplits:1)
        return String(parts[0])+"@"+parts[1].lowercased()
    }
    static func canonical(_ url: URL) -> String {
        guard var c=URLComponents(url:url,resolvingAgainstBaseURL:true) else { return url.absoluteString }
        c.fragment=nil; c.host=c.host?.lowercased()
        if c.port == (c.scheme=="https" ? 443 : 80) { c.port=nil }
        c.queryItems=c.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !["fbclid","gclid"].contains($0.name.lowercased()) }
        if c.queryItems?.isEmpty==true { c.queryItems=nil }
        if c.path.isEmpty { c.path="/" }
        return c.url?.absoluteString ?? url.absoluteString
    }
    /// Only public HTTP(S) leads are followed automatically. The network path
    /// remains OSINTHTTP/Proxy; this does not resolve names outside that route.
    static func publicLead(_ url: URL) -> Bool {
        guard ["https","http"].contains(url.scheme?.lowercased() ?? ""),url.user==nil,url.password==nil,
              let raw=url.host else { return false }
        let host=raw.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"[]."))
        if !host.contains(".") && !host.contains(":") { return false }
        if ["localhost","local","internal","home","onion"].contains(where: { host==$0 || host.hasSuffix("."+$0) }) { return false }
        if let address=IPv4Address(host) {
            let b=Array(address.rawValue)
            return !(b[0]==0 || b[0]==10 || b[0]==127 || b[0]>=224 || (b[0]==169 && b[1]==254) || (b[0]==172 && (16...31).contains(b[1])) || (b[0]==192 && b[1]==168) || (b[0]==100 && (64...127).contains(b[1])))
        }
        if let address=IPv6Address(host) {
            let b=Array(address.rawValue)
            if b.prefix(12).elementsEqual(Array(repeating:UInt8(0),count:10)+[255,255]) {
                return publicLead(URL(string:"https://"+b.suffix(4).map(String.init).joined(separator:"."))!)
            }
            return (b[0]&0xe0)==0x20
        }
        // Reject legacy integer and shortened numeric IPv4 spellings too.
        if IPv4Address(host) != nil || host.allSatisfy({ $0.isNumber || $0=="." }) { return false }
        return true
    }
    static func queries(_ query: String, kind: OSINTKind, region: String = "") -> [String] {
        let clean=query.replacingOccurrences(of:"\"",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
        let exact="\""+clean+"\""
        switch kind {
        case .person: return [exact,exact+" biography affiliation",exact+" (site:linkedin.com OR site:github.com OR site:orcid.org)"]
        case .company: return [exact,exact+" company registration official",exact+" contact leadership"]
        case .username: return [exact,exact+" profile",exact+" (site:github.com OR site:reddit.com OR site:gitlab.com)"]
        case .phone: return Array(OSINTPhone.searchTerms(query,region:region).prefix(4))
        case .email: return [exact,exact+" contact",exact+" (site:github.com OR site:linkedin.com)"]
        case .social:
            let url=OSINTService.webURL(query),handle=url?.path.split(separator:"/").last.map(String.init) ?? clean
            return [exact,"\""+handle+"\" site:"+(url?.host ?? clean),exact+" profile"]
        case .domain,.website:
            let host=OSINTService.host(query) ?? clean
            return ["site:"+host,"\""+host+"\" -site:"+host,"site:"+host+" (contact OR about OR team)"]
        default: return [clean]
        }
    }
    static func bounded(_ row: OSINTFinding) -> OSINTFinding {
        var copy=row
        let bytes=Data(row.evidence.utf8)
        copy.evidenceSHA256=row.evidenceSHA256 ?? SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        if bytes.count>131_072 {
            copy.evidence=String(decoding:bytes.prefix(131_072),as:UTF8.self)
            copy.evidenceTruncated=true
        }
        copy.pivots=Array(row.pivots.prefix(40))
        copy.facts=row.facts?.mapValues { String($0.prefix(12_000)) }
        return copy
    }
}

/// One investigation coalesces duplicate requests, limits total work and
/// cancels its exact in-flight tasks. No cross-investigation cache/cookies.
actor OSINTRequestLedger {
    private var tasks: [String:Task<OSINTHTTP.Response,Error>]=[:]
    private var bytes=0
    private var accounted=Set<String>()
    private let limit: Int
    init(limit: Int = 100) { self.limit=limit }
    func response(_ url: URL, fetch: @escaping OSINTService.Fetch) async throws -> OSINTHTTP.Response {
        try Task.checkCancellation()
        let key=OSINTIdentity.canonical(url)
        let task: Task<OSINTHTTP.Response,Error>
        if let existing=tasks[key] { task=existing }
        else {
            guard tasks.count<limit,bytes<48*1024*1024 else { throw Failure() }
            task=Task { try await fetch(url) };tasks[key]=task
        }
        let response=try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        if accounted.insert(key).inserted { bytes+=response.data.count }
        guard bytes<=48*1024*1024 else { throw Failure() }
        return response
    }
    struct Failure: LocalizedError { var errorDescription: String? { "Investigation request budget reached. Start a focused search from a finding to continue." } }
}

struct OSINTConnection: Identifiable {
    var id: String { type+":"+value }
    var type: String
    var value: String
    var sources: [OSINTFinding]
    var domains: Int { Set(sources.map { Registrable.domain(of:URL(string:$0.source)?.host?.lowercased() ?? $0.source,isSuffix:AtRest.systemSuffix) }).count }
}
struct OSINTEvent: Identifiable {
    var id: String { source.id.uuidString+label }
    var label: String
    var date: String
    var source: OSINTFinding
}
enum OSINTAnalysis {
    static func subjectSources(_ rows: [OSINTFinding],kind: OSINTKind?,subject: String?) -> [OSINTFinding] {
        guard let kind,[OSINTKind.person,.company,.social].contains(kind) else { return rows }
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let name=normalized(subject ?? "")
        var accepted=Set<UUID>()
        for row in rows where row.isSubstantive {
            let facts=row.facts ?? [:]
            let knowledge=facts["Wikidata ID"] != nil && (kind != .person || (facts["Record type"] ?? "").contains("(Q5)"))
            let known=kind != .social && (knowledge || (kind == .company && row.category=="Companies"))
            let structured=(kind == .person ? facts["Entity type"]?.contains("Person")==true : facts["Entity type"] != nil) && normalized(facts["Name"] ?? "")==name && !name.isEmpty
            let exactProfile=kind == .social && facts["Match basis"]=="Exact handle returned by the platform's public API"
            if known || structured || exactProfile { accepted.insert(row.id) }
        }
        let primaryURLs=Set(rows.filter { accepted.contains($0.id) }.map(\.source))
        for row in rows where row.facts?["Match basis"]=="Exact handle returned by the platform's public API" {
            if let linked=row.facts?["Linked from"],primaryURLs.contains(linked) { accepted.insert(row.id) }
        }
        return rows.filter { accepted.contains($0.id) }.map { row in
            guard row.facts?["Entity type"] != nil else { return row }
            var copy=row
            // Contacts in a site's footer belong to its publisher. Only the
            // matching structured entity's fields become subject connections.
            for field in ["Website","Published phone","Published email","Linked profiles","Company","Founded"] {
                copy.facts?.removeValue(forKey:field)
                if let value=row.facts?["Entity "+field] { copy.facts?[field]=value }
            }
            return copy
        }
    }
    static func export(_ report: OSINTReport) throws -> Data {
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        var object=try JSONSerialization.jsonObject(with:encoder.encode(report)) as! [String:Any]
        object["analysisVersion"]=2
        let scoped=subjectSources(report.findings,kind:report.kind,subject:report.context.text)
        object["connections"]=connections(scoped).map { ["type":$0.type,"value":$0.value,"sourceIDs":$0.sources.map { $0.id.uuidString },"sourceURLs":$0.sources.map(\.source),"distinctHosts":$0.domains] as [String:Any] }
        object["timeline"]=timeline(scoped).map { ["event":$0.label,"date":$0.date,"sourceID":$0.source.id.uuidString,"sourceURL":$0.source.source] }
        return try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys])
    }
    static func connections(_ rows: [OSINTFinding]) -> [OSINTConnection] {
        var grouped: [String:OSINTConnection]=[:]
        let fields=["Published email":"Email","Published phone":"Phone","Website":"Website","Linked profiles":"Profile","Company":"Organization","Employer":"Organization","LEI":"LEI","ASN":"Network"]
        for row in rows where row.isSubstantive {
            for (field,type) in fields {
                for raw in (row.facts?[field] ?? "").components(separatedBy:.newlines) {
                    var value=raw.trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    if type=="Website" || type=="Profile" {
                        guard let url=OSINTService.webURL(value),OSINTIdentity.publicLead(url) else { continue }
                        value=OSINTIdentity.canonical(url)
                    }
                    if type=="Email" { guard let email=OSINTIdentity.email(value) else { continue };value=email.lowercased() }
                    if type=="Phone" { value=value.filter { $0.isNumber || $0=="+" };guard value.count>=7 else { continue } }
                    let key=type+":"+value.lowercased()
                    if grouped[key]==nil { grouped[key]=OSINTConnection(type:type,value:value,sources:[]) }
                    if grouped[key]?.sources.contains(where: { OSINTIdentity.canonical(URL(string:$0.source) ?? URL(string:"about:blank")!) == OSINTIdentity.canonical(URL(string:row.source) ?? URL(string:"about:blank")!) })==false { grouped[key]?.sources.append(row) }
                }
            }
        }
        return grouped.values.sorted { a,b in a.domains != b.domains ? a.domains>b.domains : (a.sources.count != b.sources.count ? a.sources.count>b.sources.count : a.id<b.id) }
    }
    static func timeline(_ rows: [OSINTFinding]) -> [OSINTEvent] {
        rows.filter(\.isSubstantive).flatMap { row in
            ["Registered","Joined","Founded","Updated","Captured","Expires"].compactMap { field -> OSINTEvent? in
                guard let date=row.facts?[field],date.range(of:#"^\+?[0-9]{4}[-0-9T:Z+.]*$"#,options:.regularExpression) != nil else { return nil }
                let normalized: String
                if date.count==14,date.allSatisfy(\.isNumber) {
                    let a=Array(date);normalized=String(a[0..<4])+"-"+String(a[4..<6])+"-"+String(a[6..<8])+"T"+String(a[8..<10])+":"+String(a[10..<12])+":"+String(a[12..<14])+"Z"
                } else { normalized=date }
                return OSINTEvent(label:field,date:normalized,source:row)
            }
        }.sorted { $0.date == $1.date ? $0.id<$1.id : $0.date<$1.date }
    }
}
