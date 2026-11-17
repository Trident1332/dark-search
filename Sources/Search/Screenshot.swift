import AppKit
import SwiftUI
import WebKit

@MainActor
final class ScreenshotController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var capturing = false
    private(set) var document: ScreenshotDocument?
    private(set) var selectionPanel: NSPanel?
    private(set) var editorWindow: NSWindow?
    private var source: CGImage?
    private weak var owner: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var revision=UUID()
    private var savePanel: NSSavePanel?
    var saveDestinationForTesting: URL?
    var savePanelForTesting: ((NSSavePanel) -> Void)?

    func capture(in browser: Browser) {
        if let editorWindow { if !Store.testing { editorWindow.makeKeyAndOrderFront(nil) };return }
        guard !capturing,let tab=browser.active,tab.isWeb,!tab.asleep,
              let window=browser.window,tab.web.window === window,tab.web.bounds.width>1,tab.web.bounds.height>1 else {
            browser.announce("Open a visible webpage to take a screenshot");return
        }
        capturing=true;revision=UUID();let token=revision
        let web=tab.web
        let bounds=web.bounds
        let frame=window.convertToScreen(web.convert(web.bounds,to:nil))
        let configuration=WKSnapshotConfiguration();configuration.rect=web.bounds;configuration.afterScreenUpdates=true
        web.takeSnapshot(with:configuration) { [weak self,weak browser,weak window,weak web] image,error in
            Task { @MainActor in
                guard let self,self.revision==token else { return }
                guard let window,let web,web.window===window,web.bounds==bounds,
                      window.convertToScreen(web.convert(web.bounds,to:nil))==frame,browser?.active === tab,
                      let image,let pixels=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else {
                    self.capturing=false;browser?.announce(error?.localizedDescription ?? ScreenshotImage.Failure.unavailable.localizedDescription);return
                }
                self.beginSelection(pixels,frame:frame,owner:window)
            }
        }
    }
    private func beginSelection(_ image: CGImage, frame: CGRect, owner: NSWindow) {
        self.source=image;self.owner=owner
        let panel=ScreenshotSelectionPanel(contentRect:frame,styleMask:.borderless,backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.isOpaque=true;panel.backgroundColor = .black
        panel.level=owner.level;panel.hasShadow=false;panel.hidesOnDeactivate=true
        let canvas=ScreenshotCanvas(image:image);canvas.choosingCapture=true
        canvas.didSelect={ [weak self] in self?.select($0) }
        canvas.didCancel={ [weak self] in self?.cancelSelection() }
        panel.contentView=canvas;selectionPanel=panel
        for name in [NSWindow.didResizeNotification,NSWindow.didMoveNotification,NSWindow.willCloseNotification,NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:owner,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelSelection() }
            })
        }
        owner.addChildWindow(panel,ordered:.above)
        if Store.testing { panel.orderBack(nil) } else { panel.makeKeyAndOrderFront(nil) }
        panel.makeFirstResponder(canvas)
    }
    func select(_ rect: CGRect) {
        guard let source else { return }
        do {
            let image=try ScreenshotImage.cropped(source,to:rect)
            dismissSelection();self.source=nil;capturing=false
            showEditor(image)
        } catch { cancelSelection() }
    }
    func cancelSelection() {
        revision=UUID();dismissSelection();source=nil;capturing=false
        if !Store.testing { owner?.makeKey() }
    }
    private func dismissSelection() {
        observers.forEach(NotificationCenter.default.removeObserver);observers=[]
        if let panel=selectionPanel { panel.parent?.removeChildWindow(panel);panel.orderOut(nil);panel.contentView=nil;panel.close() }
        selectionPanel=nil
    }
    private func showEditor(_ image: CGImage) {
        let document=ScreenshotDocument(image);self.document=document
        let visible=owner?.screen?.visibleFrame ?? CGRect(x:0,y:0,width:1280,height:800)
        let size=CGSize(width:min(1000,max(700,visible.width-100)),height:min(740,max(480,visible.height-100)))
        let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Screenshot";window.isReleasedWhenClosed=false;window.delegate=self
        window.contentMinSize=CGSize(width:660,height:420)
        window.contentView=NSHostingView(rootView:ScreenshotEditor(document:document,save:{ [weak self] in self?.save() },close:{ [weak self] in self?.close() }))
        editorWindow=window
        let anchor=owner?.frame ?? visible
        window.setFrameOrigin(CGPoint(x:anchor.midX-size.width/2,y:anchor.midY-size.height/2))
        if Store.testing { window.setFrameOrigin(CGPoint(x:-20000,y:-20000));window.orderBack(nil) }
        else { window.makeKeyAndOrderFront(nil) }
    }
    func save() {
        guard let document,document.canExport,let window=editorWindow,savePanel==nil else { return }
        let panel=ScreenshotImage.savePanel();savePanel=panel
        if Store.testing { savePanelForTesting?(panel) }
        if Store.testing,let destination=saveDestinationForTesting {
            savePanel=nil
            do { try document.save(to:destination) } catch { document.notice=error.localizedDescription }
            return
        }
        panel.beginSheetModal(for:window) { [weak self,weak document] response in
            MainActor.assumeIsolated {
                self?.savePanel=nil
                guard response == .OK,let url=panel.url,let document else { return }
                do { try document.save(to:url) } catch { document.notice=error.localizedDescription }
            }
        }
    }
    func close() {
        cancelSelection();savePanel?.cancel(nil);savePanel=nil
        document?.cancel();document=nil
        editorWindow?.delegate=nil;editorWindow?.close();editorWindow=nil;owner=nil
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === editorWindow {
            editorWindow?.delegate=nil;editorWindow=nil;close()
        }
    }
}

private final class ScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct ScreenshotDoor: View {
    @ObservedObject var browser: Browser
    @ObservedObject var controller: ScreenshotController
    var body: some View {
        Button { controller.capture(in:browser) } label: {
            Image(systemName:"camera.viewfinder").font(.system(size:15,weight:.medium))
                .foregroundStyle(controller.capturing ? Color.accentColor : Palette.muted)
                .frame(width:30,height:32).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(controller.capturing || browser.active?.isWeb != true)
            .help("Screenshot · Select an area").accessibilityLabel("Take screenshot")
    }
}
