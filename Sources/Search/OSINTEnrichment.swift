import Foundation

final class OSINTSearchFeed: NSObject, XMLParserDelegate {
    struct Item { var title="";var summary="";var url="" }
    private var items:[Item]=[]
    private var item:Item?
    private var element=""
    static func results(_ data: Data) -> [Item] {
        let text=String(decoding:data,as:UTF8.self).uppercased()
        guard data.count<=2*1024*1024,!text.contains("<!DOCTYPE"),!text.contains("<!ENTITY") else { return [] }
        let reader=OSINTSearchFeed(),parser=XMLParser(data:data)
        parser.shouldResolveExternalEntities=false;parser.delegate=reader
        guard parser.parse() else { return [] }
        return Array(reader.items.filter { URL(string:$0.url).map(OSINTIdentity.publicLead)==true }.prefix(12))
    }
    func parser(_ parser: XMLParser,didStartElement name: String,namespaceURI: String?,qualifiedName: String?,attributes: [String:String]) {
        element=name;if name=="item" { item=Item() }
    }
    func parser(_ parser: XMLParser,foundCharacters text: String) {
        guard item != nil else { return }
        switch element { case "title":item?.title+=text;case "description":item?.summary+=text;case "link":item?.url+=text;default:break }
    }
    func parser(_ parser: XMLParser,didEndElement name: String,namespaceURI: String?,qualifiedName: String?) {
        if name=="item",let item { items.append(item);self.item=nil };element=""
    }
}

