import Foundation

/// Deterministic extraction from the returned source. No model generates these values.
enum OSINTFacts {
    static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let values=value as? [String] { return values.joined(separator:", ") }
        if let value=value as? String { return OSINTService.plain(value) }
        if let value=value as? NSNumber { return value.stringValue }
        return ""
    }
    static func compact(_ values: [String:String]) -> [String:String] {
        values.filter { !$0.value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    }
    static func summary(_ facts: [String:String], fallback: String, limit: Int = 5) -> String {
        let order=["Matched passage","Name","Domain","About","Description","Page extract","Registrar","Registered","Expires","Company","City","Country","Jurisdiction","LEI","Status","Joined","Public repositories","Followers","Website"]
        let keys=facts.keys.sorted { a,b in
            let x=order.firstIndex(of:a) ?? 999,y=order.firstIndex(of:b) ?? 999
            return x==y ? a<b : x<y
        }
        let lines=keys.prefix(limit).map { "\($0): \(facts[$0]!)" }
        return lines.isEmpty ? fallback : lines.joined(separator:"\n")
    }
    static func registration(_ json: [String:Any]) -> [String:String] {
        var facts=compact(["Domain":text(json["unicodeName"] ?? json["ldhName"]),"Status":text(json["status"])])
        for item in json["events"] as? [[String:Any]] ?? [] {
            let event=text(item["eventAction"]),date=text(item["eventDate"])
            if let label=["registration":"Registered","expiration":"Expires","last changed":"Updated"][event],!date.isEmpty { facts[label]=date }
        }
        for entity in json["entities"] as? [[String:Any]] ?? [] where (entity["roles"] as? [String] ?? []).contains("registrar") {
            let vcard=entity["vcardArray"] as? [Any] ?? []
            if vcard.count>1,let rows=vcard[1] as? [[Any]],let name=rows.first(where: { $0.count>3 && ($0[0] as? String)=="fn" }) { facts["Registrar"]=text(name[3]) }
        }
        let names=(json["nameservers"] as? [[String:Any]] ?? []).map { text($0["ldhName"]) }.filter { !$0.isEmpty }
        if !names.isEmpty { facts["Nameservers"]=names.joined(separator:"\n") }
        return compact(facts)
    }
    static func company(_ item: [String:Any]) -> [String:String] {
        let a=item["attributes"] as? [String:Any] ?? [:],e=a["entity"] as? [String:Any] ?? [:]
        let name=e["legalName"] as? [String:Any] ?? [:],address=e["legalAddress"] as? [String:Any] ?? [:],registration=a["registration"] as? [String:Any] ?? [:]
        return compact(["Name":text(name["name"]),"LEI":text(a["lei"] ?? item["id"]),"Status":text(e["status"]),"Jurisdiction":text(e["jurisdiction"]),"City":text(address["city"]),"Country":text(address["country"]),"Registered":text(registration["initialRegistrationDate"]),"Updated":text(registration["lastUpdateDate"]),"Registration status":text(registration["status"])])
    }
    static func profileJSON(_ json: [String:Any]) -> [String:String] {
        var values=json
        for key in ["user","profile","data"] { if let nested=values[key] as? [String:Any] { values=nested } }
        var facts=compact(["Name":text(values["name"] ?? values["display_name"]),"Username":text(values["login"] ?? values["username"]),"About":text(values["bio"] ?? values["description"] ?? values["about"]),"Company":text(values["company"] ?? values["organization"]),"Website":text(values["blog"] ?? values["website"] ?? values["website_url"]),"Location":text(values["location"]),"Joined":text(values["created_at"]),"Updated":text(values["updated_at"]),"Public repositories":text(values["public_repos"]),"Followers":text(values["followers_count"] ?? values["followers"]),"Published email":text(values["email"] ?? values["public_email"])])
        if let handle=values["twitter_username"] as? String,!handle.isEmpty { facts["Linked profiles"]="https://x.com/"+handle }
        return facts
    }
    static func html(_ html: String) -> [String:String] {
        var meta: [String:String]=[:]
        for tag in OSINTService.matches(#"(?is)<meta\b[^>]*>"#,html,group:0) {
            let attributes=attrs(tag)
            if let name=attributes["property"] ?? attributes["name"],let content=attributes["content"] { meta[name.lowercased()]=OSINTService.decode(content) }
        }
        let title=meta["og:title"] ?? OSINTService.matches(#"(?is)<title[^>]*>(.*?)</title>"#,html).first.map(OSINTService.plain) ?? ""
        var facts=compact(["Page title":title,"Description":meta["og:description"] ?? meta["description"] ?? meta["twitter:description"] ?? ""])
        for script in OSINTService.matches(#"(?is)<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#,html) {
            guard let object=try? JSONSerialization.jsonObject(with:Data(script.utf8)) else { continue }
            var objects=(object as? [[String:Any]]) ?? (object as? [String:Any]).map { [$0] } ?? []
            objects += objects.flatMap { $0["@graph"] as? [[String:Any]] ?? [] }
            objects += objects.compactMap { $0["mainEntity"] as? [String:Any] }
            func types(_ item: [String:Any]) -> [String] { (item["@type"] as? [String]) ?? (item["@type"] as? String).map { [$0] } ?? [] }
            let primary=objects.first { types($0).contains("Person") && $0["name"] != nil } ?? objects.first { types($0).contains("Person") } ?? objects.first { !Set(types($0)).isDisjoint(with:["Organization","Corporation","LocalBusiness"]) } ?? objects.first { !Set(types($0)).isDisjoint(with:["ProfilePage","WebPage"]) }
            for item in primary.map({ [$0] }) ?? [] {
                let types=(item["@type"] as? [String]) ?? (item["@type"] as? String).map { [$0] } ?? []
                guard !Set(types).isDisjoint(with:["Person","Organization","Corporation","LocalBusiness","ProfilePage","WebPage"]) else { continue }
                if facts["Entity type"]?.contains("Person")==true,!types.contains("Person") { continue }
                if let previous=facts["Name"],previous != text(item["name"]) {
                    for key in ["Name","About","Website","Published phone","Published email","Linked profiles","Founded","Role","Company","City","Country"] { facts.removeValue(forKey:key);facts.removeValue(forKey:"Entity "+key) }
                }
                facts["Entity type"]=types.joined(separator:", ")
                if !text(item["name"]).isEmpty,facts["Name"]==nil || types.contains("Person") { facts["Name"]=text(item["name"]) }
                if !text(item["description"]).isEmpty { facts["About"]=text(item["description"]) }
                if !text(item["url"]).isEmpty { facts["Website"]=text(item["url"]) }
                if !text(item["telephone"]).isEmpty { facts["Published phone"]=text(item["telephone"]) }
                if !text(item["email"]).isEmpty { facts["Published email"]=text(item["email"]).replacingOccurrences(of:"mailto:",with:"") }
                if let links=item["sameAs"] as? [String],!links.isEmpty { facts["Linked profiles"]=links.joined(separator:"\n") }
                if let date=item["foundingDate"] as? String { facts["Founded"]=date }
                if let title=item["jobTitle"] as? String { facts["Role"]=title }
                if let employer=item["worksFor"] as? [String:Any] { facts["Company"]=text(employer["name"]) }
                if let address=item["address"] as? [String:Any] {
                    facts["City"]=text(address["addressLocality"]);facts["Country"]=text(address["addressCountry"])
                }
                let points=(item["contactPoint"] as? [[String:Any]]) ?? (item["contactPoint"] as? [String:Any]).map { [$0] } ?? []
                for point in points.prefix(8) {
                    if let phone=point["telephone"] as? String { facts["Published phone"]=phone }
                    if let email=point["email"] as? String { facts["Published email"]=email.replacingOccurrences(of:"mailto:",with:"") }
                }
                for field in ["Website","Published phone","Published email","Linked profiles","Company","Founded"] {
                    if let value=facts[field] { facts["Entity "+field]=value }
                }
            }
        }
        if facts["Description"]==nil && facts["About"]==nil {
            let body=html.replacingOccurrences(of:#"(?is)<(script|style|nav|header|footer)\b[^>]*>.*?</\1>"#,with:"",options:.regularExpression)
            let paragraphs=OSINTService.matches(#"(?is)<p\b[^>]*>(.*?)</p>"#,body).map(OSINTService.plain).map { $0.replacingOccurrences(of:#"\s+"#,with:" ",options:.regularExpression) }
            if let extract=paragraphs.first(where: { $0.count>=50 }) { facts["Page extract"]=String(extract.prefix(1000)) }
        }
        let phones=OSINTService.matches(#"(?is)href\s*=\s*["']tel:([^"']+)["']"#,html)
        if !phones.isEmpty { facts["Published phone"]=Array(Set(phones.map { $0.components(separatedBy:";")[0].removingPercentEncoding ?? $0 })).sorted().joined(separator:"\n") }
        let mail=OSINTService.matches(#"(?is)href\s*=\s*["']mailto:([^"'?]+)"#,html).compactMap { OSINTIdentity.email($0.removingPercentEncoding ?? $0) }
        if !mail.isEmpty { facts["Published email"]=Array(Set(mail)).sorted().joined(separator:"\n") }
        if let canonical=OSINTService.matches(#"(?is)<link\b[^>]*rel\s*=\s*["']canonical["'][^>]*href\s*=\s*["']([^"']+)"#,html).first { facts["Canonical URL"]=canonical }
        return compact(facts)
    }
    static func passage(_ html: String, subject: String, kind: OSINTKind, facts: [String:String]) -> String? {
        let readable=html.replacingOccurrences(of:#"(?is)<(script|style|title|nav|header|footer)\b[^>]*>.*?</\1>"#,with:" ",options:.regularExpression)
        func plain(_ value: String) -> String {
            OSINTService.decode(value.replacingOccurrences(of:#"<[^>]+>"#,with:" ",options:.regularExpression))
                .replacingOccurrences(of:#"\s+"#,with:" ",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        // Prefer a readable paragraph over navigation, page titles, or a
        // concatenation of the same text repeated in metadata.
        let paragraphs=OSINTService.matches(#"(?is)<p\b[^>]*>(.*?)</p>"#,readable).map(plain).filter { $0.count>=50 }
        let fragments=paragraphs+[plain(readable)]+["About","Description","Page extract","Published phone","Name"].compactMap { facts[$0] }
        for haystack in fragments {
        let range: Range<String.Index>?
        if kind == .phone {
            let wanted=subject.filter(\.isNumber)
            let numbering=OSINTPhone.describe(subject)
            let national=numbering["nationalNumber"] as? String ?? wanted
            let code=(numbering["callingCode"] as? String ?? "").filter(\.isNumber)
            var variants=[wanted,national]
            for rule in OSINTPhone.rules where rule.code==code && !rule.prefix.isEmpty && rule.prefix.allSatisfy(\.isNumber) && OSINTPhone.matches(national,rule.pattern) {
                variants.append(rule.prefix+national)
            }
            var match: Range<String.Index>?
            for digits in variants where !digits.isEmpty {
                let pattern="(?<![0-9])\\+?"+digits.map(String.init).joined(separator:#"[\s().-]*"#)+"(?![0-9])"
                guard let candidate=haystack.range(of:pattern,options:.regularExpression) else { continue }
                if digits==national,!code.isEmpty {
                    let start=haystack.index(candidate.lowerBound,offsetBy:-8,limitedBy:haystack.startIndex) ?? haystack.startIndex
                    let prefix=String(haystack[start..<candidate.lowerBound])
                    if let other=OSINTService.matches(#"\+([0-9]{1,3})[\s()-]*$"#,prefix).first,other != code { continue }
                }
                match=candidate;break
            }
            range=match
        } else {
            let target=subject.replacingOccurrences(of:#"\s+"#,with:" ",options:.regularExpression)
            let before=kind == .email ? #"(?<![\w.+@-])"# : #"(?<![\p{L}\p{N}_])"#
            let after=kind == .email ? #"(?![\w+@-]|\.[\p{L}\p{N}])"# : #"(?![\p{L}\p{N}_])"#
            let pattern=before+NSRegularExpression.escapedPattern(for:target)+after
            range=haystack.range(of:pattern,options:[.regularExpression,.caseInsensitive,.diacriticInsensitive])
        }
        guard let range else { continue }
        let start=haystack.index(range.lowerBound,offsetBy:-110,limitedBy:haystack.startIndex) ?? haystack.startIndex
        let end=haystack.index(range.upperBound,offsetBy:240,limitedBy:haystack.endIndex) ?? haystack.endIndex
        return (start>haystack.startIndex ? "…" : "")+String(haystack[start..<end]).trimmingCharacters(in:.whitespacesAndNewlines)+(end<haystack.endIndex ? "…" : "")
        }
        return nil
    }
    static func recover(_ finding: OSINTFinding) -> [String:String] {
        guard let object=try? JSONSerialization.jsonObject(with:Data(finding.evidence.utf8)) else { return [:] }
        if let json=object as? [String:Any] {
            if json["ldhName"] != nil { return registration(json) }
            if json["attributes"] != nil { return company(json) }
            if let body=json["body"] as? String {
                if let data=body.data(using:.utf8),let profile=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] { return profileJSON(profile) }
                return html(body)
            }
            if let source=json["html"] as? String { return html(source) }
            if let answers=json["Answer"] as? [[String:Any]],!answers.isEmpty { return [finding.title:answers.map { text($0["data"]) }.joined(separator:"\n")] }
            if json["label"] != nil { return compact(["Name":text(json["label"]),"Description":text(json["description"])]) }
            if json["startAddress"] != nil { return compact(["Network":text(json["name"]),"Start":text(json["startAddress"]),"End":text(json["endAddress"])]) }
            if let d=json["data"] as? [String:Any],d["prefix"] != nil { return compact(["Prefix":text(d["prefix"]),"ASN":(d["asns"] as? [Any] ?? []).map { "AS"+text($0) }.joined(separator:", ")]) }
        }
        if let records=object as? [[String:Any]],records.contains(where: { $0["name_value"] != nil }) {
            let names=Array(Set(records.flatMap { text($0["name_value"]).components(separatedBy:"\n") })).filter { !$0.isEmpty }.sorted()
            return names.isEmpty ? [:] : ["Certificate names":names.joined(separator:"\n")]
        }
        if let capture=object as? [String],finding.category=="Archived pages",capture.count>1 { return ["Captured":capture[0],"Original page":capture[1]] }
        return [:]
    }
    static func upgrade(_ report: OSINTReport) -> OSINTReport {
        var copy=report
        for i in copy.findings.indices where copy.findings[i].facts==nil {
            copy.findings[i].facts=recover(copy.findings[i])
        }
        return copy
    }
    static func attrs(_ tag: String) -> [String:String] {
        guard let regex=try? NSRegularExpression(pattern:#"([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [:] }
        var result: [String:String]=[:]
        for m in regex.matches(in:tag,range:NSRange(tag.startIndex...,in:tag)) {
            guard let key=Range(m.range(at:1),in:tag) else { continue }
            for i in 2...4 { if let range=Range(m.range(at:i),in:tag) { result[String(tag[key]).lowercased()]=OSINTService.decode(String(tag[range]));break } }
        }
        return result
    }
}

actor OSINTWebCandidates {
    var values: [OSINTFinding]=[]
    func append(_ finding: OSINTFinding) { values.append(finding) }
    private var seen=Set<String>()
    func appendUnique(_ finding: OSINTFinding) -> Bool {
        let key=finding.category+"|"+finding.source
        guard seen.insert(key).inserted else { return false }
        values.append(finding);return true
    }
}
