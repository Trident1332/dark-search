import SwiftUI

struct OSINTConnectionsView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var session: OSINTSession
    @State private var expanded=false
    @State private var all=false
    var body: some View {
        DisclosureGroup(isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:14) {
                Text("Published contacts, sites and organizations connected by the retrieved sources.").font(.system(size:10.5)).foregroundStyle(Palette.muted)
                ForEach(Array(session.connections.prefix(all ? 40 : 6))) { item in
                    VStack(alignment:.leading,spacing:5) {
                        Text(item.type.uppercased()).font(.system(size:9,weight:.semibold)).tracking(0.8).foregroundStyle(Palette.muted)
                        Button { pivot(item) } label: { Text(item.value).textSelection(.enabled).font(.system(size:11.5,weight:.medium)).multilineTextAlignment(.leading) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        Text("Published in \(item.sources.count) source\(item.sources.count==1 ? "" : "s") · \(item.domains) site\(item.domains==1 ? "" : "s")").font(.system(size:9.5)).foregroundStyle(Palette.muted)
                        ForEach(Array(item.sources.prefix(3))) { source in
                            if let url=URL(string:source.source),PanelSites.allowed(url) {
                                Button { browser.open(url,foreground:true) } label: { Label(source.sourceHost,systemImage:"arrow.up.right").lineLimit(1) }.font(.system(size:10)).buttonStyle(.plain).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
                if session.connections.count>6 { Button(all ? "Show fewer connections" : "Show all connections") { all.toggle() }.buttonStyle(.plain).font(.system(size:10.5)).foregroundStyle(Color.accentColor) }
            }.padding(.top,10)
        } label: { Label("Connections (\(session.connections.count))",systemImage:"point.3.connected.trianglepath.dotted").font(.system(size:12,weight:.medium)) }.tint(Palette.muted)
    }
    private func pivot(_ item: OSINTConnection) {
        let kind: OSINTKind=switch item.type {
        case "Phone":.phone
        case "Email":.email
        case "Organization":.company
        case "Network":.asn
        default:.auto
        }
        let query=item.value.replacingOccurrences(of:#"\s+\(Q[0-9]+\)$"#,with:"",options:.regularExpression)
        session.investigate(OSINTContext(text:query,label:"From collected evidence",kind:kind))
    }
}

struct OSINTTimelineView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var session: OSINTSession
    @State private var expanded=false
    var body: some View {
        DisclosureGroup(isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:12) {
                ForEach(Array(session.timeline.prefix(30))) { item in
                    VStack(alignment:.leading,spacing:4) {
                        Text(item.date).font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.muted)
                        Text(item.label+" · "+item.source.title).font(.system(size:11.5)).lineLimit(2)
                        if let url=URL(string:item.source.source),PanelSites.allowed(url) {
                            Button(item.source.sourceHost) { browser.open(url,foreground:true) }.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }.padding(.top,10)
        } label: { Label("Timeline (\(session.timeline.count))",systemImage:"clock").font(.system(size:12,weight:.medium)) }.tint(Palette.muted)
    }
}
