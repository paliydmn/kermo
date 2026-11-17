import AppKit
import DFMCore

/// One answer in the chat as it comes: the model's text in blocks (paragraphs, code), each read it makes as a step,
/// and how the turn ended. Only the block still growing is drawn again, every 80 ms — or three times as long as the
/// last drawing took (a 20 KB paragraph takes ~40 ms): the main thread stays free for the rest of Kermo.
@MainActor
final class Answer: NSStackView {
    private unowned let panel: AIPanel
    /// The model's text since the last step, and what of it is on screen: one view a block.
    private var raw = ""
    private var shown: [(block: ChatMarkdown.Block, view: NSView)] = []
    private var segment: NSStackView?
    private var steps: [String: StepRow] = [:]
    private var waiting: NSView?, drawing = false, pace: TimeInterval = 0.08

    init(model: String, panel: AIPanel) {
        self.panel = panel
        super.init(frame: .zero)
        (orientation, alignment, spacing) = (.vertical, .leading, 6)
        let who = NSTextField(labelWithString: "✨ " + model)
        (who.font, who.textColor) = (.systemFont(ofSize: 11, weight: .semibold), .secondaryLabelColor)
        let spin = NSProgressIndicator()
        (spin.style, spin.controlSize) = (.spinning, .small)
        spin.startAnimation(nil)
        let thinking = NSStackView(views: [spin, Self.small("Thinking…")])
        waiting = thinking
        add(who)
        add(thinking)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func add(_ v: NSView) {
        addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func show(_ step: AIChat.Step) {
        waiting?.removeFromSuperview()
        waiting = nil
        switch step {
        case .text(let t):
            raw += t
            guard !drawing else { return }
            drawing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + pace) { [weak self] in MainActor.assumeIsolated { self?.draw() } }
        case .calling(let c):
            draw()
            (raw, shown, segment) = ("", [], nil)   // the text after it is a new segment
            let row = StepRow(c)
            steps[c.id] = row
            add(row)
        case .called(let c, let r): steps[c.id]?.done(r)
        }
    }

    /// The segment's blocks: those that didn't change stay as they are.
    private func draw() {
        drawing = false
        let start = Date()
        defer { pace = max(0.08, 3 * Date().timeIntervalSince(start)) }
        let blocks = ChatMarkdown.blocks(raw)
        guard !blocks.isEmpty else { return }
        if segment == nil {
            let s = NSStackView()
            (s.orientation, s.alignment, s.spacing) = (.vertical, .leading, 8)
            segment = s
            add(s)
        }
        for (i, b) in blocks.enumerated() {
            if i < shown.count, shown[i].block == b { continue }
            if i < shown.count, case .prose(let text) = b, case .prose = shown[i].block, let v = shown[i].view as? ChatText {
                v.set(ChatMarkdown.prose(text))
                shown[i].block = b
                continue
            }
            let v = view(b)
            if i < shown.count {
                segment?.removeArrangedSubview(shown[i].view)
                shown[i].view.removeFromSuperview()
                shown[i] = (b, v)
                segment?.insertArrangedSubview(v, at: i)
            } else {
                shown.append((b, v))
                segment?.addArrangedSubview(v)
            }
            v.widthAnchor.constraint(equalTo: segment!.widthAnchor).isActive = true
        }
        while shown.count > blocks.count { shown.removeLast().view.removeFromSuperview() }
        panel.follow()
    }

    private func view(_ b: ChatMarkdown.Block) -> NSView {
        switch b {
        case .prose(let text): return ChatText(ChatMarkdown.prose(text))
        case .code(let code, let lang):
            let text = ChatText(NSAttributedString(string: code.bidiVisible, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                                                                                         .foregroundColor: NSColor.labelColor]))
            var buttons: [NSView] = [MenuButton("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }]
            if ChatMarkdown.shells.contains(lang.lowercased()) {
                let into = MenuButton("Into Terminal") { [weak self] in self?.panel.intoTerminal(code) }
                into.toolTip = "Into the terminal's line — nothing runs until you press ↩ there"
                buttons.insert(into, at: 0)
            }
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [spacer] + buttons)
            row.spacing = 4
            let box = NSStackView(views: [TintBox(text, fill: .quaternaryLabelColor, inset: NSSize(width: 8, height: 6)), row])
            (box.orientation, box.spacing) = (.vertical, 3)
            for v in box.arrangedSubviews { v.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }
            return box
        }
    }

    /// How the turn ended, and what it took.
    func end(_ end: AIChat.End, _ used: AIUsage) {
        draw()
        waiting?.removeFromSuperview()
        let said: String? = switch end {
        case .model(.done), .model(.tools): nil
        case .model(.maxTokens): "The answer reached its length limit."
        case .model(.refused(let why)): "The model declined to answer" + (why.map { " (\($0))" } ?? "") + "."
        case .model(.other(let why)): "The answer ended: \(why)."
        case .rounds: "Kermo stopped after \(AIChat.rounds) rounds of reading. Say “go on” to let it continue."
        }
        if let said { add(Self.noteRow(said, error: false, action: nil)) }
        var tokens = ["\(AIPanel.tokens(used.input + used.cacheRead + used.cacheWrite)) in", "\(AIPanel.tokens(used.output)) out"]
        if used.cacheRead > 0 { tokens.append("\(AIPanel.tokens(used.cacheRead)) from cache") }
        add(Self.small(tokens.joined(separator: " · ") + " tokens"))
    }

    /// Stopped or failed: what was there stays, with the words — and what may help.
    func end(note: String, error: Bool = false, action: (String, () -> Void)? = nil) {
        draw()
        waiting?.removeFromSuperview()
        steps.values.forEach { $0.stopped() }
        add(Self.noteRow(note, error: error, action: action))
    }

    static func noteRow(_ words: String, error: Bool, action: (String, () -> Void)?) -> NSView {
        let text = ChatText(NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: error ? Palette.fail : NSColor.secondaryLabelColor]))
        guard let (title, act) = action else { return text }
        let b = MenuButton(title, act)
        b.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [text, b])
        (row.alignment, row.spacing) = (.centerY, 8)
        return row
    }

    static func small(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        (l.font, l.textColor) = (.systemFont(ofSize: 11), .secondaryLabelColor)
        return l
    }
}

