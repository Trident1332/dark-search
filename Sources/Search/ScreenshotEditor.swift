import AppKit
import SwiftUI

/// The same pixel mapping is used to select the capture and to blur the result.
@MainActor
final class ScreenshotCanvas: NSView {
    var image: CGImage { didSet { needsDisplay=true } }
    var choosingCapture = false
    var enabled = true
    var didSelect: ((CGRect) -> Void)?
    var didCancel: (() -> Void)?
    private var start: CGPoint?
    private(set) var selection: CGRect?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageFrame: CGRect {
        ScreenshotGeometry.imageFrame(CGSize(width:image.width,height:image.height),in:bounds.insetBy(dx:choosingCapture ? 0 : 20,dy:choosingCapture ? 0 : 20))
    }
    init(image: CGImage) { self.image=image;super.init(frame:.zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if enabled { addCursorRect(imageFrame,cursor:.crosshair) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill();bounds.fill()
        NSImage(cgImage:image,size:CGSize(width:image.width,height:image.height))
            .draw(in:imageFrame,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
        if choosingCapture {
            let shade=NSBezierPath(rect:bounds)
            if let selection { shade.appendRect(selection) }
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.40).setFill();shade.fill()
        }
        if let selection {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill();selection.fill()
            let line=NSBezierPath(rect:selection.insetBy(dx:0.5,dy:0.5));line.lineWidth=1.5
            NSColor.white.setStroke();line.stroke()
            if choosingCapture,let rect=ScreenshotGeometry.pixels(selection,in:imageFrame,image:CGSize(width:image.width,height:image.height)) {
                badge("\(Int(rect.width)) × \(Int(rect.height))",at:CGPoint(x:selection.midX,y:min(bounds.maxY-32,selection.maxY+8)))
            }
        }
        if choosingCapture { badge("Drag to capture  ·  Esc to cancel",at:CGPoint(x:bounds.midX,y:16)) }
    }
    private func badge(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.white]
        let size=(text as NSString).size(withAttributes:attributes)
        let rect=CGRect(x:max(4,min(bounds.width-size.width-24,point.x-size.width/2-12)),y:point.y,width:size.width+24,height:size.height+14)
        NSColor.black.withAlphaComponent(0.78).setFill();NSBezierPath(roundedRect:rect,xRadius:8,yRadius:8).fill()
        (text as NSString).draw(at:CGPoint(x:rect.minX+12,y:rect.minY+7),withAttributes:attributes)
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        let point=convert(event.locationInWindow,from:nil)
        guard imageFrame.contains(point) else { return }
        window?.makeFirstResponder(self);start=point;selection=nil;needsDisplay=true
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled,let start else { return }
        selection=ScreenshotGeometry.selection(from:start,to:convert(event.locationInWindow,from:nil),inside:imageFrame)
        needsDisplay=true
    }
    override func mouseUp(with event: NSEvent) {
        guard enabled,let start else { return }
        let rect=ScreenshotGeometry.selection(from:start,to:convert(event.locationInWindow,from:nil),inside:imageFrame)
        self.start=nil;selection=nil;needsDisplay=true
        guard rect.width>=3,rect.height>=3,
              let pixels=ScreenshotGeometry.pixels(rect,in:imageFrame,image:CGSize(width:image.width,height:image.height)) else { return }
        didSelect?(pixels)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode==53 { start=nil;selection=nil;needsDisplay=true;didCancel?() }
        else { super.keyDown(with:event) }
    }
}

private struct ScreenshotPreview: NSViewRepresentable {
    @ObservedObject var document: ScreenshotDocument
    func makeNSView(context: Context) -> ScreenshotCanvas {
        let view=ScreenshotCanvas(image:document.image)
        view.didSelect={ [weak document] in document?.blur($0) }
        return view
    }
    func updateNSView(_ view: ScreenshotCanvas, context: Context) {
        view.image=document.image;view.enabled = !document.rendering
        view.window?.invalidateCursorRects(for:view)
    }
}

struct ScreenshotEditor: View {
    @ObservedObject var document: ScreenshotDocument
    var save: () -> Void
    var close: () -> Void
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"camera.viewfinder").font(.system(size:18)).foregroundStyle(Palette.muted)
                VStack(alignment:.leading,spacing:3) {
                    Text("Screenshot").font(.system(size:15,weight:.semibold))
                    Text("\(document.image.width) × \(document.image.height)").font(.system(size:11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { document.undo() } label: { Label("Undo",systemImage:"arrow.uturn.backward") }
                    .disabled(document.areas.isEmpty || document.rendering).keyboardShortcut("z",modifiers:.command)
                Button("Reset") { document.reset() }.disabled(document.areas.isEmpty || document.rendering)
            }.buttonStyle(.borderless).padding(.horizontal,22).padding(.vertical,16)
            Rectangle().fill(Palette.hairline).frame(height:1)
            ScreenshotPreview(document:document).frame(maxWidth:.infinity,maxHeight:.infinity)
            Rectangle().fill(Palette.hairline).frame(height:1)
            HStack(spacing:12) {
                if document.rendering {
                    ProgressView().controlSize(.small)
                    Text("Applying blur…").font(.system(size:12)).foregroundStyle(Palette.muted)
                } else {
                    Image(systemName:"drop.halffull").foregroundStyle(Color.accentColor)
                    Text(document.problem ?? document.notice ?? "Drag over anything you want to blur")
                        .font(.system(size:12)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                Spacer(minLength:12)
                Button { document.copy() } label: { Label("Copy",systemImage:"doc.on.doc") }
                    .keyboardShortcut("c",modifiers:.command).disabled(!document.canExport)
                Button(action:save) { Label("Save…",systemImage:"square.and.arrow.down") }
                    .keyboardShortcut("s",modifiers:.command).buttonStyle(.borderedProminent).disabled(!document.canExport)
            }.padding(.horizontal,22).padding(.vertical,16)
        }
        .background(Palette.ground).foregroundStyle(Palette.ink)
        .frame(minWidth:660,minHeight:420)
        .onExitCommand(perform:close)
    }
}
