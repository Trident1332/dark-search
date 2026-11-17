import Foundation
import Network

/// Public-source collection. No credential, subscription or cloud model is required.
final class OSINTHTTP: @unchecked Sendable {
    struct Response: Sendable { var data: Data; var status: Int; var url: URL; var headers: [String:String] = [:]
        var text: String { String(data:data,encoding:.utf8) ?? String(decoding:data,as:UTF8.self) }
        var json: [String:Any] { (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:] }
    }
    private let lock = NSLock()
    private var kept: (Int,URLSession)?
    private var route: ProxyConfiguration?
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName:Proxy.routeChanged,object:nil,queue:nil) { [weak self] _ in self?.cancel() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; kept?.1.invalidateAndCancel() }
    func cancel() { lock.lock(); let old=kept; kept=nil; lock.unlock(); old?.1.invalidateAndCancel() }
    func setRoute(_ value: ProxyConfiguration?) {
        lock.lock(); let old=kept; kept=nil; route=value; lock.unlock()
        old?.1.invalidateAndCancel()
    }
    private func session() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        let version = Proxy.routesRevision
        if let kept, kept.0 == version { return kept.1 }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage=nil; config.httpShouldSetCookies=false; config.urlCredentialStorage=nil; config.urlCache=nil
        config.timeoutIntervalForRequest=15; config.timeoutIntervalForResource=25
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = Proxy.makeSession(configuration:config,route:route)
        kept=(version,session); return session
    }
    func fetch(_ url: URL) async throws -> Response {
        var target = url
        // Deterministic native integration tests only; never enabled in a normal session.
        if Store.testing, let base = ProcessInfo.processInfo.environment["SEARCH_OSINT_FIXTURE"], let u = URL(string:base) {
            target = OSINTJSON.url(u.appendingPathComponent("source").absoluteString,["url":url.absoluteString])
        }
        var request = URLRequest(url:target)
        request.setValue("SearchOSINT/1.0 (+https://github.com/Trident1332/dark-search)",forHTTPHeaderField:"User-Agent")
        request.setValue("application/json, text/html;q=0.9, */*;q=0.8",forHTTPHeaderField:"Accept")
        let redirects=OSINTRedirects(initial:target)
        let (stream,response) = try await session().proxyBytes(for:request,delegate:redirects)
        let limit=url==OSINTService.catalogURL ? 16*1024*1024 : 4*1024*1024
        var data=Data()
        for try await byte in stream {
            if data.count>=limit { throw NSError(domain:"OSINT",code:2,userInfo:[NSLocalizedDescriptionKey:"The source response exceeded the collection limit; open it directly to inspect it."]) }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return Response(data:data,status:http.statusCode,url:Store.testing && target != url ? url : (http.url ?? url),headers:http.allHeaderFields.reduce(into:[:]) { $0[String(describing:$1.key)]=String(describing:$1.value) })
    }
}

final class OSINTRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let initial: URL
    private var redirects=0
    init(initial: URL) { self.initial=initial }
    func urlSession(_ session: URLSession,task: URLSessionTask,didReceive challenge: URLAuthenticationChallenge,completionHandler: @escaping (URLSession.AuthChallengeDisposition,URLCredential?) -> Void) {
        if Proxy.authenticate(challenge,in:session,completionHandler:completionHandler) { return }
        completionHandler(challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge,nil)
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) {
        redirects+=1
        guard redirects<=6,let target=request.url,
              OSINTIdentity.publicLead(target) || (!OSINTIdentity.publicLead(initial) && target.host==initial.host && target.port==initial.port && target.scheme==initial.scheme) else { completionHandler(nil);return }
        completionHandler(request)
    }
}

