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
        let (data,response) = try await session().proxyData(for:request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard data.count <= 16*1024*1024 else { throw NSError(domain:"OSINT",code:2,userInfo:[NSLocalizedDescriptionKey:"The source response exceeded 16 MB; open it directly to inspect it."]) }
        return Response(data:data,status:http.statusCode,url:Store.testing && target != url ? url : (http.url ?? url),headers:http.allHeaderFields.reduce(into:[:]) { $0[String(describing:$1.key)]=String(describing:$1.value) })
    }
}

struct OSINTService: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> OSINTHTTP.Response
    typealias Emit = @Sendable (OSINTFinding) async -> Void
    var fetch: Fetch
    var searx = ""
    var allSites = false
    init(fetch: @escaping Fetch, searx: String = "", allSites: Bool = false) { self.fetch=fetch; self.searx=searx; self.allSites=allSites }
    static let catalogURL = URL(string:"https://raw.githubusercontent.com/sherlock-project/sherlock/master/sherlock_project/resources/data.json")!
    func collect(_ context: OSINTContext, kind: OSINTKind, emit: @escaping Emit) async {
        let query = context.text.trimmingCharacters(in:.whitespacesAndNewlines)
        await withTaskGroup(of:Void.self) { group in
            if [.domain,.website,.social].contains(kind), let host = Self.host(query) {
                group.addTask {
                    if IPv4Address(host) != nil || IPv6Address(host) != nil { await self.ip(host,emit:emit) }
                    else { await self.domain(host,emit:emit) }
                }
            }
            if [.website,.social].contains(kind), let u = Self.webURL(query) {
                group.addTask { await self.page(u,emit:emit) }
            }
            if kind == .username {
                group.addTask { await self.usernames(query.trimmingCharacters(in:CharacterSet(charactersIn:"@")),emit:emit) }
            }
            if kind == .ip { group.addTask { await self.ip(query,emit:emit) } }
            if kind == .company { group.addTask { await self.company(query,emit:emit) } }
            if kind == .phone {
                let value = OSINTPhone.describe(query)
                await emit(OSINTFinding(category:"Phone numbering",title:value["international"] as? String ?? query,
                    detail:(value["numberingRegions"] as? [String])?.joined(separator:", ") ?? value["error"] as? String ?? "Numbering metadata",
                    source:"https://github.com/google/libphonenumber",state:value["error"] == nil ? .found : .unavailable,evidence:OSINTJSON.text(value)))
            }
            if [.person,.company].contains(kind) { group.addTask { await self.entities(query,emit:emit) } }
            if kind != .image { group.addTask { await self.web(query,emit:emit) } }
            await group.waitForAll()
        }
    }
    static func webURL(_ query: String) -> URL? {
        guard let url = URL(string:query.contains("://") ? query : "https://"+query), ["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host != nil else { return nil }
        return url
    }
    static func host(_ query: String) -> String? { webURL(query)?.host?.lowercased() }
    private func source(_ category: String, _ title: String, _ url: URL, emit: Emit,
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
        await withTaskGroup(of:Void.self) { group in
            group.addTask {
                let url = URL(string:"https://rdap.org/domain/"+host)!
                await source("Domains & networks","Domain registration",url,emit:emit) { response in
                    let j=response.json
                    guard j["ldhName"] != nil || j["unicodeName"] != nil else { return [Self.invalid("Domain registration",response)] }
                    return [OSINTFinding(category:"Domains & networks",title:"Domain registration",detail:(j["ldhName"] as? String ?? host)+" · RDAP",source:response.url.absoluteString,evidence:response.text,pivots:Self.strings(j["nameservers"],key:"ldhName"))]
                }
            }
            for type in ["A","AAAA","MX","NS","TXT","CAA"] {
                group.addTask {
                    let url=OSINTJSON.url("https://dns.google/resolve",["name":host,"type":type])
                    await source("Domains & networks","\(type) records",url,emit:emit) { response in
                        let j=response.json, answers=j["Answer"] as? [[String:Any]] ?? []
                        let values=answers.compactMap { $0["data"] as? String }
                        let status=j["Status"] as? Int ?? -1
                        return [OSINTFinding(category:"Domains & networks",title:"\(type) records",detail:values.isEmpty ? (status==0 ? "No \(type) answers" : "DNS status \(status)") : values.joined(separator:"\n"),source:url.absoluteString,state:status==0 ? (values.isEmpty ? .notFound : .found) : .unavailable,evidence:response.text,pivots:type=="A" || type=="AAAA" ? values : [])]
                    }
                }
            }
            group.addTask {
                let url=OSINTJSON.url("https://crt.sh/",["q":"%."+host,"output":"json"])
                await source("Domains & networks","Certificate names",url,emit:emit) { response in
                    guard let records=(try? JSONSerialization.jsonObject(with:response.data)) as? [[String:Any]] else { return [Self.invalid("Certificate names",response)] }
                    let names=Array(Set(records.flatMap { ($0["name_value"] as? String ?? "").components(separatedBy:"\n") })).filter { !$0.isEmpty }.sorted()
                    return [OSINTFinding(category:"Domains & networks",title:"Certificate names",detail:names.isEmpty ? "No names returned" : names.joined(separator:"\n"),source:url.absoluteString,state:names.isEmpty ? .notFound : .found,evidence:response.text,pivots:names.filter { !$0.contains("*") })]
                }
            }
            group.addTask {
                let url=OSINTJSON.url("https://web.archive.org/cdx/search/cdx",["url":host+"/*","output":"json","filter":"statuscode:200","collapse":"urlkey","limit":"30","fl":"timestamp,original,statuscode,mimetype"])
                await source("Domains & networks","Archived pages",url,emit:emit) { response in
                    guard let rows=(try? JSONSerialization.jsonObject(with:response.data)) as? [[String]] else { return [Self.invalid("Archived pages",response)] }
                    let entries=rows.dropFirst().filter { $0.count>=2 }
                    return entries.map { OSINTFinding(category:"Archived pages",title:$0[1],detail:"Archived \($0[0])",source:"https://web.archive.org/web/\($0[0])/\($0[1])",evidence:OSINTJSON.text($0),pivots:[$0[1]]) } + (entries.isEmpty ? [OSINTFinding(category:"Archived pages",title:"Archived pages",detail:"No captures returned for this query",source:url.absoluteString,evidence:response.text)] : [])
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
                    return [OSINTFinding(category:"Domains & networks",title:r.json["name"] as? String ?? "Network registration",detail:"\(r.json["startAddress"] ?? "") – \(r.json["endAddress"] ?? "")\nRegistration country: \(r.json["country"] ?? "Not supplied") · not device location",source:r.url.absoluteString,evidence:r.text)]
                }
            }
            group.addTask {
                let url=OSINTJSON.url("https://stat.ripe.net/data/network-info/data.json",["resource":value])
                await source("Domains & networks","Announcing networks",url,emit:emit) { r in
                    let d=r.json["data"] as? [String:Any] ?? [:], asns=(d["asns"] as? [Any] ?? []).map { let value=String(describing:$0); return value.hasPrefix("AS") ? value : "AS"+value }
                    return [OSINTFinding(category:"Domains & networks",title:"Announcing networks",detail:asns.joined(separator:", ")+" · \(d["prefix"] ?? "No prefix returned")",source:url.absoluteString,evidence:r.text)]
                }
            }
            group.addTask {
                let name: String
                if let ipv4=IPv4Address(value) { name=ipv4.rawValue.reversed().map(String.init).joined(separator:".")+".in-addr.arpa" }
                else { name=IPv6Address(value)!.rawValue.map { String(format:"%02x",$0) }.joined().reversed().map(String.init).joined(separator:".")+".ip6.arpa" }
                let url=OSINTJSON.url("https://dns.google/resolve",["name":name,"type":"PTR"])
                await source("Domains & networks","Reverse DNS",url,emit:emit) { r in
                    let values=(r.json["Answer"] as? [[String:Any]] ?? []).compactMap { $0["data"] as? String }
                    return [OSINTFinding(category:"Domains & networks",title:"Reverse DNS",detail:values.isEmpty ? "No PTR answer returned" : values.joined(separator:"\n"),source:url.absoluteString,evidence:r.text,pivots:values)]
                }
            }
        }
    }
    func entities(_ query: String, emit: @escaping Emit) async {
        let url=OSINTJSON.url("https://www.wikidata.org/w/api.php",["action":"wbsearchentities","search":query,"language":"en","format":"json","limit":"10"])
        await source("Public records","Wikidata",url,emit:emit) { r in
            guard let items=r.json["search"] as? [[String:Any]] else { return [Self.invalid("Wikidata",r)] }
            if items.isEmpty { return [OSINTFinding(category:"Public records",title:"Wikidata",detail:"No matching entities returned",source:url.absoluteString,evidence:r.text)] }
            return items.map { item in OSINTFinding(category:"Public records",title:item["label"] as? String ?? query,detail:item["description"] as? String ?? "Possible entity match",source:"https://www.wikidata.org/wiki/\(item["id"] ?? "")",state:.possible,evidence:OSINTJSON.text(item)) }
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
                return OSINTFinding(category:"Companies",title:n["name"] as? String ?? query,detail:"LEI \(lei) · \(e["status"] ?? "")",source:"https://search.gleif.org/#/record/"+lei,state:.possible,evidence:OSINTJSON.text(item))
            }
        }
    }
    func page(_ url: URL, emit: @escaping Emit) async {
        await source("Linked websites","Website source",url,emit:emit) { r in
            let html=r.text
            let title=Self.matches(#"(?is)<title[^>]*>(.*?)</title>"#,html).first.map(Self.plain) ?? url.host ?? "Website"
            let links=Self.matches(#"(?is)\bhref\s*=\s*["']([^"']+)["']"#,html).compactMap { URL(string:Self.decode($0),relativeTo:r.url)?.absoluteURL }.filter { ["https","http"].contains($0.scheme ?? "") }
            let external=Array(Set(links.filter { $0.host != r.url.host }.map(\.absoluteString))).sorted()
            return [OSINTFinding(category:"Linked websites",title:title,detail:r.url.absoluteString,source:r.url.absoluteString,evidence:OSINTJSON.text(["status":r.status,"headers":r.headers,"html":html]),pivots:external)] + external.prefix(30).map { link in
                OSINTFinding(category:OSINTKind.detect(link) == .social ? "Public profiles" : "Linked websites",title:URL(string:link)?.host ?? link,detail:link,source:link,state:.reference,evidence:"Linked in the retrieved source of \(r.url.absoluteString)",pivots:[link])
            }
        }
    }
    func web(_ query: String, emit: @escaping Emit) async {
        let configured=searx.trimmingCharacters(in:.whitespacesAndNewlines)
        if !configured.isEmpty, let base=Self.webURL(configured) {
            let url=OSINTJSON.url(base.appendingPathComponent("search").absoluteString,["q":query,"format":"json"])
            await source("Web results","Web search",url,emit:emit) { r in
                guard let results=r.json["results"] as? [[String:Any]] else { return [Self.invalid("Web search",r)] }
                return results.map { OSINTFinding(category:"Web results",title:$0["title"] as? String ?? query,detail:$0["content"] as? String ?? "",source:$0["url"] as? String ?? url.absoluteString,state:.possible,evidence:OSINTJSON.text($0),pivots:[$0["url"] as? String ?? ""]) } + (results.isEmpty ? [OSINTFinding(category:"Web results",title:"Web search",detail:"No results returned by the configured instance",source:url.absoluteString,evidence:r.text)] : [])
            }
        } else {
            let url=OSINTJSON.url("https://html.duckduckgo.com/html/",["q":query])
            await source("Web results","Web search",url,emit:emit) { r in
                let blocks=Self.matches(#"(?is)<a\b[^>]*class=["'][^"']*result__a[^"']*["'][^>]*>.*?</a>"#,r.text,group:0)
                let results=blocks.compactMap { block -> OSINTFinding? in
                    guard let href=Self.matches(#"(?is)href=["']([^"']+)["']"#,block).first else { return nil }
                    let raw=Self.decode(href), resolved=URL(string:raw,relativeTo:url)?.absoluteURL
                    let target=resolved.flatMap { URLComponents(url:$0,resolvingAgainstBaseURL:true)?.queryItems?.first { $0.name=="uddg" }?.value } ?? resolved?.absoluteString ?? raw
                    guard let link=URL(string:target),["https","http"].contains(link.scheme ?? "") else { return nil }
                    return OSINTFinding(category:"Web results",title:Self.plain(block),detail:link.host ?? target,source:target,state:.possible,evidence:block,pivots:[target])
                }
                return results.isEmpty ? [OSINTFinding(category:"Web results",title:"Web search",detail:"No extractable results; this source may require a browser check. Open the source, or configure your own SearXNG instance.",source:url.absoluteString,state:.unavailable,evidence:r.text)] : results
            }
        }
        for (name,base) in [("Search the web","https://www.google.com/search"),("Search public profiles","https://www.google.com/search")] {
            let q=name=="Search public profiles" ? "\"\(query)\" (site:linkedin.com OR site:instagram.com OR site:facebook.com OR site:x.com)" : "\"\(query)\""
            await emit(OSINTFinding(category:"More sources",title:name,detail:"Open this search in the browser",source:OSINTJSON.url(base,["q":q]).absoluteString,state:.reference))
        }
    }
    struct Site: Sendable { var name: String; var rule: [String:String]; var missing: [String] }
    func usernames(_ username: String, emit: @escaping Emit) async {
        do {
            let response=try await fetch(Self.catalogURL)
            guard response.status==200,let catalog=(try? JSONSerialization.jsonObject(with:response.data)) as? [String:Any] else { throw URLError(.cannotParseResponse) }
            let preferred=["GitHub","GitLab","Reddit","Instagram","Twitter","TikTok","YouTube","Bluesky","HackerNews","Keybase","Steam","Twitch","Pinterest","Medium","Dev.to","Codeberg","Chess","Vimeo","Flickr","SoundCloud"]
            let keys=catalog.keys.filter { !$0.hasPrefix("$") }.sorted {
                let a=preferred.firstIndex(of:$0) ?? 999,b=preferred.firstIndex(of:$1) ?? 999
                return a==b ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending : a<b
            }
            let sites=keys.compactMap { name -> Site? in
                guard let d=catalog[name] as? [String:Any],let url=d["url"] as? String,let type=d["errorType"] as? String else { return nil }
                let method=d["request_method"] as? String ?? "GET"
                if method != "GET" && method != "HEAD" { return nil }
                if let regex=d["regexCheck"] as? String,username.range(of:regex,options:.regularExpression)==nil { return nil }
                return Site(name:name,rule:["url":url,"probe":d["urlProbe"] as? String ?? url,"type":type],missing:(d["errorMsg"] as? [String]) ?? (d["errorMsg"] as? String).map { [$0] } ?? [])
            }
            let selected=allSites ? sites : Array(sites.prefix(30))
            guard !selected.isEmpty else { throw URLError(.cannotParseResponse) }
            for start in stride(from:0,to:selected.count,by:8) {
                try Task.checkCancellation()
                await withTaskGroup(of:Void.self) { group in
                    for site in selected[start..<min(start+8,selected.count)] {
                        group.addTask {
                            let encoded=username.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed.subtracting(CharacterSet(charactersIn:"/?#%"))) ?? username
                            guard let url=URL(string:site.rule["probe"]!.replacingOccurrences(of:"{}",with:encoded)),let profile=URL(string:site.rule["url"]!.replacingOccurrences(of:"{}",with:encoded)) else { return }
                            do {
                                let r=try await fetch(url)
                                let state=Self.profileState(site,r,profile:profile)
                                await emit(OSINTFinding(category:"Public profiles",title:site.name,detail:state == .possible ? profile.absoluteString : state == .notFound ? "No matching public profile returned" : Self.status(r.status)+" · could not verify profile",source:profile.absoluteString,state:state,evidence:OSINTJSON.text(["checkURL":url.absoluteString,"responseURL":r.url.absoluteString,"httpStatus":r.status,"rule":site.rule,"body":r.text]),pivots:state == .possible ? [profile.absoluteString] : []))
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
    static func matches(_ pattern: String, _ text: String, group: Int = 1) -> [String] {
        guard let regex=try? NSRegularExpression(pattern:pattern) else { return [] }
        return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { m in guard group<m.numberOfRanges,let range=Range(m.range(at:group),in:text) else { return nil }; return String(text[range]) }
    }
    static func invalid(_ title: String, _ response: OSINTHTTP.Response) -> OSINTFinding {
        OSINTFinding(category:"Sources",title:title,detail:"The source did not return the expected data format",source:response.url.absoluteString,state:.unavailable,evidence:response.text)
    }
    static func plain(_ html: String) -> String { decode(html.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression)).trimmingCharacters(in:.whitespacesAndNewlines) }
    static func decode(_ html: String) -> String {
        html.replacingOccurrences(of:"&amp;",with:"&").replacingOccurrences(of:"&quot;",with:"\"").replacingOccurrences(of:"&#39;",with:"'").replacingOccurrences(of:"&lt;",with:"<").replacingOccurrences(of:"&gt;",with:">")
    }
    private static func strings(_ value: Any?, key: String) -> [String] { (value as? [[String:Any]] ?? []).compactMap { $0[key] as? String } }
}