extension OSINTService {
    static func relevance(_ html: String,facts: [String:String],page: URL,subject: String,kind: OSINTKind) -> (basis:String,passage:String?)? {
        if kind == .social,let target=webURL(subject) {
            let key=OSINTIdentity.canonical(target)
            if OSINTIdentity.canonical(page)==key { return ("Retrieved the requested profile URL",nil) }
            let links=matches(#"(?is)\bhref\s*=\s*["']([^"']+)["']"#,html).compactMap { URL(string:decode($0),relativeTo:page)?.absoluteURL }
                + (facts["Linked profiles"] ?? "").components(separatedBy:.newlines).compactMap(URL.init(string:))
            return links.contains { OSINTIdentity.canonical($0)==key } ? ("This source explicitly links to "+target.absoluteString,nil) : nil
        }
        if [.domain,.website].contains(kind),let host=host(subject),let current=page.host {
            if Registrable.sameSite(host,current,isSuffix:AtRest.systemSuffix) { return ("Published on the requested website",nil) }
            if let passage=OSINTFacts.passage(html,subject:host,kind:.email,facts:facts) { return ("Exact domain mention in retrieved content",passage) }
            let links=matches(#"(?is)\bhref\s*=\s*["']([^"']+)["']"#,html).compactMap { URL(string:decode($0),relativeTo:page)?.absoluteURL }
            return links.contains { $0.host.map { Registrable.sameSite(host,$0,isSuffix:AtRest.systemSuffix) } == true } ? ("This source explicitly links to the requested website",nil) : nil
        }
        if [.person,.company,.username,.phone,.email,.ip,.asn].contains(kind) {
            guard let passage=OSINTFacts.passage(html,subject:subject,kind:kind,facts:facts) else { return nil }
            return ("Exact subject mention in retrieved content",passage)
        }
        return nil
    }
    func asn(_ input: String, emit: @escaping Emit) async {
        let raw=input.uppercased().replacingOccurrences(of:"AS",with:"")
        guard let value=UInt32(raw),value>0 else { return }
        let id="AS\(value)",url=OSINTJSON.url("https://stat.ripe.net/data/as-overview/data.json",["resource":id])
        await source("Domains & networks","Network operator "+id,url,emit:emit) { r in
            guard let d=r.json["data"] as? [String:Any],d["holder"] != nil else { return [Self.invalid("Network operator "+id,r)] }
            let facts=OSINTFacts.compact(["ASN":id,"Organization":OSINTFacts.text(d["holder"]),"Announced":(d["announced"] as? Bool).map { $0 ? "Visible in RIPE RIS" : "Not currently observed by RIPE RIS" } ?? "","Registry":OSINTFacts.text((d["block"] as? [String:Any])?["name"])])
            return [OSINTFinding(category:"Domains & networks",title:id+" · "+OSINTFacts.text(d["holder"]),detail:OSINTFacts.summary(facts,fallback:id),source:url.absoluteString,evidence:r.text,facts:facts)]
        }
    }
    func entityDetails(_ id: String, kind: OSINTKind? = nil, emit: @escaping Emit) async {
        let url=URL(string:"https://www.wikidata.org/wiki/Special:EntityData/"+id+".json")!
        do {
            let response=try await fetch(url);try Task.checkCancellation()
            guard response.status==200,let entities=response.json["entities"] as? [String:[String:Any]],let entity=entities[id],entity["missing"]==nil else { return }
            let claims=entity["claims"] as? [String:[[String:Any]]] ?? [:]
            func values(_ property: String) -> [Any] {
                (claims[property] ?? []).filter { ($0["rank"] as? String) != "deprecated" }.compactMap {
                    (($0["mainsnak"] as? [String:Any])?["datavalue"] as? [String:Any])?["value"]
                }
            }
            let types=values("P31").compactMap { ($0 as? [String:Any])?["id"] as? String }
            let human=types.contains("Q5")
            let organization=["P159","P749","P355","P1454","P1278","P249"].contains { !values($0).isEmpty } || (!values("P571").isEmpty && !values("P856").isEmpty)
            if (kind == .person && !human) || (kind == .company && (human || !organization)) {
                let name=(entity["labels"] as? [String:[String:Any]])?["en"]?["value"] as? String ?? id
                await emit(OSINTFinding(category:"Public records",title:name,detail:"Related record; its type does not establish a matching \(kind == .person ? "person" : "organization")",source:"https://www.wikidata.org/wiki/"+id,state:.reference,evidence:response.text,facts:["Name":name,"Record type":types.joined(separator:", ")]))
                return
            }
            let associations=["P31":"Record type","P106":"Occupation","P108":"Employer","P159":"Headquarters","P127":"Owned by","P749":"Parent organization","P355":"Subsidiaries","P17":"Country"]
            var refs:[String:[String]]=[:]
            for property in associations.keys { refs[property]=values(property).compactMap { ($0 as? [String:Any])?["id"] as? String }.filter { $0.range(of:#"^Q[0-9]+$"#,options:.regularExpression) != nil } }
            let ids=Array(Set(refs.values.flatMap { $0 })).sorted().prefix(30)
            var labels:[String:String]=[:]
            if !ids.isEmpty {
                let labelURL=OSINTJSON.url("https://www.wikidata.org/w/api.php",["action":"wbgetentities","ids":ids.joined(separator:"|"),"props":"labels","languages":"en","format":"json"])
                if let r=try? await fetch(labelURL),r.status==200,let records=r.json["entities"] as? [String:[String:Any]] {
                    for (key,value) in records { labels[key]=((value["labels"] as? [String:[String:Any]])?["en"]?["value"] as? String) }
                }
            }
            var facts=OSINTFacts.compact(["Name":(entity["labels"] as? [String:[String:Any]])?["en"]?["value"] as? String ?? id,"Description":(entity["descriptions"] as? [String:[String:Any]])?["en"]?["value"] as? String ?? "","Wikidata ID":id])
            for (property,label) in associations {
                let names=(refs[property] ?? []).map { (labels[$0] ?? $0)+" ("+$0+")" }
                if !names.isEmpty { facts[label]=names.joined(separator:"\n") }
            }
            if let website=values("P856").compactMap({ $0 as? String }).first,let link=URL(string:website),OSINTIdentity.publicLead(link) { facts["Website"]=website }
            if let time=values("P571").compactMap({ ($0 as? [String:Any])?["time"] as? String }).first { facts["Founded"]=time.trimmingCharacters(in:CharacterSet(charactersIn:"+")) }
            let profiles:[(String,String)]=[("P2002","https://x.com/"),("P2013","https://www.facebook.com/"),("P2397","https://www.youtube.com/channel/"),("P2037","https://github.com/"),("P496","https://orcid.org/")]
            let links=profiles.flatMap { property,base in values(property).compactMap { $0 as? String }.compactMap { value -> String? in
                guard let path=value.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed.subtracting(CharacterSet(charactersIn:"/?#%"))) else { return nil };return base+path
            } }
            if !links.isEmpty { facts["Linked profiles"]=links.joined(separator:"\n") }
            facts["Match basis"]="Public knowledge-base candidate; verify identity against the cited record"
            let pivots=links+(facts["Website"].map { [$0] } ?? [])
            await emit(OSINTFinding(category:"Public records",title:facts["Name"] ?? id,detail:OSINTFacts.summary(facts,fallback:id,limit:7),source:"https://www.wikidata.org/wiki/"+id,state:.possible,evidence:response.text,pivots:pivots,facts:facts))
        } catch { if !Task.isCancelled { await emit(OSINTFinding(category:"Public records",title:"Wikidata record "+id,detail:error.localizedDescription,source:url.absoluteString,state:.unavailable)) } }
    }
    static func blockedPage(_ html: String) -> Bool {
        let lower=html.lowercased()
        if ["cf-chl-","verify you are human","just a moment...","unusual traffic"].contains(where:lower.contains) { return true }
        let title=matches(#"(?is)<title[^>]*>(.*?)</title>"#,html).first.map(plain)?.lowercased() ?? ""
        return ["sign in","log in","login","page not found","404 not found","access denied"].contains(title)
    }
    func email(_ query: String, emit: @escaping Emit) async {
        guard let address=OSINTIdentity.email(query),let domain=address.split(separator:"@").last else {
            await emit(OSINTFinding(category:"Email",title:"Email address",detail:"Enter a complete email address",source:"",state:.unavailable));return
        }
        await withTaskGroup(of:Void.self) { group in
            group.addTask { await self.dnsRecord(String(domain),type:"MX",title:"Mail delivery",emit:emit) }
            group.addTask { await self.dnsRecord(String(domain),type:"TXT",title:"Mail-domain TXT records",emit:emit) }
            group.addTask { await self.dnsPolicy(String(domain),emit:emit) }
        }
    }
    func dnsPolicy(_ host: String, emit: @escaping Emit) async {
        await dnsRecord("_dmarc."+host,type:"TXT",title:"DMARC policy",emit:emit)
    }
    func dnsRecord(_ host: String, type: String, title: String, emit: @escaping Emit) async {
        let url=OSINTJSON.url("https://dns.google/resolve",["name":host,"type":type])
        await source("Domains & networks",title,url,emit:emit) { r in
            guard let status=r.json["Status"] as? Int else { return [Self.invalid(title,r)] }
            let answers=(r.json["Answer"] as? [[String:Any]] ?? []).compactMap { $0["data"] as? String }
            return [OSINTFinding(category:"Domains & networks",title:title,detail:answers.isEmpty ? "No \(type) records returned for \(host)" : answers.joined(separator:"\n"),source:url.absoluteString,state:status==0 ? (answers.isEmpty ? .notFound : .found) : .unavailable,evidence:r.text,facts:answers.isEmpty ? nil : ["Domain":host,type:answers.joined(separator:"\n"),"DNSSEC authenticated":(r.json["AD"] as? Bool)==true ? "Yes" : "No authenticated-data flag returned"]) ]
        }
    }
    /// Only selected links from already retrieved pages are expanded; never a
    /// recursive crawler or guessed private endpoint/account recovery probe.
    func follow(pages: [OSINTFinding], subject: String?, kind: OSINTKind?, emit: @escaping Emit) async {
        var selected:[(URL,String)]=[],seen=Set(pages.map { $0.source })
        for row in pages where row.isSubstantive {
            guard let object=(try? JSONSerialization.jsonObject(with:Data(row.evidence.utf8))) as? [String:Any],
                  let html=object["html"] as? String,let base=URL(string:row.source) else { continue }
            let links=Self.matches(#"(?is)\bhref\s*=\s*["']([^"']+)["']"#,html).compactMap { URL(string:Self.decode($0),relativeTo:base)?.absoluteURL }
            for url in links where url.host==base.host && OSINTIdentity.publicLead(url) {
                let path=url.path.lowercased()
                guard ["contact","about","team","people","company","impressum"].contains(where:path.contains),
                      !["login","logout","signout","delete","subscribe","checkout","admin"].contains(where:path.contains),
                      url.query==nil,url.pathComponents.count<=5,seen.insert(OSINTIdentity.canonical(url)).inserted else { continue }
                if selected.count<4 { selected.append((url,row.source)) }
            }
        }
        await withTaskGroup(of:Void.self) { group in
            for (url,parent) in selected {
                group.addTask {
                    await self.page(url,category:"Retrieved pages",includeLinks:false,subject:subject,kind:kind) { input in
                        var row=input
                        if row.isSubstantive { row.facts=OSINTFacts.compact((row.facts ?? [:]).merging(["Linked from":parent]) { _,new in new }) }
                        await emit(row)
                    }
                }
            }
        }
        var profiles=Set<String>()
        for row in OSINTAnalysis.subjectSources(pages,kind:kind,subject:subject) where row.isSubstantive {
            for raw in (row.facts?["Linked profiles"] ?? "").components(separatedBy:.newlines) {
                guard profiles.count<3,let url=URL(string:raw),OSINTIdentity.publicLead(url),profiles.insert(OSINTIdentity.canonical(url)).inserted else { continue }
                await socialProfile(url,linkedFrom:row.source,emit:emit)
            }
        }
    }
    func socialProfile(_ url: URL, linkedFrom: String? = nil, emit: @escaping Emit) async {
        let host=url.host?.lowercased().replacingOccurrences(of:"www.",with:"") ?? ""
        let path=url.path.split(separator:"/").map(String.init)
        if ["github.com","gitlab.com"].contains(host),path.count==1 {
            await knownProfiles(path[0],only:host=="github.com" ? "GitHub" : "GitLab",linkedFrom:linkedFrom,emit:emit)
        } else {
            await page(url,category:"Public profiles",includeLinks:false) { input in
                var row=input
                if let linkedFrom,row.isSubstantive { row.facts?["Linked from"]=linkedFrom;row.state = .possible }
                await emit(row)
            }
        }
    }
    func knownProfiles(_ username: String, only: String? = nil, linkedFrom: String? = nil, emit: @escaping Emit) async {
        guard username.range(of:#"^[A-Za-z0-9_.-]{1,64}$"#,options:.regularExpression) != nil else { return }
        let sources:[(String,URL,URL)]=[
            ("GitHub",URL(string:"https://api.github.com/users/"+username)!,URL(string:"https://github.com/"+username)!),
            ("GitLab",OSINTJSON.url("https://gitlab.com/api/v4/users",["username":username]),URL(string:"https://gitlab.com/"+username)!),
            ("Hacker News",URL(string:"https://hacker-news.firebaseio.com/v0/user/"+username+".json")!,OSINTJSON.url("https://news.ycombinator.com/user",["id":username]))]
        await withTaskGroup(of:Void.self) { group in
            for (name,api,profile) in sources where only==nil || only==name {
                group.addTask {
                    do {
                        let r=try await fetch(api);try Task.checkCancellation()
                        guard r.status==200 else {
                            await emit(OSINTFinding(category:"Public profiles",title:name,detail:Self.status(r.status),source:profile.absoluteString,state:r.status==404 ? .notFound : .unavailable,evidence:r.text));return
                        }
                        var json=r.json
                        if name=="GitLab" { json=((try? JSONSerialization.jsonObject(with:r.data)) as? [[String:Any]])?.first(where: { ($0["username"] as? String)?.lowercased()==username.lowercased() }) ?? [:] }
                        let identity=json[name=="GitHub" ? "login" : name=="GitLab" ? "username" : "id"] as? String
                        guard let identity,(name=="Hacker News" ? identity==username : identity.lowercased()==username.lowercased()) else {
                            await emit(OSINTFinding(category:"Public profiles",title:name,detail:json.isEmpty ? "No public profile returned" : "The returned profile did not match the requested handle",source:profile.absoluteString,state:json.isEmpty ? .notFound : .unavailable,evidence:r.text));return
                        }
                        if name=="GitLab",let id=json["id"] as? Int {
                            if let detail=try? await fetch(URL(string:"https://gitlab.com/api/v4/users/\(id)")!),detail.status==200,(detail.json["username"] as? String)?.lowercased()==username.lowercased() { json=detail.json }
                        }
                        var facts=OSINTFacts.profileJSON(json)
                        if name=="Hacker News" {
                            facts["Username"]=identity;facts["Karma"]=OSINTFacts.text(json["karma"])
                            if let timestamp=json["created"] as? Double { facts["Joined"]=Date(timeIntervalSince1970:timestamp).ISO8601Format() }
                        }
                        facts["Match basis"]="Exact handle returned by the platform's public API"
                        if let linkedFrom { facts["Linked from"]=linkedFrom }
                        let website=facts["Website"].flatMap(Self.webURL).filterPublic
                        await emit(OSINTFinding(category:"Public profiles",title:name,detail:OSINTFacts.summary(facts,fallback:identity),source:profile.absoluteString,state:.possible,evidence:OSINTJSON.text(["checkURL":api.absoluteString,"profile":json]),pivots:[profile.absoluteString]+(website.map { [$0.absoluteString] } ?? []),facts:OSINTFacts.compact(facts)))
                    } catch { if !Task.isCancelled { await emit(OSINTFinding(category:"Public profiles",title:name,detail:error.localizedDescription,source:profile.absoluteString,state:.unavailable)) } }
                }
            }
        }
    }
}

private extension Optional where Wrapped == URL {
    var filterPublic: URL? { flatMap { OSINTIdentity.publicLead($0) ? $0 : nil } }
}