/// One read the model made: what and where, then how it ended; a click shows what came back.
final class StepRow: NSStackView {
    private let mark = NSImageView(), label = NSTextField(labelWithString: "")
    private var result: AIResult?
    private let title: String

    init(_ c: AIToolUse) {
        func arg(_ k: String) -> String? { if case .string(let s)? = c.args?[k] { s } else { nil } }
        let what = ["focus": "What's in front of you", "list_folder": "List", "read_file": "Read", "terminal_output": "Terminal output",
                    "server_info": "Server info", "run_command": "Run"][c.name] ?? c.name
        title = ([what, arg("server"), arg("path") ?? arg("folder"), arg("command")].compactMap { $0 }).joined(separator: " ").bidiVisible
        super.init(frame: .zero)
        let spin = NSProgressIndicator()
        (spin.style, spin.controlSize) = (.spinning, .small)
        spin.startAnimation(nil)
        label.stringValue = title
        (label.font, label.lineBreakMode, label.textColor) = (.systemFont(ofSize: 11.5), .byTruncatingMiddle, .secondaryLabelColor)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setViews([spin, label], in: .leading)
        spacing = 6
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(open)))
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func done(_ r: AIResult) {
        result = r
        mark.image = (r.isError ? Symbol.failed : Symbol.check).image(r.isError ? "Failed" : "Done")
        mark.contentTintColor = r.isError ? Palette.fail : .secondaryLabelColor
        setViews([mark, label], in: .leading)
        label.stringValue = title + (r.isError ? " — " + (r.text.split(separator: "\n").first.map(String.init) ?? "") : " · \(AIPanel.tokens(r.text.count)) characters")
        toolTip = "Click: what came back"
    }

    func stopped() { if result == nil { done(.failure("Stopped.")) } }

    @objc private func open() { AIPanel.pop(title, result?.text ?? "Running…", from: self) }
}

/// The model's markdown as the chat draws it: paragraphs and fenced code; in a paragraph headings bold, lists with
/// bullets, **bold**, *italic*, `code` and links — only http(s), their address shown when the words differ. No image
/// is loaded, nothing opens by itself.
enum ChatMarkdown {
    enum Block: Equatable { case prose(String), code(String, lang: String) }
    static let shells: Set<String> = ["sh", "bash", "shell", "zsh", "console", "fish"]

    /// Blank lines part paragraphs; a fence still open (the answer is coming) is a code block up to here.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = [], para: [Substring] = [], code: [Substring]?, lang = ""
        func endPara() { if !para.isEmpty { out.append(.prose(para.joined(separator: "\n"))); para = [] } }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if let c = code {
                    out.append(.code(c.joined(separator: "\n"), lang: lang))
                    code = nil
                } else {
                    endPara()
                    (code, lang) = ([], String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                }
            } else if code != nil {
                code!.append(line)
            } else if t.isEmpty {
                endPara()
            } else {
                para.append(line)
            }
        }
        endPara()
        if let c = code { out.append(.code(c.joined(separator: "\n"), lang: lang)) }
        return out
    }

    static func prose(_ text: String, size: CGFloat = 13) -> NSAttributedString {
        let md = text.bidiVisible
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+(.+)$"#, with: "**$1**", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^(\s*)[-*+] "#, with: "$1• ", options: .regularExpression)
        let base = NSFont.systemFont(ofSize: size), out = NSMutableAttributedString()
        guard let a = try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text.bidiVisible, attributes: [.font: base, .foregroundColor: NSColor.labelColor])
        }
        for run in a.runs {
            var s = String(a[run.range].characters)
            var attrs: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: NSColor.labelColor]
            let i = run.inlinePresentationIntent ?? []
            if i.contains(.code) {
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
            } else {
                var traits: NSFontTraitMask = []
                if i.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if i.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { attrs[.font] = NSFontManager.shared.convert(base, toHaveTrait: traits) }
            }
            if let url = run.link, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                attrs[.link] = url
                if s != url.absoluteString { s += " (\(url.absoluteString))" }
            }
            out.append(NSAttributedString(string: s, attributes: attrs))
        }
        return out
    }
}
