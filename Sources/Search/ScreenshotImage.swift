import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Selections use image pixels with their origin at the top left, independent
/// of the preview size and the screen's backing scale.
enum ScreenshotGeometry {
    static func imageFrame(_ pixels: CGSize, in bounds: CGRect) -> CGRect {
        guard pixels.width>0,pixels.height>0,bounds.width>0,bounds.height>0 else { return .zero }
        let scale=min(bounds.width/pixels.width,bounds.height/pixels.height)
        let size=CGSize(width:pixels.width*scale,height:pixels.height*scale)
        return CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height)
    }
    static func selection(from start: CGPoint, to end: CGPoint, inside frame: CGRect) -> CGRect {
        CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y)).intersection(frame)
    }
    static func pixels(_ selection: CGRect, in frame: CGRect, image: CGSize) -> CGRect? {
        let clipped=selection.intersection(frame)
        guard !clipped.isNull,clipped.width>0,clipped.height>0,frame.width>0,frame.height>0 else { return nil }
        let rect=CGRect(x:(clipped.minX-frame.minX)*image.width/frame.width,
                        y:(clipped.minY-frame.minY)*image.height/frame.height,
                        width:clipped.width*image.width/frame.width,height:clipped.height*image.height/frame.height)
            .integral.intersection(CGRect(origin:.zero,size:image))
        return rect.width>=1 && rect.height>=1 ? rect : nil
    }
}

enum ScreenshotImage {
    enum Failure: LocalizedError {
        case unavailable, processing, encoding
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The screenshot could not be created. Try again once the page is visible."
            case .processing: return "The selected area could not be blurred."
            case .encoding: return "The screenshot could not be exported."
            }
        }
    }
    private static let context=CIContext(options:[.cacheIntermediates:false])
    static func cropped(_ image: CGImage, to selection: CGRect) throws -> CGImage {
        let rect=selection.integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        guard !rect.isNull,rect.width>=1,rect.height>=1,let result=image.cropping(to:rect) else { throw Failure.unavailable }
        return result
    }
    /// Flatten every blur into the output bitmap. The exported file and
    /// clipboard have no original-image layer or removable blur overlays.
    static func render(_ original: CGImage, areas: [CGRect]) throws -> CGImage {
        guard !areas.isEmpty else { return original }
        let size=CGRect(x:0,y:0,width:original.width,height:original.height)
        let radius=max(14,min(42,CGFloat(max(original.width,original.height))/90))
        let blurred=CIImage(cgImage:original).clampedToExtent()
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:size)
        guard let blur=context.createCGImage(blurred,from:size),
              let canvas=CGContext(data:nil,width:original.width,height:original.height,bitsPerComponent:8,bytesPerRow:0,
                                   space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.processing }
        canvas.interpolationQuality = .none
        canvas.draw(original,in:size)
        for area in areas {
            let rect=area.integral.intersection(size)
            guard !rect.isNull,rect.width>0,rect.height>0,let patch=blur.cropping(to:rect) else { continue }
            canvas.saveGState()
            let destination=CGRect(x:rect.minX,y:size.height-rect.maxY,width:rect.width,height:rect.height)
            canvas.clip(to:destination);canvas.setBlendMode(.copy);canvas.draw(patch,in:destination)
            canvas.restoreGState()
        }
        guard let result=canvas.makeImage() else { throw Failure.processing }
        return result
    }
    static func png(_ image: CGImage) throws -> Data {
        guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw Failure.encoding }
        return data
    }
    static func savePanel(date: Date = Date()) -> NSSavePanel {
        let panel=NSSavePanel()
        panel.allowedContentTypes=[.png];panel.canCreateDirectories=true;panel.isExtensionHidden=false
        panel.directoryURL=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.dateFormat="yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue="Screenshot \(format.string(from:date)).png"
        panel.title="Save screenshot";panel.prompt="Save"
        return panel
    }
}

@MainActor
final class ScreenshotDocument: ObservableObject {
    let original: CGImage
    @Published private(set) var image: CGImage
    @Published private(set) var areas: [CGRect] = []
    @Published private(set) var rendering = false
    @Published private(set) var problem: String?
    @Published var notice: String?
    private var revision=UUID()
    private var task: Task<Void,Never>?
    var canExport: Bool { !rendering && problem==nil }
    init(_ image: CGImage) { original=image;self.image=image }
    func blur(_ area: CGRect) { apply(areas+[area]) }
    func undo() { if !areas.isEmpty { apply(Array(areas.dropLast())) } }
    func reset() { apply([]) }
    func cancel() { revision=UUID();task?.cancel();task=nil }
    private func apply(_ next: [CGRect]) {
        guard !rendering else { return }
        let token=UUID();revision=token;rendering=true;problem=nil;notice=nil
        let source=original
        task=Task { [weak self] in
            let result=await Task.detached(priority:.userInitiated) { Result { try ScreenshotImage.render(source,areas:next) } }.value
            guard let self,!Task.isCancelled,self.revision==token else { return }
            self.rendering=false
            switch result {
            case .success(let output): self.image=output;self.areas=next
            case .failure(let error): self.problem=error.localizedDescription
            }
        }
    }
    func png() throws -> Data {
        guard canExport else { throw ScreenshotImage.Failure.processing }
        return try ScreenshotImage.png(image)
    }
    @discardableResult func copy(to board: NSPasteboard = .general) -> Bool {
        do {
            let data=try png()
            let tiff=NSBitmapImageRep(cgImage:image).representation(using:.tiff,properties:[:])
            board.clearContents()
            guard board.setData(data,forType:.png) else { throw ScreenshotImage.Failure.encoding }
            if let tiff { board.setData(tiff,forType:.tiff) }
            notice="Copied";return true
        } catch { notice=error.localizedDescription;return false }
    }
    func save(to url: URL) throws { try png().write(to:url,options:.atomic);notice="Saved \(url.lastPathComponent)" }
}
