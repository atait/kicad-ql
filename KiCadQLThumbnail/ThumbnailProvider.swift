import QuickLookThumbnailing
import CoreGraphics
import KiCadPCBKit

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let board = try PCBBoard(url: request.fileURL)
            let size = board.fittedSize(in: request.maximumSize)
            handler(QLThumbnailReply(contextSize: size) { ctx -> Bool in
                PCBRenderer.draw(board, in: ctx, rect: CGRect(origin: .zero, size: size))
                return true
            }, nil)
        } catch {
            handler(nil, error)
        }
    }
}
