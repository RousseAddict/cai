import UIKit

// A chat bubble cell. Manual frame layout (no Auto Layout) per the iOS 6 conventions.
// User messages align right with an accent bubble; assistant messages align left, full-width.
// Message text is rendered as lightweight markdown (**bold**, *italic*, `code`, links).
class MessageCell: UITableViewCell {
    static let reuseID = "MessageCell"

    static let font = UIFont.systemFont(ofSize: 16)
    private static let boldFont = UIFont.boldSystemFont(ofSize: 16)
    private static let italicFont = UIFont.italicSystemFont(ofSize: 16)
    private static let codeFont = UIFont(name: "Menlo", size: 15) ?? UIFont.systemFont(ofSize: 15)

    // Regexes/detector compiled once. Recompiling per row made opening long conversations slow.
    private static let boldRE = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    private static let italicRE = try? NSRegularExpression(pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)")
    private static let codeRE = try? NSRegularExpression(pattern: "`([^`]+)`")
    private static let headerRE = try? NSRegularExpression(pattern: "^(#{1,6})[ \\t]+(.+)$",
                                                           options: [.anchorsMatchLines])
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static let bubbleWidthRatio: CGFloat = 0.75
    private static let hInset: CGFloat = 10   // text inset inside bubble (each side)
    private static let vInset: CGFloat = 8    // text inset inside bubble (top/bottom)
    private static let hMargin: CGFloat = 10  // bubble margin from screen edge
    private static let vMargin: CGFloat = 5   // cell top/bottom margin

    // A block caret appended while the assistant reply is still streaming.
    private static let caret = "\u{258C}"

    private let bubble = UIView()
    private let label = UILabel()

