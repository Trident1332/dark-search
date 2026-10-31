import AppKit
import WebKit

/// Captures the trusted right-click in its own frame. No lookup happens until
/// the person chooses the native menu item; websites cannot open the panel.
final class OSINTMenuRelay: NSObject, WKScriptMessageHandler {
    static let name="searchOSINTContext"
    weak var web: PageView?
    private var latest: (OSINTContext,Date,URL?)?
    private(set) var frame: WKFrameInfo?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === web,let body=message.body as? [String:Any] else { return }
        let selection=body["selection"] as? String ?? "",image=body["image"] as? String ?? "",link=body["link"] as? String ?? ""
        let page=message.frameInfo.request.url?.absoluteString ?? body["page"] as? String ?? ""
        let context: OSINTContext
        if !image.isEmpty { context=OSINTContext(text:image,page:page,label:"Selected image",imageURL:image,kind:.image) }
        else if !link.isEmpty {
            context=OSINTContext(text:link.lowercased().hasPrefix("tel:") ? String(link.dropFirst(4)) : link,page:page,label:"Selected link")
        } else if !selection.isEmpty { context=OSINTContext(text:selection,page:page,label:"Selected text") }
        else { context=OSINTContext(text:page,page:page,label:"Current website") }
        latest=(context,Date(),web?.url)
        frame=message.frameInfo
    }
    func take() -> OSINTContext? {
        defer { latest=nil }
        guard let latest,Date().timeIntervalSince(latest.1)<30,latest.2==web?.url else { return nil }
        return latest.0
    }
    static let script = #"""
    (()=>{
      if(window.__searchOSINTMenu)return;window.__searchOSINTMenu=true;
      document.addEventListener('contextmenu',event=>{
        if(!event.isTrusted)return;
        const el=event.target;
        let selection='';
        if(el?.matches?.('textarea,input:not([type=password])')){
          if(typeof el.selectionStart==='number')selection=String(el.value||'').slice(el.selectionStart,el.selectionEnd);
        }else selection=String(getSelection()||'');
        const img=el?.closest?.('img'),a=el?.closest?.('a[href]');
        const context={selection:selection.trim(),image:img?.currentSrc||img?.src||'',link:a?.href||'',page:location.href,at:Date.now()};
        window.__searchOSINTLast=context;
        window.webkit?.messageHandlers.searchOSINTContext?.postMessage(context);
      },true);
    })()
    """#
}

extension PageView {
    func addOSINTItem(to menu: NSMenu) {
        guard onOSINT != nil,PanelSites.allowed(url),!menu.items.contains(where: { $0.identifier?.rawValue=="SearchOSINT" }) else { return }
        let item=NSMenuItem(title:"OSINT it",action:#selector(osintIt(_:)),keyEquivalent:"")
        item.identifier=NSUserInterfaceItemIdentifier("SearchOSINT"); item.target=self
        if menu.items.last?.isSeparatorItem==false { menu.addItem(.separator()) }
        menu.addItem(item)
    }
    @objc func osintIt(_ sender: NSMenuItem) {
        guard let page=url,PanelSites.allowed(page),onOSINT != nil else { return }
        let point=osintPoint
        Task { @MainActor [weak self] in
            guard let self else { return }
            var context: OSINTContext?
            var imageFrame: WKFrameInfo?
            if let point {
                let script = "const last=window.__searchOSINTLast;if(last&&Date.now()-last.at<30000)return last;const el=document.elementFromPoint(x,y),img=el?.closest?.('img'),a=el?.closest?.('a[href]');return {image:img?.currentSrc||img?.src||'',link:a?.href||'',selection:String(getSelection()||'').trim(),frame:el?.tagName==='IFRAME'};"
                if let hit=try? await self.callAsyncJavaScript(script,arguments:["x":point.x,"y":point.y],in:nil,contentWorld:Web.world) as? [String:Any] {
                    context=self.osintContext?(); imageFrame=self.osintFrame?()
                    let image=hit["image"] as? String ?? "",link=hit["link"] as? String ?? "",selected=hit["selection"] as? String ?? ""
                    if !image.isEmpty && (context==nil || context?.label=="Current website") {
                        context=OSINTContext(text:image,page:page.absoluteString,label:"Selected image",imageURL:image,kind:.image);imageFrame=nil
                    } else if context==nil || context?.label=="Current website" {
                        if !link.isEmpty { context=OSINTContext(text:link.hasPrefix("tel:") ? String(link.dropFirst(4)) : link,page:page.absoluteString,label:"Selected link") }
                        else if !selected.isEmpty { context=OSINTContext(text:selected,page:page.absoluteString,label:"Selected text") }
                    }
                }
            }
            if context==nil { context=self.osintContext?(); imageFrame=self.osintFrame?() }
            if context==nil { context=OSINTContext(text:page.absoluteString,page:page.absoluteString,label:"Current website") }
            guard self.url==page,let context else { return }
            let resolver: OSINTImageResolver?
            if context.kind == .image,let image=context.imageURL {
                let frame=imageFrame
                resolver = { [weak self] in
                    guard let self,self.url==page,!Task.isCancelled else { return nil }
                    let script = "const r=await fetch(url,{credentials:'include'});if(!r.ok)throw Error('Image HTTP '+r.status);const a=new Uint8Array(await r.arrayBuffer());let s='';for(let i=0;i<a.length;i+=32768)s+=String.fromCharCode(...a.subarray(i,i+32768));return btoa(s);"
                    guard let encoded=try? await self.callAsyncJavaScript(script,arguments:["url":image],in:frame,contentWorld:Web.world) as? String,!Task.isCancelled else { return nil }
                    return Data(base64Encoded:encoded)
                }
            } else { resolver=nil }
            self.onOSINT?(context,resolver)
        }
    }
}
