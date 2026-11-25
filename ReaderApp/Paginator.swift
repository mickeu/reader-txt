import Foundation
import CoreText
import CoreGraphics

/// 基于 CoreText 的分页器，和旧版一样按字号/行距/版心切页。
enum Paginator {
    struct Page: Hashable {
        var offset: Int
        var length: Int
    }

    static func attributed(_ text: String, fontSize: CGFloat, lineSpacing: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // 行距用 lineSpacing 补，多出的部分不会撑破版心。
        paragraph.lineSpacing = max(0, lineSpacing)
        paragraph.lineBreakMode = .byWordWrapping
        let font = UIFont.systemFont(ofSize: max(8, fontSize))
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
        ])
    }

    /// 按版心切页。空文本返回单页（offset 0 / length 0），避免阅读页空白崩溃。
    static func paginate(_ text: String, size: CGSize, fontSize: CGFloat, lineSpacing: CGFloat) -> [Page] {
        guard size.width > 1, size.height > 1 else { return [Page(offset: 0, length: 0)] }
        guard !text.isEmpty else { return [Page(offset: 0, length: 0)] }

        let attributed = self.attributed(text, fontSize: fontSize, lineSpacing: lineSpacing)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: size.width, height: size.height), transform: nil)

        var pages: [Page] = []
        let total = (text as NSString).length
        var location = 0
        // 上限保护：文本异常时最多 20000 页。
        while location < total && pages.count < 20000 {
            let frameRange = CFRange(location: location, length: 0)
            let frame = CTFramesetterCreateFrame(framesetter, frameRange, path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 { break }   // 版心太小，停止而不是死循环
            pages.append(Page(offset: visible.location, length: visible.length))
            location = visible.location + visible.length
        }
        return pages.isEmpty ? [Page(offset: 0, length: 0)] : pages
    }

    /// 页序号，用于把字符偏移换算成第几页。
    static func pageIndex(forOffset offset: Int, in pages: [Page]) -> Int {
        guard !pages.isEmpty else { return 0 }
        var low = 0, high = pages.count - 1, ans = 0
        while low <= high {
            let mid = (low + high) / 2
            if pages[mid].offset <= offset {
                ans = mid; low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return ans
    }

    /// 取某一页的正文，边界做了裁剪，永不越界。
    static func text(_ full: String, page: Page) -> String {
        let ns = full as NSString
        let length = ns.length
        guard length > 0 else { return "" }
        let start = min(max(0, page.offset), length)
        let count = min(max(0, page.length), length - start)
        return ns.substring(with: NSRange(location: start, length: count))
    }
}