import Foundation
import Network
import CryptoKit
import ImageIO
import Vision
import AppKit

typealias OSINTImageResolver = @MainActor () async -> Data?

enum OSINTKind: String, Codable, CaseIterable, Identifiable {
    case auto, person, username, website, company, domain, ip, asn, phone, email, social, image
    var id: String { rawValue }
    var title: String { switch self {
    case .auto: return "Automatic"
    case .person: return "Person"
    case .username: return "Username"
    case .website: return "Website"
    case .company: return "Company"
    case .domain: return "Domain"
    case .ip: return "IP address"
    case .asn: return "Autonomous system"
    case .phone: return "Phone number"
    case .email: return "Email address"
    case .social: return "Social profile"
    case .image: return "Image"
    } }
    var icon: String { switch self {
    case .username, .social: return "at"
    case .person: return "person"
    case .company: return "building.2"
    case .domain, .website: return "globe"
    case .ip,.asn: return "network"
    case .phone: return "phone"
    case .email: return "envelope"
    case .image: return "photo"
    case .auto: return "magnifyingglass"
    } }
    static func detect(_ input: String) -> Self {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if OSINTIdentity.email(s) != nil { return .email }
        if s.range(of:#"(?i)^AS[0-9]{1,10}$"#,options:.regularExpression) != nil { return .asn }
        // Network accepts an integer as a legacy IPv4 address. A national
        // phone number must not accidentally take the IP lookup path.
        if (s.split(separator:".",omittingEmptySubsequences:false).count == 4 && IPv4Address(s) != nil)
            || (s.contains(":") && IPv6Address(s) != nil) { return .ip }
        if s.hasPrefix("@"), !s.contains(" ") { return .username }
        let digits = s.filter(\.isNumber)
        if digits.count >= 7, s.allSatisfy({ $0.isNumber || "+()- .".contains($0) }) { return .phone }
        if let u = URL(string:s), ["https","http"].contains(u.scheme?.lowercased() ?? ""), let host = u.host {
            return socialHosts.contains(host.replacingOccurrences(of:"www.",with:"")) ? .social : .website
        }
        if !s.contains(" "), s.contains("."), let host = URL(string:"https://"+s)?.host, host.contains(".") { return .domain }
        if s.range(of:#"(?i)\b(inc|llc|ltd|limited|corp|corporation|company|gmbh|studio|labs)\b"#,options:.regularExpression) != nil { return .company }
        return s.contains(" ") ? .person : .username
    }
    static let socialHosts: Set<String> = ["github.com","gitlab.com","instagram.com","x.com","twitter.com","reddit.com","linkedin.com","facebook.com","tiktok.com","bsky.app","mastodon.social","youtube.com","threads.net"]
}

struct OSINTContext: Codable, Equatable {
    var text: String
    var page: String = ""
    var label: String = "Entered query"
    var imageURL: String? = nil
    var imageBytes: Data? = nil
    var kind: OSINTKind = .auto
}

struct OSINTFinding: Codable, Identifiable, Equatable {
    enum State: String, Codable { case found, possible, unavailable, notFound, reference }
    var id = UUID()
    var category: String
    var title: String
    var detail: String
    var source: String
    var state: State = .found
    var evidence: String = ""
    var pivots: [String] = []
    var collected = Date()
    var saved = false
    var facts: [String:String]? = nil
    var evidenceSHA256: String? = nil
    var evidenceTruncated: Bool? = nil
    var isSearchLink: Bool { category == "More sources" }
    var isSubstantive: Bool {
        guard state == .found || state == .possible else { return false }
        guard category != "Web results" && category != "More sources" else { return false }
        let scaffolding:Set<String>=["Page title","Canonical URL","Match basis","Match meaning","Linked from","Discovery query","Entity type"]
        return !(facts ?? [:]).filter { !scaffolding.contains($0.key) }.isEmpty || category == "Images" || category == "Phone numbering"
    }
    var sourceHost: String { URL(string:source)?.host ?? source }
    var icon: String { switch category {
    case "Public profiles": return "person.crop.circle"
    case "Images": return "photo"
    case "Phone numbering": return "phone"
    case "Companies": return "building.2"
    case "Web results", "Linked websites": return "globe"
    default: return "doc.text.magnifyingglass"
    } }
}

struct OSINTReport: Codable, Identifiable {
    var id = UUID()
    var context: OSINTContext
    var kind: OSINTKind
    var started = Date()
    var findings: [OSINTFinding] = []
    var completed = false
    var stopped = false
    var imagePath: String? = nil
}

enum OSINTPhone {
    struct Rule: Decodable { let region: String; let code: String; let prefix: String; let pattern: String; let types: [String:String] }
    static let rules = (try? JSONDecoder().decode([Rule].self,from:Data(OSINTPhoneMetadata.json.utf8))) ?? []
    static func matches(_ digits: String, _ pattern: String) -> Bool {
        !pattern.isEmpty && digits.range(of:"^(?:"+pattern+")$",options:.regularExpression) != nil
    }
    static func describe(_ raw: String, region: String = "") -> [String:Any] {
        let cleaned = raw.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:#"(?i)^tel:"#,with:"",options:.regularExpression)
        var digits = cleaned.filter(\.isNumber)
        var international = cleaned.hasPrefix("+") || cleaned.hasPrefix("00")
        if cleaned.hasPrefix("00") { digits = String(digits.dropFirst(2)) }
        if !international, let rule = rules.first(where: { $0.region == region }) {
            if !rule.prefix.isEmpty, digits.hasPrefix(rule.prefix) { digits = String(digits.dropFirst(rule.prefix.count)) }
            digits = rule.code + digits; international = true
        }
        guard international, (4...15).contains(digits.count) else {
            return ["input":raw,"error":"Use an international number beginning with + and its country calling code."]
        }
        guard let code = rules.map(\.code).filter({ digits.hasPrefix($0) }).max(by: { $0.count < $1.count }) else {
            return ["input":raw,"error":"Unknown country calling code."]
        }
        let national = String(digits.dropFirst(code.count))
        let candidates = rules.filter { $0.code == code && matches(national,$0.pattern) }
        let detailed = candidates.filter { $0.types.values.contains { matches(national,$0) } }
        let territories = detailed.isEmpty ? candidates : detailed
        let regions = Array(Set(territories.map { Locale(identifier:"en").localizedString(forRegionCode:$0.region) ?? $0.region })).sorted()
        let types = Set(territories.flatMap { $0.types.filter { matches(national,$0.value) }.map(\.key) }).sorted()
        return ["input":raw,"international":"+"+digits,"callingCode":"+"+code,"nationalNumber":national,
                "numberingRegions":regions,"numberingCategories":types,"matchesNumberingPlan":!candidates.isEmpty,
                "meaning":"Numbering-plan metadata, not proof of an assigned number, current carrier, subscriber identity or current location.",
                "metadataSource":"google/libphonenumber · 2026-10-31"]
    }
    static func searchTerms(_ raw: String, region: String = "") -> [String] {
        let info=describe(raw,region:region)
        var terms: [String]=[]
        if let national=info["nationalNumber"] as? String {
            if national.count==10 {
                let a=String(national.prefix(3)),b=String(national.dropFirst(3).prefix(3)),c=String(national.suffix(4))
                terms.append("\(a)-\(b)-\(c)")
            }
        }
        if let international=info["international"] as? String { terms += [international,international.filter(\.isNumber)] }
        if let national=info["nationalNumber"] as? String {
            terms.append(national)
            if national.count==10 { terms.append("(\(national.prefix(3))) \(national.dropFirst(3).prefix(3))-\(national.suffix(4))") }
        }
        terms.append(raw)
        var seen=Set<String>()
        return terms.filter { !$0.isEmpty && seen.insert($0).inserted }.map { "\""+$0.replacingOccurrences(of:"\"",with:"")+"\"" }
    }
    static func searchQuery(_ raw: String, region: String = "") -> String {
        searchTerms(raw,region:region).joined(separator:" OR ")
    }
}

enum OSINTImage {
    struct Result { var metadata: String; var text: String; var pivots: [String]; var summary: String; var facts: [String:String] }
    static func analyse(_ data: Data) throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), CGImageSourceGetCount(source)>0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else {
            throw NSError(domain:"OSINT",code:1,userInfo:[NSLocalizedDescriptionKey:"This file could not be decoded as an image."])
        }
        var metadata = properties
        metadata["SHA-256"] = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        metadata["Original bytes"] = data.count
        metadata["Image count"] = CGImageSourceGetCount(source)
        metadata["Analysis"] = "Original image bytes; metadata is not proof of authenticity. Missing EXIF/GPS is not reconstructed."
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        var text = ""
        do {
            try VNImageRequestHandler(data:data,options:[:]).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
        } catch { metadata["OCR unavailable"] = error.localizedDescription }
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String:Any]
        var pivots: [String] = []
        if let lat = gps?[kCGImagePropertyGPSLatitude as String] as? Double, let lon = gps?[kCGImagePropertyGPSLongitude as String] as? Double {
            let y = gps?[kCGImagePropertyGPSLatitudeRef as String] as? String == "S" ? -lat : lat
            let x = gps?[kCGImagePropertyGPSLongitudeRef as String] as? String == "W" ? -lon : lon
            metadata["GPS decimal"] = ["latitude":y,"longitude":x]
            pivots.append("https://www.openstreetmap.org/?mlat=\(y)&mlon=\(x)#map=16/\(y)/\(x)")
        }
        let width = properties[kCGImagePropertyPixelWidth as String] ?? "?"
        let height = properties[kCGImagePropertyPixelHeight as String] ?? "?"
        let tiff=properties[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
        let exif=properties[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        var facts=OSINTFacts.compact(["Dimensions":"\(width) × \(height)","Original bytes":String(data.count),"Camera":OSINTFacts.text(tiff[kCGImagePropertyTIFFMake as String])+" "+OSINTFacts.text(tiff[kCGImagePropertyTIFFModel as String]),"SHA-256":metadata["SHA-256"] as? String ?? "","EXIF capture time":OSINTFacts.text(exif[kCGImagePropertyExifDateTimeOriginal as String]),"OCR":"\(text.count) recognised characters"])
        if let gps=metadata["GPS decimal"] as? [String:Double] { facts["Embedded coordinates"]="\(gps["latitude"] ?? 0), \(gps["longitude"] ?? 0)" }
        let recognised=OSINTService.matches(#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,63}\b"#,text,group:0)
        pivots+=Array(Set(recognised)).sorted().prefix(10)
        if !recognised.isEmpty { facts["OCR email candidates"]=Array(Set(recognised)).sorted().joined(separator:"\n") }
        facts=OSINTFacts.compact(facts)
        return Result(metadata:OSINTJSON.text(metadata),text:text,pivots:pivots,
                      summary:OSINTFacts.summary(facts,fallback:"Image metadata",limit:6)+"\n"+(gps == nil ? "No GPS metadata" : "GPS metadata present"),facts:facts.merging(["Metadata location":gps == nil ? "No GPS metadata" : "GPS metadata present"]) { _,new in new })
    }
}

enum OSINTJSON {
    static func text(_ value: Any) -> String {
        func clean(_ value: Any) -> Any {
            if let d = value as? [String:Any] { return d.mapValues(clean) }
            if let a = value as? [Any] { return a.map(clean) }
            if value is String || value is NSNumber || value is NSNull { return value }
            return String(describing:value)
        }
        guard let data = try? JSONSerialization.data(withJSONObject:clean(value),options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed]) else { return String(describing:value) }
        return String(decoding:data,as:UTF8.self)
    }
    static func url(_ base: String, _ values: [String:String]) -> URL {
        var parts = URLComponents(string:base)!
        parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
        return parts.url!
    }
}
