import SwiftUI
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let payload: SharePayload
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: payload.urls, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum ShareImageError: LocalizedError {
    case unableToRender
    case tooManyPages
    var errorDescription: String? {
        switch self {
        case .unableToRender: return "无法生成完整图片，请稍后重试。没有分享任何内容。"
        case .tooManyPages: return "这条记录需要超过 200 页图片。为避免手机内存不足，请先分成几条笔记，或使用完整数据备份。没有截断或分享部分内容。"
        }
    }
}

@MainActor
enum ShareImageMaker {
    static func task(_ task: TodoItem, list: String) throws -> SharePayload {
        let range = taskScheduleSummary(task)
        let metadata = [task.isCompleted ? "已完成" : "待完成", range, list, task.tags.map { "#" + $0 }.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " · ")
        return try create(title: "待办", text: task.title + "\n\n" + metadata + (task.detail.isEmpty ? "" : "\n\n" + task.detail))
    }
    static func note(_ note: NoteItem) throws -> SharePayload {
        let tags = note.tags.map { "#" + $0 }.joined(separator: " ")
        return try create(title: "笔记", text: note.title + "\n\n" + note.body + (tags.isEmpty ? "" : "\n\n" + tags))
    }

    /// The same measured attributed text is paginated and drawn. No character is
    /// removed, including whitespace, emoji clusters, blank lines, or long URLs.
    static func pages(text: String, width: CGFloat = 456, height: CGFloat = 575) throws -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [""] }
        var pages: [String] = []; var offset = 0
        while offset < characters.count {
            guard pages.count < 200 else { throw ShareImageError.tooManyPages }
            var lower = 1; var upper = min(characters.count - offset, 12_000); var best = 0
            while lower <= upper {
                let middle = (lower + upper) / 2
                let candidate = String(characters[offset..<(offset + middle)])
                let bounds = NSAttributedString(string: candidate, attributes: textAttributes).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                if ceil(bounds.height) <= height - 4 { best = middle; lower = middle + 1 } else { upper = middle - 1 }
            }
            guard best > 0 else { throw ShareImageError.unableToRender }
            pages.append(String(characters[offset..<(offset + best)])); offset += best
        }
        guard pages.joined() == text else { throw ShareImageError.unableToRender }
        return pages
    }
    private static var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6; paragraph.lineBreakMode = .byCharWrapping
        return [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 1), .paragraphStyle: paragraph]
    }
    private static func create(title: String, text: String) throws -> SharePayload {
        let pages = try pages(text: text)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalChecklistShare", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Expire only our own past share folders, never user documents.
        let oldFolders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in oldFolders {
            if let date = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate, date < Date().addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: folder) }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        var urls: [URL] = []
        do {
            for (index, page) in pages.enumerated() {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 540, height: 750), format: format).image { context in
                    UIColor(red: 0.94, green: 0.95, blue: 1, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 540, height: 750))
                    UIColor.white.setFill(); UIBezierPath(roundedRect: CGRect(x: 18, y: 18, width: 504, height: 714), cornerRadius: 28).fill()
                    let blue = UIColor(red: 0.32, green: 0.42, blue: 0.98, alpha: 1)
                    (("本地清单 · " + title) as NSString).draw(at: CGPoint(x: 42, y: 43), withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: blue])
                    NSAttributedString(string: page, attributes: textAttributes).draw(with: CGRect(x: 42, y: 88, width: 456, height: 575), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                    let footer = "\(index + 1) / \(pages.count)" as NSString
                    footer.draw(at: CGPoint(x: 42, y: 690), withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.gray])
                }
                guard let png = image.pngData() else { throw ShareImageError.unableToRender }
                let url = folder.appendingPathComponent(String(format: "本地清单-%03d.png", index + 1))
                #if targetEnvironment(macCatalyst)
                try png.write(to: url, options: [.atomic])
                #else
                try png.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                #endif
                urls.append(url)
            }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
        return SharePayload(urls: urls)
    }
}
