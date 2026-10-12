import AppKit
import Nuke

typealias PageContext = [String: String]
@MainActor enum UIScreen { static let main = UIScreenValue(); struct UIScreenValue { let bounds = CGRect(x: 0, y: 0, width: 390, height: 844) } }
enum AidokuRunner {
    @MainActor final class Source {
        struct Features { let processesPages = true }
        let features = Features()
        var calls = 0
        func getModifiedImageRequest(url: URL, context: PageContext?) async -> URLRequest { calls += 1; return URLRequest(url: url) }
    }
}
struct TestProcessor: ImageProcessing {
    var identifier: String { "noop" }
    func process(_ image: NSImage) -> NSImage? { image }
    init() {}
    init(width: CGFloat) {}
    init(source: AidokuRunner.Source, pageContext: PageContext?) {}
}
typealias PageInterceptorProcessor = TestProcessor
typealias CropBordersProcessor = TestProcessor
typealias DownsampleProcessor = TestProcessor
typealias UpscaleProcessor = TestProcessor
extension ImageRequest.UserInfoKey { static let processesKey = Self("processes") }
@MainActor final class NASComicManager {
    static let shared = NASComicManager()
    var received: [PageContext?] = []
    var bytes = Data()
    func onlineImageData(context: PageContext?) async throws -> Data {
        received.append(context)
        guard context?["nasPage"] == "fixture" else { throw URLError(.cannotDecodeContentData) }
        return bytes
    }
}

@main struct Check {
    @MainActor static func main() async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 48, bitsPerPixel: 32)!
        bitmap.bitmapData?[0] = 255
        bitmap.bitmapData?[3] = 255
        NASComicManager.shared.bytes = bitmap.representation(using: .png, properties: [:])!
        let source = AidokuRunner.Source()
        let pipeline = ImagePipeline { $0.imageCache = nil; $0.dataCache = nil }
        for width: CGFloat? in [nil, 390] {
            let request = await ReaderPageView.imageRequest(url: URL(string: "nascomic://page/fixture-\(width ?? 0)")!, context: ["nasPage": "fixture"], source: source, width: width)
            let image = try await pipeline.image(for: request)
            precondition(image.size.width == 12 && image.size.height == 18, "NAS bytes must become a decoded image")
            precondition(request.userInfo[.processesKey] as? Bool != true, "NAS must bypass original source page decryption")
        }
        precondition(source.calls == 0 && NASComicManager.shared.received.count == 2, "both modes must keep NAS context and avoid source requests")
        _ = await ReaderPageView.imageRequest(url: URL(string: "https://source.invalid/page.png")!, context: nil, source: source)
        precondition(source.calls == 1, "regular source modification must remain intact")
        let broken = await ReaderPageView.imageRequest(url: URL(string: "nascomic://page/missing-context")!, context: nil, source: source)
        do { _ = try await pipeline.image(for: broken); fatalError("missing context must fail") } catch { }
        print("PASS: actual Nuke image decoding for paged and webtoon requests; NAS context; source processor isolation; ordinary source preserved")
    }
}