struct OSINTService: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> OSINTHTTP.Response
    typealias Emit = @Sendable (OSINTFinding) async -> Void
    var fetch: Fetch
    var searx = ""
    var allSites = false
    var phoneRegion = ""
    init(fetch: @escaping Fetch, searx: String = "", allSites: Bool = false, phoneRegion: String = "") { self.fetch=fetch; self.searx=searx; self.allSites=allSites; self.phoneRegion=phoneRegion }
    static let catalogURL = URL(string:"https://raw.githubusercontent.com/sherlock-project/sherlock/master/sherlock_project/resources/data.json")!
    func collect(_ context: OSINTContext, kind: OSINTKind, emit: @escaping Emit) async {
        let ledger=OSINTRequestLedger(limit:allSites ? 1800 : 100)
        var scoped=self
        let original=fetch
        scoped.fetch={ url in try await ledger.response(url,fetch:original) }
        await scoped.run(context,kind:kind) { row in
            guard !Task.isCancelled else { return }
            await emit(OSINTIdentity.bounded(row))
        }
    }
    private func run(_ context: OSINTContext, kind: OSINTKind, emit: @escaping Emit) async {
        let raw = context.text.trimmingCharacters(in:.whitespacesAndNewlines)
        let query = kind == .username ? raw.trimmingCharacters(in:CharacterSet(charactersIn:"@")) : kind == .email ? (OSINTIdentity.email(raw) ?? raw) : raw
        await withTaskGroup(of:Void.self) { group in
            if [.domain,.website].contains(kind), let host = Self.host(query) {
                group.addTask {
                    if IPv4Address(host) != nil || IPv6Address(host) != nil { await self.ip(host,emit:emit) }
                    else { await self.domain(host,emit:emit) }
                }
            }
            if [.website,.social].contains(kind), let u = Self.webURL(query) {
                group.addTask {
                    if kind == .social { await self.socialProfile(u,emit:emit) }
                    else {
                        let pages=OSINTWebCandidates()
                        await self.page(u) { row in await pages.append(row);await emit(row) }
                        await self.follow(pages:await pages.values,subject:nil,kind:kind,emit:emit)
                    }
                }
            }
            if kind == .username {
                group.addTask { await self.usernames(query.trimmingCharacters(in:CharacterSet(charactersIn:"@")),emit:emit) }
            }
            if kind == .ip { group.addTask { await self.ip(query,emit:emit) } }
            if kind == .asn { group.addTask { await self.asn(query,emit:emit) } }
            if kind == .company { group.addTask { await self.company(query,emit:emit) } }
            if kind == .email { group.addTask { await self.email(query,emit:emit) } }
            if kind == .phone {
                let value=OSINTPhone.describe(query,region:phoneRegion)
                let fields=OSINTFacts.compact(["International":OSINTFacts.text(value["international"]),"Calling code":OSINTFacts.text(value["callingCode"]),"Numbering regions":OSINTFacts.text(value["numberingRegions"]),"Number categories":OSINTFacts.text(value["numberingCategories"]),"Plan match":(value["matchesNumberingPlan"] as? Bool).map { $0 ? "Yes" : "No" } ?? ""])
                let finding=OSINTFinding(category:"Phone numbering",title:value["international"] as? String ?? query,
                    detail:OSINTFacts.summary(fields,fallback:value["error"] as? String ?? "No numbering data returned"),
                    source:"https://github.com/google/libphonenumber",state:value["error"] == nil ? .found : .unavailable,
                    evidence:OSINTJSON.text(value),facts:fields)
                await emit(finding)
            }
            if [.person,.company].contains(kind) { group.addTask { await self.entities(query,kind:kind,emit:emit) } }
            if kind != .image {
                group.addTask {
                    let normalized=OSINTPhone.describe(query,region:phoneRegion)["international"] as? String ?? query
                    await self.web(kind == .phone ? OSINTPhone.searchQuery(query,region:phoneRegion) : query,subject:kind == .phone ? normalized : query,kind:kind,emit:emit)
                }
            }
            await group.waitForAll()
        }
    }
    static func webURL(_ query: String) -> URL? {
        guard let url = URL(string:query.contains("://") ? query : "https://"+query), ["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host != nil,url.user==nil,url.password==nil else { return nil }
        return url
    }
    static func host(_ query: String) -> String? { webURL(query)?.host?.lowercased() }
    func source(_ category: String, _ title: String, _ url: URL, emit: Emit,
                        parse: (OSINTHTTP.Response) -> [OSINTFinding]) async {
        do {
            try Task.checkCancellation()
            let response = try await fetch(url)
            guard (200..<300).contains(response.status) else {
                await emit(OSINTFinding(category:category,title:title,detail:Self.status(response.status),source:url.absoluteString,state:.unavailable,evidence:response.text)); return
            }
            for row in parse(response) { try Task.checkCancellation(); await emit(row) }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { await emit(OSINTFinding(category:category,title:title,detail:error.localizedDescription,source:url.absoluteString,state:.unavailable)) } }
    }
    static func status(_ status: Int) -> String {
        switch status { case 429: return "Rate limited by this source"
        case 401,403: return "Access blocked or login required"
        case 404: return "No public record returned"
        default: return "Source returned HTTP \(status)" }
    }
    func domain(_ host: String, emit: @escaping Emit) async {
        let registered=Registrable.domain(of:host,isSuffix:AtRest.systemSuffix)
        await withTaskGroup(of:Void.self) { group in
            group.addTask {
                let url = URL(string:"https://rdap.org/domain/"+registered)!
                await source("Domains & networks","Domain registration",url,emit:emit) { response in
                    let j=response.json
                    guard j["ldhName"] != nil || j["unicodeName"] != nil else { return [Self.invalid("Domain registration",response)] }
                    return [OSINTFinding(category:"Domains & networks",title:"Domain registration",detail:OSINTFacts.summary(OSINTFacts.registration(j),fallback:host),source:response.url.absoluteString,evidence:response.text,pivots:Self.strings(j["nameservers"],key:"ldhName"),facts:OSINTFacts.registration(j))]
                }
            }
            for type in ["A","AAAA","MX","NS","TXT","CAA","CNAME"] {
                group.addTask {
                    let url=OSINTJSON.url("https://dns.google/resolve",["name":host,"type":type])
                    await source("Domains & networks","\(type) records",url,emit:emit) { response in
                        let j=response.json, answers=j["Answer"] as? [[String:Any]] ?? []
                        let values=answers.compactMap { $0["data"] as? String }
                        let status=j["Status"] as? Int ?? -1
                        return [OSINTFinding(category:"Domains & networks",title:"\(type) records",detail:values.isEmpty ? (status==0 ? "No \(type) answers" : "DNS status \(status)") : values.joined(separator:"\n"),source:url.absoluteString,state:status==0 ? (values.isEmpty ? .notFound : .found) : .unavailable,evidence:response.text,pivots:type=="A" || type=="AAAA" ? values : [],facts:values.isEmpty ? nil : [type:values.joined(separator:"\n")])]
                    }
                }
            }
            group.addTask { await self.dnsPolicy(registered,emit:emit) }
            group.addTask {
                let url=OSINTJSON.url("https://crt.sh/",["q":"%."+host,"output":"json"])
                await source("Domains & networks","Certificate names",url,emit:emit) { response in
                    guard let records=(try? JSONSerialization.jsonObject(with:response.data)) as? [[String:Any]] else { return [Self.invalid("Certificate names",response)] }
                    let names=Array(Set(records.flatMap { ($0["name_value"] as? String ?? "").components(separatedBy:"\n") })).filter { $0==host || $0.hasSuffix("."+host) }.sorted()
                    return [OSINTFinding(category:"Domains & networks",title:"Certificate names",detail:names.isEmpty ? "No names returned" : names.joined(separator:"\n"),source:url.absoluteString,state:names.isEmpty ? .notFound : .found,evidence:response.text,pivots:names.filter { !$0.contains("*") },facts:names.isEmpty ? nil : ["Certificate names":names.joined(separator:"\n")])]
                }
            }
            group.addTask {
                let url=OSINTJSON.url("https://web.archive.org/cdx/search/cdx",["url":host+"/*","output":"json","filter":"statuscode:200","collapse":"urlkey","limit":"30","fl":"timestamp,original,statuscode,mimetype"])
                await source("Domains & networks","Archived pages",url,emit:emit) { response in
                    guard let rows=(try? JSONSerialization.jsonObject(with:response.data)) as? [[String]] else { return [Self.invalid("Archived pages",response)] }
                    let entries=rows.dropFirst().filter { $0.count>=2 }
                    return entries.map { OSINTFinding(category:"Archived pages",title:$0[1],detail:"Archived \($0[0])",source:"https://web.archive.org/web/\($0[0])/\($0[1])",evidence:OSINTJSON.text($0),pivots:[$0[1]],facts:["Captured":$0[0],"Original page":$0[1]]) } + (entries.isEmpty ? [OSINTFinding(category:"Archived pages",title:"Archived pages",detail:"No captures returned for this query",source:url.absoluteString,evidence:response.text)] : [])
                }
            }
        }
    }
    func ip(_ value: String, emit: @escaping Emit) async {
        guard IPv4Address(value) != nil || IPv6Address(value) != nil else {
            await emit(OSINTFinding(category:"Domains & networks",title:"IP address",detail:"Enter a valid IPv4 or IPv6 address",source:"",state:.unavailable)); return
        }
        await withTaskGroup(of:Void.self) { group in
            group.addTask {
                let url=URL(string:"https://rdap.org/ip/"+value)!
                await source("Domains & networks","Network registration",url,emit:emit) { r in
                    guard r.json["startAddress"] != nil else { return [Self.invalid("Network registration",r)] }
                    return [OSINTFinding(category:"Domains & networks",title:r.json["name"] as? String ?? "Network registration",detail:"\(r.json["startAddress"] ?? "") – \(r.json["endAddress"] ?? "")\nRegistration country: \(r.json["country"] ?? "Not supplied") · not device location",source:r.url.absoluteString,evidence:r.text,facts:OSINTFacts.compact(["Network":OSINTFacts.text(r.json["name"]),"Start":OSINTFacts.text(r.json["startAddress"]),"End":OSINTFacts.text(r.json["endAddress"]),"Registration country":OSINTFacts.text(r.json["country"])]))]
                }
            }
            group.addTask {
                let url=OSINTJSON.url("https://stat.ripe.net/data/network-info/data.json",["resource":value])
                await source("Domains & networks","Announcing networks",url,emit:emit) { r in
                    let d=r.json["data"] as? [String:Any] ?? [:], asns=(d["asns"] as? [Any] ?? []).map { let value=String(describing:$0); return value.hasPrefix("AS") ? value : "AS"+value }
                    return [OSINTFinding(category:"Domains & networks",title:"Announcing networks",detail:asns.joined(separator:", ")+" · \(d["prefix"] ?? "No prefix returned")",source:url.absoluteString,evidence:r.text,facts:OSINTFacts.compact(["ASN":asns.joined(separator:", "),"Prefix":OSINTFacts.text(d["prefix"])]))]
                }
                if let r=try? await fetch(url),let d=r.json["data"] as? [String:Any] {
                    for number in (d["asns"] as? [Any] ?? []).prefix(2) { await asn(String(describing:number),emit:emit) }
                }
            }
            group.addTask {
                let name: String
                if let ipv4=IPv4Address(value) { name=ipv4.rawValue.reversed().map(String.init).joined(separator:".")+".in-addr.arpa" }
                else { name=IPv6Address(value)!.rawValue.map { String(format:"%02x",$0) }.joined().reversed().map(String.init).joined(separator:".")+".ip6.arpa" }
                let url=OSINTJSON.url("https://dns.google/resolve",["name":name,"type":"PTR"])
                await source("Domains & networks","Reverse DNS",url,emit:emit) { r in
                    let values=(r.json["Answer"] as? [[String:Any]] ?? []).compactMap { $0["data"] as? String }
                    return [OSINTFinding(category:"Domains & networks",title:"Reverse DNS",detail:values.isEmpty ? "No PTR answer returned" : values.joined(separator:"\n"),source:url.absoluteString,state:values.isEmpty ? .notFound : .found,evidence:r.text,pivots:values,facts:values.isEmpty ? nil : ["Reverse DNS":values.joined(separator:"\n")])]
                }
            }
        }
    }
    func entities(_ query: String, kind: OSINTKind? = nil, emit: @escaping Emit) async {
        let collected=OSINTWebCandidates()
        let url=OSINTJSON.url("https://www.wikidata.org/w/api.php",["action":"wbsearchentities","search":query,"language":"en","format":"json","limit":"10"])
        await source("Public records","Wikidata",url,emit:{ row in await collected.append(row);await emit(row) }) { r in
            guard let items=r.json["search"] as? [[String:Any]] else { return [Self.invalid("Wikidata",r)] }
            if items.isEmpty { return [OSINTFinding(category:"Public records",title:"Wikidata",detail:"No matching entities returned",source:url.absoluteString,evidence:r.text)] }
            return items.map { item in OSINTFinding(category:"Public records",title:item["label"] as? String ?? query,detail:item["description"] as? String ?? "Unverified record candidate",source:"https://www.wikidata.org/wiki/\(item["id"] ?? "")",state:.reference,evidence:OSINTJSON.text(item),facts:OSINTFacts.compact(["Name":OSINTFacts.text(item["label"]),"Description":OSINTFacts.text(item["description"])])) }
        }
        for row in await collected.values.prefix(3) where row.state == .reference {
            guard let id=URL(string:row.source)?.lastPathComponent,id.range(of:#"^Q[0-9]+$"#,options:.regularExpression) != nil else { continue }
            await entityDetails(id,kind:kind,emit:emit)
        }
    }
    func company(_ query: String, emit: @escaping Emit) async {
        let url=OSINTJSON.url("https://api.gleif.org/api/v1/lei-records",["filter[entity.legalName]":query,"page[size]":"15"])
        await source("Companies","Legal entity records",url,emit:emit) { r in
            guard let items=r.json["data"] as? [[String:Any]] else { return [Self.invalid("Legal entity records",r)] }
            if items.isEmpty { return [OSINTFinding(category:"Companies",title:"GLEIF legal entities",detail:"No LEI records returned; this does not rule out a company",source:url.absoluteString,evidence:r.text)] }
            return items.map { item in
                let a=item["attributes"] as? [String:Any] ?? [:], e=a["entity"] as? [String:Any] ?? [:], n=e["legalName"] as? [String:Any] ?? [:]
                let lei=a["lei"] as? String ?? item["id"] as? String ?? ""
                return OSINTFinding(category:"Companies",title:n["name"] as? String ?? query,detail:OSINTFacts.summary(OSINTFacts.company(item),fallback:"LEI \(lei)"),source:"https://search.gleif.org/#/record/"+lei,state:.possible,evidence:OSINTJSON.text(item),facts:OSINTFacts.company(item))
            }
        }
    }
    func page(_ url: URL, category: String = "Linked websites", includeLinks: Bool = true, subject: String? = nil, kind: OSINTKind? = nil, emit: @escaping Emit) async {
        await source(category,"Website source",url,emit:emit) { r in
            let html=r.text
            if Self.blockedPage(html) { return [OSINTFinding(category:category,title:url.host ?? "Website",detail:"The page returned a login, error or browser challenge; no page facts were retrieved",source:url.absoluteString,state:.unavailable,evidence:html)] }
            var facts=OSINTFacts.html(html)
            if let subject,let kind {
                guard let match=Self.relevance(html,facts:facts,page:r.url,subject:subject,kind:kind) else {
                    return [OSINTFinding(category:category,title:url.host ?? "Retrieved page",detail:"Page retrieved, but no matching subject or explicit source relationship was found",source:r.url.absoluteString,state:.notFound,evidence:html)]
                }
                facts["Match basis"]=match.basis
                if let passage=match.passage { facts["Matched passage"]=passage }
                facts["Match meaning"]=kind == .phone ? "Published number; assignment and subscriber ownership are not established." : kind == .email ? "Published email address; mailbox activity and ownership are not established." : "A cited public connection, not proof that shared names or accounts identify the same person."
            }
            let title=facts["Name"] ?? facts["Page title"] ?? url.host ?? "Website"
            let links=Self.matches(#"(?is)\bhref\s*=\s*["']([^"']+)["']"#,html).compactMap { URL(string:Self.decode($0),relativeTo:r.url)?.absoluteURL }.filter { ["https","http"].contains($0.scheme ?? "") }
            let external=Array(Set(links.filter { $0.host != r.url.host }.map(\.absoluteString))).sorted()
            let headers=r.headers.filter { ["content-type","date","last-modified","etag","server"].contains($0.key.lowercased()) }
            let root=OSINTFinding(category:category,title:title,detail:OSINTFacts.summary(facts.filter { $0.key != "Page title" },fallback:"Page retrieved; no descriptive details were published"),source:r.url.absoluteString,state:subject != nil ? .possible : .found,evidence:OSINTJSON.text(["status":r.status,"headers":headers,"html":html]),pivots:external,facts:facts)
            return [root] + (includeLinks ? external.prefix(30).map { link in
                OSINTFinding(category:OSINTKind.detect(link) == .social ? "Public profiles" : "Linked websites",title:URL(string:link)?.host ?? link,detail:link,source:link,state:.reference,evidence:"Linked in the retrieved source of \(r.url.absoluteString)",pivots:[link])
            } : [])
        }
    }
    func web(_ query: String, subject: String? = nil, kind: OSINTKind? = nil, emit: @escaping Emit) async {
        let candidates=OSINTWebCandidates()
        let record: Emit = { finding in
            if await candidates.appendUnique(finding) { await emit(finding) }
        }
        let lead=subject ?? query
        let terms=kind.map { OSINTIdentity.queries(lead,kind:$0,region:phoneRegion) } ?? [query]
        let configured=searx.trimmingCharacters(in:.whitespacesAndNewlines)
        await withTaskGroup(of:Void.self) { group in
            for term in terms {
                group.addTask {
                    if !configured.isEmpty,let base=Self.webURL(configured) {
                        let url=OSINTJSON.url(base.appendingPathComponent("search").absoluteString,["q":term,"format":"json"])
                        await source("Web results","Web search",url,emit:record) { r in
                            guard let results=r.json["results"] as? [[String:Any]] else { return [Self.invalid("Web search",r)] }
                            return results.prefix(12).compactMap { item in
                                guard let raw=item["url"] as? String,let target=URL(string:raw),OSINTIdentity.publicLead(target) else { return nil }
                                return OSINTFinding(category:"Web results",title:item["title"] as? String ?? lead,detail:item["content"] as? String ?? "",source:OSINTIdentity.canonical(target),state:.possible,evidence:OSINTJSON.text(item),pivots:[raw],facts:["Discovery query":term])
                            }
                        }
                    } else {
                        let url=OSINTJSON.url("https://html.duckduckgo.com/html/",["q":term])
                        await source("Web results","Web search",url,emit:record) { r in
                            let blocks=Self.matches(#"(?is)<a\b[^>]*class=["'][^"']*result__a[^"']*["'][^>]*>.*?</a>"#,r.text,group:0)
                            let results=blocks.compactMap { block -> OSINTFinding? in
                                guard let href=Self.matches(#"(?is)href=["']([^"']+)["']"#,block).first else { return nil }
                                let raw=Self.decode(href),resolved=URL(string:raw,relativeTo:url)?.absoluteURL
                                let target=resolved.flatMap { URLComponents(url:$0,resolvingAgainstBaseURL:true)?.queryItems?.first { $0.name=="uddg" }?.value } ?? resolved?.absoluteString ?? raw
                                guard let link=URL(string:target),OSINTIdentity.publicLead(link) else { return nil }
                                return OSINTFinding(category:"Web results",title:Self.plain(block),detail:link.host ?? target,source:OSINTIdentity.canonical(link),state:.possible,evidence:block,pivots:[target],facts:["Discovery query":term])
                            }
                            return results.isEmpty ? [OSINTFinding(category:"Sources",title:"DuckDuckGo search",detail:"No extractable results returned; trying another public search source",source:url.absoluteString,state:.unavailable,evidence:r.text)] : results
                        }
                    }
                }
            }
        }
        // RSS is parsed as XML with external entities disabled. Search snippets
        // remain leads; fetched page content must independently match the query.
        if configured.isEmpty,!(await candidates.values.contains { $0.category=="Web results" && $0.state == .possible }) {
            await withTaskGroup(of:Void.self) { group in
                for term in terms.prefix(2) {
                    group.addTask {
                        let url=OSINTJSON.url("https://www.bing.com/search",["q":term,"format":"rss"])
                        await source("Web results","Bing search feed",url,emit:record) { r in
                            let rows=OSINTSearchFeed.results(r.data)
                            return rows.isEmpty ? [Self.invalid("Bing search feed",r)] : rows.map { item in
                                OSINTFinding(category:"Web results",title:item.title,detail:item.summary,source:item.url,state:.possible,evidence:OSINTJSON.text(["query":term,"title":item.title,"snippet":item.summary,"url":item.url]),pivots:[item.url],facts:["Discovery query":term])
                            }
                        }
                    }
                }
            }
        }
        let results=await candidates.values.filter { $0.category=="Web results" && $0.state == .possible }
        // Distribute retrieval across hosts, rather than spending every slot on
        // repeated search-index copies of one website.
        let ranked=results.sorted { a,b in
            let x=a.title.localizedCaseInsensitiveContains(lead),y=b.title.localizedCaseInsensitiveContains(lead)
            return x != y ? x : a.source<b.source
        }
        var counts:[String:Int]=[:],selected:[URL]=[],later:[URL]=[]
        for row in ranked {
            guard let url=URL(string:row.source) else { continue }
            let host=url.host ?? "";counts[host,default:0]+=1
            if counts[host,default:0]<=2 { selected.append(url) } else { later.append(url) }
        }
        selected=Array((selected+later).prefix(10))
        let pages=OSINTWebCandidates()
        for start in stride(from:0,to:selected.count,by:4) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of:Void.self) { group in
                for url in selected[start..<min(start+4,selected.count)] {
                    group.addTask {
                        await self.page(url,category:"Retrieved pages",includeLinks:false,subject:lead,kind:kind) { row in
                            await pages.append(row);await record(row)
                        }
                    }
                }
            }
        }
        await follow(pages:await pages.values,subject:lead,kind:kind,emit:record)
        let q="\""+lead.replacingOccurrences(of:"\"",with:"")+"\""
        await emit(OSINTFinding(category:"More sources",title:"Continue in the browser",detail:"Open an exact web search",source:OSINTJSON.url("https://www.google.com/search",["q":q]).absoluteString,state:.reference))
    }
    struct Site: Sendable { var name: String; var rule: [String:String]; var missing: [String] }
    func usernames(_ username: String, emit: @escaping Emit) async {
        await knownProfiles(username,emit:emit)
        do {
            let response=try await fetch(Self.catalogURL)
            guard response.status==200,let catalog=(try? JSONSerialization.jsonObject(with:response.data)) as? [String:Any] else { throw URLError(.cannotParseResponse) }
            let preferred=["GitHub","GitLab","Reddit","Instagram","Twitter","TikTok","YouTube","Bluesky","HackerNews","Keybase","Steam","Twitch","Pinterest","Medium","Dev.to","Codeberg","Chess","Vimeo","Flickr","SoundCloud"]
            let keys=catalog.keys.filter { !$0.hasPrefix("$") }.sorted {
                let a=preferred.firstIndex(of:$0) ?? 999,b=preferred.firstIndex(of:$1) ?? 999
                return a==b ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending : a<b
            }
            let sites=keys.compactMap { name -> Site? in
                if ["GitHub","GitLab","HackerNews","Hacker News"].contains(name) { return nil }
                guard let d=catalog[name] as? [String:Any],let url=d["url"] as? String,let type=d["errorType"] as? String else { return nil }
                let method=d["request_method"] as? String ?? "GET"
                if method != "GET" && method != "HEAD" { return nil }
                if let regex=d["regexCheck"] as? String,username.range(of:regex,options:.regularExpression)==nil { return nil }
                return Site(name:name,rule:["url":url,"probe":d["urlProbe"] as? String ?? url,"type":type],missing:(d["errorMsg"] as? [String]) ?? (d["errorMsg"] as? String).map { [$0] } ?? [])
            }
            let selected=allSites ? sites : Array(sites.prefix(30))
            if selected.isEmpty { return }
            for start in stride(from:0,to:selected.count,by:8) {
                try Task.checkCancellation()
                await withTaskGroup(of:Void.self) { group in
                    for site in selected[start..<min(start+8,selected.count)] {
                        group.addTask {
                            let encoded=username.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed.subtracting(CharacterSet(charactersIn:"/?#%"))) ?? username
                            guard var url=URL(string:site.rule["probe"]!.replacingOccurrences(of:"{}",with:encoded)),let profile=URL(string:site.rule["url"]!.replacingOccurrences(of:"{}",with:encoded)),OSINTIdentity.publicLead(url),OSINTIdentity.publicLead(profile) else { return }
                            if profile.host=="github.com" { url=URL(string:"https://api.github.com/users/"+encoded)! }
                            do {
                                let r=try await fetch(url)
                                var state=Self.profileState(site,r,profile:profile)
                                if state == .possible,r.json.isEmpty {
                                    let control="search-check-"+UUID().uuidString.lowercased()
                                    if let other=URL(string:site.rule["probe"]!.replacingOccurrences(of:"{}",with:control)),OSINTIdentity.publicLead(other) {
                                        do {
                                            let negative=try await fetch(other)
                                            if (200..<300).contains(negative.status),Self.profileFingerprint(r.text,handle:username)==Self.profileFingerprint(negative.text,handle:control) { state = .unavailable }
                                        } catch { if Task.isCancelled { return } }
                                    }
                                }
                                let facts=state == .possible ? (r.json.isEmpty ? OSINTFacts.html(r.text) : OSINTFacts.profileJSON(r.json)) : [:]
                                let details=state == .possible ? OSINTFacts.summary(facts.filter { $0.key != "Page title" },fallback:"Profile endpoint responded; public profile details could not be retrieved") : state == .notFound ? "No matching public profile returned" : Self.status(r.status)+" · could not verify profile"
                                let website=facts["Website"].flatMap(Self.webURL)?.absoluteString
                                await emit(OSINTFinding(category:"Public profiles",title:site.name,detail:details,source:profile.absoluteString,state:state,evidence:OSINTJSON.text(["checkURL":url.absoluteString,"responseURL":r.url.absoluteString,"httpStatus":r.status,"rule":site.rule,"body":r.text]),pivots:state == .possible ? ([profile.absoluteString]+(website.map { [$0] } ?? [])) : [],facts:facts.isEmpty ? nil : facts))
                            } catch { if !Task.isCancelled { await emit(OSINTFinding(category:"Public profiles",title:site.name,detail:error.localizedDescription,source:profile.absoluteString,state:.unavailable)) } }
                        }
                    }
                }
            }
        } catch { if !Task.isCancelled { await emit(OSINTFinding(category:"Public profiles",title:"Username source catalog",detail:"The Sherlock catalog could not be loaded: "+error.localizedDescription,source:Self.catalogURL.absoluteString,state:.unavailable)) } }
    }
    static func profileState(_ site: Site, _ r: OSINTHTTP.Response, profile: URL) -> OSINTFinding.State {
        if r.status==404 || r.status==410 { return .notFound }
        guard (200..<300).contains(r.status) else { return .unavailable }
        if blockedPage(r.text) { return .unavailable }
        if r.url.host != profile.host && r.url.host != "api.github.com" { return .unavailable }
        let lower=r.text.lowercased()
        if ["verify you are human","cf-chl-","g-recaptcha","unusual traffic","just a moment...","access denied"].contains(where:lower.contains) { return .unavailable }
        switch site.rule["type"] {
        case "status_code": return .possible
        case "message":
            guard !site.missing.isEmpty else { return .unavailable }
            return site.missing.contains(where:r.text.contains) ? .notFound : .possible
        case "response_url": return r.url.host==profile.host && r.url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))==profile.path.trimmingCharacters(in:CharacterSet(charactersIn:"/")) ? .possible : .unavailable
        default: return .unavailable
        }
    }
    static func profileFingerprint(_ html: String, handle: String) -> String {
        plain(html.replacingOccurrences(of:#"(?is)<(script|style)\b[^>]*>.*?</\1>"#,with:"",options:.regularExpression))
            .replacingOccurrences(of:handle,with:"{handle}",options:.caseInsensitive)
            .replacingOccurrences(of:#"\s+"#,with:" ",options:.regularExpression)
    }
    static func matches(_ pattern: String, _ text: String, group: Int = 1) -> [String] {
        guard let regex=try? NSRegularExpression(pattern:pattern) else { return [] }
        return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { m in guard group<m.numberOfRanges,let range=Range(m.range(at:group),in:text) else { return nil }; return String(text[range]) }
    }
    static func invalid(_ title: String, _ response: OSINTHTTP.Response) -> OSINTFinding {
        OSINTFinding(category:"Sources",title:title,detail:"The source did not return the expected data format",source:response.url.absoluteString,state:.unavailable,evidence:response.text)
    }
    static func plain(_ html: String) -> String { decode(html.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression)).trimmingCharacters(in:.whitespacesAndNewlines) }
    static func decode(_ html: String) -> String {
        var value=html.replacingOccurrences(of:"&amp;",with:"&").replacingOccurrences(of:"&quot;",with:"\"").replacingOccurrences(of:"&apos;",with:"'").replacingOccurrences(of:"&nbsp;",with:" ").replacingOccurrences(of:"&lt;",with:"<").replacingOccurrences(of:"&gt;",with:">")
        if let regex=try? NSRegularExpression(pattern:#"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in:value,range:NSRange(value.startIndex...,in:value)).reversed() {
                guard let r=Range(match.range(at:1),in:value),let whole=Range(match.range,in:value) else { continue }
                let token=String(value[r]),hex=token.hasPrefix("x")
                if let number=UInt32(hex ? String(token.dropFirst()) : token,radix:hex ? 16 : 10),let scalar=UnicodeScalar(number) { value.replaceSubrange(whole,with:String(scalar)) }
            }
        }
        return value
    }
    private static func strings(_ value: Any?, key: String) -> [String] { (value as? [[String:Any]] ?? []).compactMap { $0[key] as? String } }
}
