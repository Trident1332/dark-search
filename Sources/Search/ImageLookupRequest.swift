import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image preparation stays on this Mac until Search is explicitly chosen.
enum ImageLookupRequest {
    static let endpoint = URL(string: "https://lens.google.com/v3/upload")!
    static let limit = 20 * 1024 * 1024
    struct Picture {
        let data: Data
        let preview: NSImage
        let width: Int
        let height: Int
    }
    enum Failure: LocalizedError {
        case invalidURL, invalidImage, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a complete http or https image URL, without a username or password."
            case .invalidImage: return "Choose a readable image, such as JPEG, PNG, WebP or HEIC."
            case .tooLarge: return "Choose an image under 20 MB and 64 megapixels."
            }
        }
    }
    static func imageURL(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              let url = parts.url else { throw Failure.invalidURL }
        return url
    }
    static func picture(_ data: Data) throws -> Picture {
        guard data.count <= limit else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { throw Failure.invalidImage }
        guard width <= 32000, height <= 32000, width * height <= 64_000_000 else { throw Failure.tooLarge }
        // A bounded, orientation-correct raster strips source metadata and
        // avoids sending GPS, filenames or embedded document attachments.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let raster = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.invalidImage }
        CGImageDestinationAddImage(destination, raster, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        return Picture(data: output as Data, preview: NSImage(cgImage: raster, size: .zero), width: width, height: height)
    }
    static func request(picture: Picture?, link: String, endpoint: URL = endpoint) throws -> URLRequest {
        if let picture {
            let boundary = "SearchImage-" + UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"encoded_image\"; filename=\"image.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
            body.append(picture.data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            return request
        }
        let url = try imageURL(link)
        var parts = URLComponents(string: "https://lens.google.com/uploadbyurl")!
        parts.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return URLRequest(url: parts.url!)
    }
}
