import Cocoa
import Quartz
import KiCadPCBKit

/// Data-based preview: Info.plist needs QLIsDataBasedPreview = YES and
/// NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).PreviewProvider.
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let board = try PCBBoard(url: request.fileURL)
        let size = board.fittedSize(in: CGSize(width: 1200, height: 1200))
        // isBitmap: false records vector drawing, so it stays sharp at any window size.
        return QLPreviewReply(contextSize: size, isBitmap: false) { ctx, _ in
            PCBRenderer.draw(board, in: ctx, rect: CGRect(origin: .zero, size: size))
        }
    }
}
