import Foundation

/// Saved endpoints refer to the existing encrypted password store by server,
/// protocol, port and account. Passwords never enter this settings document.
struct SavedProxy: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var kind: ProxyKind = .socks5
    var host = ""
    var port = ""
    var signsIn = false
    var user = ""

    init(id: UUID = UUID(), name: String = "", kind: ProxyKind = .socks5,
         host: String = "", port: String = "", signsIn: Bool = false, user: String = "") {
        self.id=id; self.name=name; self.kind=kind; self.host=host; self.port=port
        self.signsIn=signsIn; self.user=user
    }
    init(id: UUID = UUID(), name: String, setup: ProxySetup, port: String) {
        self.init(id:id,name:name,kind:setup.kind,host:setup.host,port:port,signsIn:setup.signsIn,user:setup.user)
    }
    var setup: ProxySetup {
        ProxySetup(kind:kind,host:host,port:UInt16(port.trimmingCharacters(in:.whitespacesAndNewlines)),signsIn:signsIn,user:user)
    }
    var title: String { name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? setup.name : name }
    var valid: Bool {
        !host.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            && (port.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (UInt16(port.trimmingCharacters(in:.whitespacesAndNewlines)) ?? 0)>0)
            && (!signsIn || !user.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
    }
}

struct SavedProxyLibrary: Codable, Equatable {
    static let key = "proxy.savedConnections"
    var entries: [SavedProxy] = []
    var selected: UUID?

    static func load(_ data: Data?, legacy: SavedProxy) -> SavedProxyLibrary {
        if let data, var library=try? JSONDecoder().decode(Self.self,from:data) {
            var seen=Set<UUID>()
            library.entries=library.entries.filter { seen.insert($0.id).inserted }
            if !library.entries.contains(where: { $0.id==library.selected }) { library.selected=nil }
            return library
        }
        guard !legacy.host.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return .init() }
        return .init(entries:[legacy],selected:legacy.id)
    }
}