    // Reused off-screen for height measurement (never added to the view hierarchy).
    private static let sizingLabel: UILabel = {
        let l = UILabel()
        l.font = MessageCell.font
        l.numberOfLines = 0
        return l
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        bubble.layer.cornerRadius = 14
        // No clipsToBounds on the bubble (avoids off-screen rendering); the label has no overflow.
        contentView.addSubview(bubble)

        label.numberOfLines = 0
        label.font = MessageCell.font
        label.backgroundColor = .clear         // iOS 6: labels default to white bg
        label.textColor = Theme.primaryText
        bubble.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var isUser = false

    func configure(with message: ChatMessage, showCaret: Bool = false) {
        isUser = message.isUser
        label.attributedText = MessageCell.format(message.content, showCaret: showCaret)
        // User messages sit in an accent bubble; assistant replies are full-width, no bubble.
        bubble.backgroundColor = isUser ? Theme.userBubble : .clear
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cellWidth = contentView.bounds.width
        let attr = label.attributedText ?? NSAttributedString()

        if isUser {
            // Right-aligned bubble, capped at bubbleWidthRatio of the cell.
            let maxTextWidth = floor(cellWidth * MessageCell.bubbleWidthRatio) - 2 * MessageCell.hInset
            let textSize = MessageCell.textSize(for: attr, maxWidth: maxTextWidth)
            let bubbleW = textSize.width + 2 * MessageCell.hInset
            let bubbleH = textSize.height + 2 * MessageCell.vInset
            let x = cellWidth - MessageCell.hMargin - bubbleW
            bubble.frame = CGRect(x: x, y: MessageCell.vMargin, width: bubbleW, height: bubbleH)
            label.frame = CGRect(x: MessageCell.hInset, y: MessageCell.vInset,
                                 width: textSize.width, height: textSize.height)
        } else {
            // Full-width assistant text, left-aligned, no bubble.
            let maxTextWidth = cellWidth - 2 * MessageCell.hMargin
            let textSize = MessageCell.textSize(for: attr, maxWidth: maxTextWidth)
            let bubbleH = textSize.height + 2 * MessageCell.vInset
            bubble.frame = CGRect(x: MessageCell.hMargin, y: MessageCell.vMargin,
                                  width: maxTextWidth, height: bubbleH)
            label.frame = CGRect(x: 0, y: MessageCell.vInset,
                                 width: maxTextWidth, height: textSize.height)
        }
    }

    // MARK: - Sizing

    // iOS 6-safe text measurement via UILabel.sizeThatFits (boundingRect(with:) is iOS 7+).
    private static func textSize(for attr: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        sizingLabel.attributedText = attr
        let fit = sizingLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(fit.width), maxWidth), height: ceil(fit.height))
    }

    static func height(for message: ChatMessage, cellWidth: CGFloat, showCaret: Bool = false) -> CGFloat {
        let maxTextWidth = message.isUser
            ? floor(cellWidth * bubbleWidthRatio) - 2 * hInset
            : cellWidth - 2 * hMargin
        let attr = format(message.content, showCaret: showCaret)
        let textSize = textSize(for: attr, maxWidth: maxTextWidth)
        return textSize.height + 2 * vInset + 2 * vMargin
    }

    // MARK: - Markdown

    // Renders a lightweight subset of markdown to an attributed string:
    // # headings, **bold**, *italic*, `code`, GFM tables, and auto-detected links.
    // Markers are removed (not just hidden) so the styled text reads cleanly on any background.
    private static func format(_ text: String, showCaret: Bool) -> NSAttributedString {
        let source = showCaret ? (text.isEmpty ? caret : text + " " + caret) : text

        // Tables are reflowed into a key/value record list before styling (see preprocessTables).
        let result = NSMutableAttributedString(
            string: preprocessTables(source),
            attributes: [.font: font, .foregroundColor: Theme.primaryText])

        applyHeaders(result)
        applyInline(result, boldRE, markerLen: 2, font: boldFont)
        applyInline(result, italicRE, markerLen: 1, font: italicFont)
        applyInline(result, codeRE, markerLen: 1, font: codeFont)
        applyLinks(result)
        return result
    }

    // Styles ATX headings (# … ######) as bold, size scaled by level, and removes the `#` prefix.
    private static func applyHeaders(_ s: NSMutableAttributedString) {
        guard let re = headerRE else { return }
        let full = NSRange(location: 0, length: (s.string as NSString).length)
        for m in re.matches(in: s.string, options: [], range: full).reversed() {
            guard m.numberOfRanges >= 3 else { continue }
            let hashes = m.range(at: 1)
            let title = m.range(at: 2)
            let size: CGFloat = hashes.length <= 1 ? 22 : (hashes.length == 2 ? 19 : 17)
            s.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: size), range: title)
            // Delete the "### " prefix (from the first hash up to the title start).
            s.deleteCharacters(in: NSRange(location: hashes.location, length: title.location - hashes.location))
        }
    }

    // Applies `font` to each capture group and deletes the surrounding markers.
    // Matches are processed back-to-front so earlier ranges stay valid after deletion.
    private static func applyInline(_ s: NSMutableAttributedString, _ re: NSRegularExpression?,
                                    markerLen: Int, font: UIFont) {
        guard let re = re else { return }
        let full = NSRange(location: 0, length: (s.string as NSString).length)
        let matches = re.matches(in: s.string, options: [], range: full)
        for m in matches.reversed() {
            guard m.numberOfRanges >= 2 else { continue }
            let whole = m.range(at: 0)
            let inner = m.range(at: 1)
            s.addAttribute(.font, value: font, range: inner)
            // Delete trailing marker first, then the leading one.
            s.deleteCharacters(in: NSRange(location: inner.location + inner.length, length: markerLen))
            s.deleteCharacters(in: NSRange(location: whole.location, length: markerLen))
        }
    }

    // Colors and underlines detected URLs (NSDataDetector is iOS 4+).
    private static func applyLinks(_ s: NSMutableAttributedString) {
        guard let detector = linkDetector else { return }
        let full = NSRange(location: 0, length: (s.string as NSString).length)
        for m in detector.matches(in: s.string, options: [], range: full) {
            s.addAttribute(.foregroundColor, value: Theme.accent, range: m.range)
            s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
        }
    }

    // MARK: - Tables

    // Finds table blocks (a row of `|` cells followed by a `---|---`/`---+---` separator) and
    // reflows each into a key/value record list. A real grid can't fit a phone's width without
    // wrapping into garbage, so each data row becomes a record keyed by its first cell, with the
    // remaining columns listed as "Header: value" lines. Cheap string work — no per-glyph layout.
    private static func preprocessTables(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if lines[i].contains("|"), i + 1 < lines.count, isSeparatorRow(lines[i + 1]) {
                let header = lines[i]
                var rows: [String] = []
                var j = i + 2
                while j < lines.count, lines[j].contains("|") { rows.append(lines[j]); j += 1 }
                out.append(renderTable(header: header, rows: rows))
                i = j
            } else {
                out.append(lines[i])
                i += 1
            }
        }
        return out.joined(separator: "\n")
    }

    // A table separator row: only |, +, =, -, :, spaces, containing a column marker and a dash.
    private static func isSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") || t.contains("+") else { return false }
        guard t.contains("-") || t.contains("=") else { return false }
        for ch in t where !"|+=-: ".contains(ch) { return false }
        return true
    }

    // Splits a table row into trimmed cells, dropping the empty cells created by edge pipes,
    // and strips inline markers so cells read cleanly.
    private static func splitRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|").map {
            stripInline($0.trimmingCharacters(in: .whitespaces))
        }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    // Reflows a table into records: each data row keyed by its first cell, remaining columns
    // listed under it as "Header: value". Never overflows the screen width.
    private static func renderTable(header: String, rows: [String]) -> String {
        let head = splitRow(header)
        guard head.count >= 2 else { return header }

        var records: [String] = []
        for rowLine in rows {
            var cells = splitRow(rowLine)
            guard !cells.isEmpty else { continue }
            while cells.count < head.count { cells.append("") }

            if head.count == 2 {
                // Simple two-column table: "key: value".
                records.append("\(cells[0]): \(cells[1])")
            } else {
                // First cell is the record's label; remaining columns become indented pairs.
                var block = cells[0]
                for c in 1..<head.count {
                    block += "\n   \(head[c]): \(cells[c])"
                }
                records.append(block)
            }
        }
        return records.joined(separator: "\n\n")
    }

    // Removes inline markdown markers (kept plain for table cells).
    private static func stripInline(_ s: String) -> String {
        var r = s
        r = replaceRegex(r, boldRE, "$1")
        r = replaceRegex(r, italicRE, "$1")
        r = replaceRegex(r, codeRE, "$1")
        return r
    }

    private static func replaceRegex(_ s: String, _ re: NSRegularExpression?, _ template: String) -> String {
        guard let re = re else { return s }
        return re.stringByReplacingMatches(in: s, options: [],
                                           range: NSRange(location: 0, length: (s as NSString).length),
                                           withTemplate: template)
    }
}
