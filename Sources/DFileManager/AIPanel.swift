import AppKit
import DFMCore

/// The AI chat right of the panels and the terminal (⌃⌘I, the toolbar's ✨): the user's own model in Ask — it reads
/// and answers, it changes nothing — Edit, which also proposes changes to files as a card (`EditCard`) the user
/// applies to the editor, or Agent, which acts within the chat's scope (the row under the modes). What goes is what
/// the user attached (chips) and what the model's tools return; every call is `AISession.call` (`readOnly` in Ask
/// and Edit: nothing changes, the user is only ever asked to let it read). Without a key: a card that leads to
/// Settings › AI. Nothing is made before the panel is first shown, and the key is read at the first send.
@MainActor
final class AIPanel: NSViewController, NSTextViewDelegate {
    unowned let app: AppDelegate
    init(app: AppDelegate) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }

    /// Something the user may attach: what it is, where it is from, how its text is read (masked, cut).
    struct Context {
        var id: String, title: String, symbol: Symbol
        var server: SFTPTarget?   // nil: this Mac
        var read: @MainActor () async -> AIResult
    }
    /// An attached one: its text once read.
    private struct Attached { var context: Context; var text: AIResult? }

    private var chat: AIChat?
    private(set) var session: AISession?
    /// The provider the chat started with: its production questions named it, its history is its.
    private var pinned: String?
    private(set) var turn: Task<Void, Never>?
    /// The history's length when a request failed: Retry asks again only while nothing came after it.
    private var failedAt: Int?
    /// New Chat's count: a turn of an earlier chat, still waiting on Touch ID, ends without a word.
    private var generation = 0
    private var chips: [Attached] = []
    /// Production servers this chat sends from: asked once each.
    private var prodSent: Set<String> = []
    /// The question waiting in the chat: ↩, ⌘↩ and ⎋ in the field go to it.
    private var card: Card?

    /// Where the chats are kept (tests: a folder of their own).
    var chats = AIChatStore(dir: Config.path("ai"))
    /// This chat's file, when it began, with which model, what the user sent — as the panel showed it, masked.
    private var chatID: String?, began = Date(), beganWith = ""
    private var asked: [AISavedChat.Asked] = []
    /// A chat read back held production text: Never Send stops it as it would have.
    private var resumedProduction = false
    /// A write that failed was said in this chat: once is enough.
    private var unsaved = false
    /// "Keep chats" was off at some point of this chat: it isn't written any more, even once it's back on.
    private var unkept = false
    private var holdsProduction: Bool { !prodSent.isEmpty || session?.readProduction == true || resumedProduction }

    /// Ask, Edit or Agent (task 23 PR 7, 8): what the next ↩ goes with. New Chat keeps it; a launch starts in Ask.
    enum Mode: Int { case ask, edit, agent }
    private(set) var mode = Mode.ask
    private let modes = NSSegmentedControl(), modeNote = NSTextField(labelWithString: "")
    private var modeRow: NSStackView?
    /// What this chat may do where (`AISession.granted`): a chip a place, and + to give one View. `giving`: a level
    /// the row is setting — its question, if any, goes with New Chat.
    private let scopeRow = ChipFlow(), scopeLine = NSStackView()
    private var giving: Task<Void, Never>?
    /// The answer a turn is writing: where a proposed change's card and a plan go.
    private weak var answering: Answer?
    /// The plan this answer shows, updated in place; a later answer's plan is a card of its own.
    private weak var planCard: PlanCard?
    /// Dollars this chat has cost since it was started or opened, request by request, and up to where it goes on
    /// before it asks again — for the cap it was given under (another cap: that one). `unpriced`: a request had no
    /// price to count — said once a chat, after its answer (`toldUnpriced`).
    private var spent = 0.0, allowance: (cap: Double, until: Double)?, unpriced = false, toldUnpriced = false

    private var built = false
    private let list = NSStackView(), scroll = NSScrollView()
    private let input = ChatInput(usingTextLayoutManager: false), inputScroll = NSScrollView()
    private let chipRow = ChipFlow(), info = NSTextField(labelWithString: ""), model = NSButton()
    private let send = NSButton(), composer = NSStackView()

    // MARK: - Building

    /// Once, when first shown.
    func build() {
        guard !built else { return refresh() }
        built = true
        let title = NSTextField(labelWithString: "AI")
        title.font = .boldSystemFont(ofSize: 13)
        model.bezelStyle = .inline
        model.controlSize = .small
        model.target = self
        model.action = #selector(openSettings)
        model.toolTip = "Settings › AI"
        model.lineBreakMode = .byTruncatingMiddle
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [NSImageView(image: Symbol.ai.image("AI")), title, model, spacer,
                                       iconButton(.recent, "Chats", #selector(chatsMenu(_:))), iconButton(.newDocument, "New Chat", #selector(newChat)),
                                       iconButton(.close, "Hide  ⌃⌘I", #selector(hide))])
        (head.spacing, head.edgeInsets) = (6, NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 6))

        modes.segmentCount = 3
        ["Ask", "Edit", "Agent"].enumerated().forEach { modes.setLabel($1, forSegment: $0) }
        (modes.trackingMode, modes.controlSize, modes.selectedSegment, modes.target, modes.action) = (.selectOne, .small, 0, self, #selector(modeChanged))
        modes.setToolTip("Reads and answers; changes nothing", forSegment: 0)
        modes.setToolTip("Also proposes changes to files as a diff — only your ⌘S saves", forSegment: 1)
        modes.setToolTip("Also acts — writes files, copies, runs commands — within what you allow this chat", forSegment: 2)
        (modeNote.font, modeNote.textColor, modeNote.lineBreakMode) = (.systemFont(ofSize: 11), .secondaryLabelColor, .byTruncatingTail)
        modeNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [modes, modeNote])
        (row.spacing, row.edgeInsets) = (8, NSEdgeInsets(top: 0, left: 12, bottom: 6, right: 12))
        modeRow = row
        showMode()
        scopeLine.setViews([scopeRow], in: .top)
        scopeLine.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 6, right: 12)
        scopeRow.widthAnchor.constraint(equalTo: scopeLine.widthAnchor, constant: -24).isActive = true

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let doc = Flipped()
        list.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: doc.topAnchor), list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor), list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        input.delegate = self
        input.font = .systemFont(ofSize: 13)
        input.isRichText = false
        input.allowsUndo = true
        input.textContainerInset = NSSize(width: 4, height: 6)
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.placeholder = "Ask about what's open — # adds context"
        input.onCommandReturn = { [unowned self] in if let card { card.answer(0) } else { send(input.string) } }
        input.onFocus = { [unowned self] in showChips() }   // what is open now
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder
        inputScroll.heightAnchor.constraint(equalToConstant: 66).isActive = true

        send.bezelStyle = .inline
        send.isBordered = false
        send.target = self
        send.action = #selector(sendOrStop)
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 11)
        info.lineBreakMode = .byTruncatingTail
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let foot = NSStackView(views: [iconButton(.plus, "Add Context  #", #selector(addMenu(_:))), iconButton(.show, "What Will Be Sent", #selector(preview(_:))), info, send])
        foot.spacing = 4
        composer.orientation = .vertical
        composer.alignment = .leading
        composer.spacing = 6
        composer.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        composer.setViews([chipRow, inputScroll, foot], in: .top)
        for v in [chipRow, inputScroll, foot] as [NSView] { v.widthAnchor.constraint(equalTo: composer.widthAnchor, constant: -20).isActive = true }

        let line = { () -> NSBox in let b = NSBox(); b.boxType = .separator; return b }
        let all = NSStackView(views: [head, row, scopeLine, line(), scroll, line(), composer])
        all.orientation = .vertical
        all.spacing = 0
        all.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(all)
        NSLayoutConstraint.activate([
            all.topAnchor.constraint(equalTo: view.topAnchor), all.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            all.leadingAnchor.constraint(equalTo: view.leadingAnchor), all.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            head.heightAnchor.constraint(equalToConstant: 36),
        ])
        for v in [head, row, scopeLine, scroll, composer] as [NSView] { v.widthAnchor.constraint(equalTo: all.widthAnchor).isActive = true }
        // Back from Settings with a key, or another model: said at once.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: app.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.app.aiChatShown == true { self?.refresh() } }
        }
        refresh()
    }

    private func iconButton(_ s: Symbol, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: s.image(tip), target: self, action: action)
        (b.bezelStyle, b.isBordered, b.toolTip) = (.inline, false, tip)
        return b
    }

    /// The key, the model, the chips Kermo suggests — as things are now. No Keychain read: `has` only.
    func refresh() {
        guard built else { return }
        let d = app.defaults, hasKey = AISettings.ready(d)
        model.title = d.string(forKey: "aiModel").flatMap { $0.isEmpty ? nil : $0 } ?? (AISettings.kind(d) == .anthropic ? AISettings.anthropicModel : "Choose a model")
        composer.isHidden = !hasKey
        modeRow?.isHidden = !hasKey
        scopeLine.isHidden = !hasKey
        showScope()
        if !hasKey, chat == nil { return showEmpty(setup: true) }
        if chat == nil, list.arrangedSubviews.isEmpty || list.arrangedSubviews.first is Empty { showEmpty(setup: false) }
        showChips()
        updateSend()
    }

    func focus() {
        view.window?.makeFirstResponder(composer.isHidden ? view : input)
        if !composer.isHidden { showChips() }
    }
    var hasFocus: Bool { (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true }

    private final class Empty: NSStackView {}

    private func showEmpty(setup: Bool) {
        let title = NSTextField(labelWithString: setup ? "Use your own AI" : "Ask about what's open")
        title.font = .boldSystemFont(ofSize: 14)
        let does = switch mode {
        case .ask: "The model only reads: it changes nothing."
        case .edit: "The model reads, and proposes changes to files as a diff you keep or drop: only your ⌘S saves."
        case .agent: "The model acts within what you allow this chat — the Scope row. Deleting, writing over a file, a copy between machines and any change on production ask each time."
        }
        let text = Self.wrapped(setup
            ? "Kermo sends your questions straight from this Mac to the provider you choose, with your key: Anthropic, or an OpenAI-compatible server — Ollama or LM Studio on your Mac too. No Kermo server, no Kermo account."
            : "Kermo suggests what's open below: the panel's folder, the file under the cursor, the editor, the terminal. Nothing goes anywhere until you add it and press ↩. " + does)
        text.textColor = .secondaryLabelColor
        let views: [NSView] = [NSImageView(image: Symbol.ai.image()), title, text] + (setup ? [NSButton(title: "Settings › AI…", target: self, action: #selector(openSettings))] : [])
        let e = Empty(views: views)
        (e.orientation, e.alignment, e.spacing) = (.vertical, .centerX, 8)
        list.setViews([e], in: .top)
        e.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -24).isActive = true
        text.widthAnchor.constraint(equalTo: e.widthAnchor).isActive = true
    }

    // MARK: - Chips

    /// What is open now, each once: the editor's document and selection, the panels' file under the cursor and folder
    /// (the active one only, unless `all`), the terminal's last command.
    func contexts(all: Bool) -> [Context] {
        var out: [Context] = []
        if let h = EditorHost.shared, h.window?.isVisible == true, let e = h.active {
            out += [Self.selection(e), Self.document(e)].compactMap { $0 }
        }
        for p in all ? app.panels : [app.active] {
            if let r = p.remote, p.list == nil, p.searchTitle == nil {
                let t = r.target.asUser, at = AISession.label(t)
                if let c = p.remoteCursor, c.item.kind == .file {
                    let path = (c.dir as NSString).appendingPathComponent(c.item.name)
                    out.append(file(path, on: t, title: "\(c.item.name) · \(at)"))
                }
                out.append(folder(r.dir, on: t, title: "\(r.dir) · \(at)"))
            } else if let dir = p.plainFolder {
                if let u = p.cursorURL, p.item(at: p.table.selectedRow)?.kind == .file {   // the panel's look, no disk access here
                    out.append(file(u.path, on: nil, title: "\(u.lastPathComponent) · this Mac"))
                }
                out.append(folder(dir, on: nil, title: "\((dir as NSString).abbreviatingWithTildeInPath) · this Mac"))
            }
        }
        if app.terminal?.isShown == true, let tab = app.terminal.current, tab.view.output() != nil {
            let o = tab.origin
            out.append(Context(id: "term:\(tab.id)", title: Self.title("Last command", tab, unsure: o.unsure), symbol: .terminal, server: o.server) { [weak tab] in
                guard let tab else { return .failure("The tab was closed.") }
                guard let text = tab.view.commandWithOutput() else { return .failure("Nothing to read there: no command printed anything, or a full-screen program is running.") }
                // Suggested a while ago: an `ssh` since, or in the command itself, makes it another machine's.
                guard await tab.learnedOrigin(ran: String(text.prefix { $0 != "\n" })).server == o.server else {
                    return .failure("That command is another machine's — ⇧⌘I in the terminal adds it as that one's.")
                }
                return AISession.handOver(text, limit: 16_000, keepEnd: true)
            })
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    private func file(_ path: String, on t: SFTPTarget?, title: String) -> Context {
        Context(id: "file:\(t.map(AISession.label) ?? "mac"):\(path)", title: title, symbol: .doc, server: t) {
            switch await AISession.text(t, path) {
            case .failure(let no): .failure(no.text)
            case .success(let (text, cut)): AISession.handOver(text, cut: cut)
            }
        }
    }
    private func folder(_ path: String, on t: SFTPTarget?, title: String) -> Context {
        Context(id: "dir:\(t.map(AISession.label) ?? "mac"):\(path)", title: title, symbol: .folder, server: t) {
            var r = await AISession.listing(t, path)
            if !r.isError { r = AISession.handOver(r.text) }
            return r
        }
    }

    // MARK: - Selection → chat (task 23 PR 6)

    /// The editor's selection, read now. A terminal's or a comparison's copy is its origin's: a production server's
    /// output is production's.
    static func selection(_ e: Editor) -> Context? {
        let range = e.textView.selectedRange()
        guard range.length > 0 else { return nil }
        let selected = (e.textView.string as NSString).substring(with: range)
        return Context(id: "sel:\(e.id):\(range)", title: "Selection · \(e.name)", symbol: .document, server: e.origin?.asUser) { AISession.handOver(selected) }
    }

    /// The editor's document, read as it is attached.
    static func document(_ e: Editor) -> Context {
        Context(id: "editor:\(e.id)", title: "\(e.name) · editor", symbol: .document, server: e.origin?.asUser) { [weak e] in
            e.map { AISession.handOver($0.textView.string) } ?? .failure("The document was closed.")
        }
    }

    /// A terminal tab's text, taken by the caller as it was (showing the chat narrows the terminal, which drops its
    /// selection and its marks) — its selection, or a "Command" with what it printed —, from where the tab says it is
    /// once `ssh -G` has said where an `ssh` there goes (`learnedOrigin`): a command's own line too (`ssh prod 'df'`).
    static func terminal(_ tab: EmbeddedTerminal.Tab, _ text: String, what: String) async -> Context {
        let o = await tab.learnedOrigin(ran: what == "Command" ? String(text.prefix { $0 != "\n" }) : nil)
        return Context(id: "tsel:\(tab.id):\(text.hashValue)", title: title(what, tab, unsure: o.unsure), symbol: .terminal, server: o.server) {
            AISession.handOver(text, limit: 16_000, keepEnd: true)
        }
    }

    private static func title(_ what: String, _ tab: EmbeddedTerminal.Tab, unsure: Bool) -> String {
        "\(what) · \(tab.label)" + (unsure ? " · as whoever is logged in" : "")
    }

    /// A panel's marked items, else the one under the cursor: files to read, folders to list.
    func marked(_ p: PanelViewController) -> [Context] {
        let items = p.selectedItems.filter { $0.kind != .other }
        if let r = p.remote, p.list == nil, p.searchTitle == nil {
            let t = r.target.asUser, at = AISession.label(t)
            return items.map { i in
                let path = (r.dir as NSString).appendingPathComponent(i.name)
                return i.kind == .dir ? folder(path, on: t, title: "\(path) · \(at)") : file(path, on: t, title: "\(i.name) · \(at)")
            }
        }
        guard let dir = p.plainFolder else { return [] }
        return items.map { i in
            let path = (dir as NSString).appendingPathComponent(i.name)
            return i.kind == .dir ? folder(path, on: nil, title: "\((path as NSString).abbreviatingWithTildeInPath) · this Mac") : file(path, on: nil, title: "\(i.name) · this Mac")
        }
    }

    /// ⇧⌘I, ⌥-click, Add to Chat: these chips, read now, and the chat shown with the keys in its field. Without the AI
    /// set up: the chat's "Use your own AI", nothing read.
    func add(_ found: [Context]) {
        if !app.aiChatShown { app.setAIChat(shown: true) }
        app.window.makeKeyAndOrderFront(nil)
        guard AISettings.ready(app.defaults) else { return }
        let fresh = found.filter { c in !chips.contains { $0.context.id == c.id } }
        attach(Array(fresh.prefix(10)))
        if fresh.count > 10 { flash("The first 10 of \(fresh.count) — ⇧⌘I again for the next.") }
    }

    // MARK: - ✨ Explain (task 23 PR 6b)

    static let question = "Why did this fail?"

    /// ✨ Explain: what failed, attached as any chip is — a production server's asked about at ↩, none taken under
    /// Never Send — and `question` in the field, unless words are there or a question of the chat's waits. Nothing goes
    /// until ↩. The app shows the chat first (`AppDelegate.explain`). Make with AI… asks its own.
    func explain(_ found: [Context], asking question: String = AIPanel.question) {
        guard AISettings.ready(app.defaults) else { return }
        let had = Set(chips.map(\.context.id))   // clicked again: the question comes back with its chip
        guard attach(found) > 0 || found.contains(where: { had.contains($0.id) }), card == nil,
              input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input.string = question
        input.setSelectedRange(NSRange(location: (question as NSString).length, length: 0))
        updateInfo()
    }

    /// Make with AI… (task 23 PR 9): Kermo's tool format as a chip — docs/tools.md's part on it, from the app.
    static var toolFormat: Context {
        Context(id: "tool-format", title: "Kermo's tool format", symbol: .document, server: nil) {
            AIResult("Kermo's tool format, from its docs (docs/tools.md). A tool is one JSON file: answer with the whole file in one ```json block — "
                     + "Kermo opens it in its tool editor, unsaved, where Problems checks it and Test runs its list on a server.\n\n" + ToolNew.format)
        }
    }

    /// What failed — a command, a check, an alert — with what it said, from the machine it failed on (nil: this Mac):
    /// masked, its last 16 KB. `what`: "systemctl restart -- nginx.service", "nginx -t on site.conf".
    static func failure(_ what: String, on server: SFTPTarget?, _ text: String) -> Context {
        let at = server.map(AISession.label) ?? "this Mac"
        return Context(id: "why:\(at):\(what):\(text.hashValue)", title: "\(what) · \(at)", symbol: .warn, server: server?.asUser) {
            AISession.handOver(text, limit: 16_000, keepEnd: true)
        }
    }

    /// Follow selection: each ↩ takes what is selected then where the user selected last — a terminal tab or the
    /// editor —, until it's clicked off. New Chat turns it off.
    private(set) var following = false
    private weak var selectedTab: EmbeddedTerminal.Tab?
    private weak var selectedEditor: Editor?
    private var editorLast = false

    /// A selection made (or gone) in a terminal tab, or in an editor (its caret moved): where Follow and ⇧⌘I from the
    /// field look.
    func selected(_ tab: EmbeddedTerminal.Tab) {
        (selectedTab, editorLast) = (tab, false)
        followMoved()
    }
    func selected(_ e: Editor) {
        (selectedEditor, editorLast) = (e, true)
        followMoved()
    }
    /// Where Follow would take from as the chip last showed it: a caret moving as the user types redraws nothing.
    private var followShown: (title: String, server: SFTPTarget?)?
    private func followMoved() {
        guard following, built else { return }
        let now = followSource()
        if now?.title != followShown?.title || now?.server != followShown?.server { showChips() }
    }

    /// Where Follow would take from now — the chip's words and the machine; nil: nothing selected. Nothing is copied.
    private func followSource() -> (title: String, server: SFTPTarget?)? {
        if editorLast {
            guard let e = selectedEditor, e.textView.selectedRange().length > 0 else { return nil }
            return ("Selection · \(e.name)", e.origin?.asUser)
        }
        guard let tab = selectedTab, tab.view.selectionActive else { return nil }
        let o = tab.origin
        return (Self.title("Selection", tab, unsure: o.unsure), o.server)
    }

    /// What is selected now where the user selected last — its text taken now, its chip made once where it's from is
    /// known; nil: nothing.
    func selectionNow() -> (() async -> Context)? {
        if editorLast { return selectedEditor.flatMap(Self.selection).map { c in { c } } }
        guard let tab = selectedTab, let text = tab.view.getSelection(), !text.isEmpty else { return nil }
        return { await Self.terminal(tab, text, what: "Selection") }
    }

    func toggleFollow() {
        following.toggle()
        showChips()
        if following, followShown?.server.map(SavedServer.isProd) == true, AISettings.neverProd(app.defaults) {
            flash("Settings › AI: nothing from a production server goes to the AI — that selection won't go.")
        }
    }

    /// The Follow chip, attached chips, then up to four suggestions (dashed: a click adds one).
    private func showChips() {
        let now = following ? followSource() : nil
        followShown = now
        let follow = ChipButton(title: following ? now.map { "Following: " + $0.title } ?? "Following selection — none now" : "Follow selection",
                                symbol: .follow, suggested: !following, prod: now?.server.map(SavedServer.isProd) ?? false, plus: false) { [unowned self] _ in toggleFollow() }
        follow.toolTip = following ? "On: what is selected in the terminal or the editor when you press ↩ goes with the message. Click to turn off."
            : "Turn on: what is selected in the terminal or the editor when you press ↩ goes with each message."
        let added = chips.enumerated().map { i, c -> NSView in
            let b = ChipButton(title: c.context.title + (c.text == nil ? " …" : ""), symbol: c.context.symbol, suggested: false, prod: isProd(c.context)) { [unowned self] v in
                showChip(i, from: v)
            }
            b.toolTip = c.text.map { "\($0.text.count) characters" + Self.hiddenWords($0.text) } ?? "Reading…"
            return b
        }
        let have = Set(chips.map(\.context.id))
        let suggested = contexts(all: false).filter { !have.contains($0.id) }.prefix(4).map { c -> NSView in
            ChipButton(title: c.title, symbol: c.symbol, suggested: true, prod: isProd(c)) { [unowned self] _ in attach(c) }
        }
        chipRow.set([follow] + added + suggested)
        updateInfo()
    }

    private static func hiddenWords(_ text: String) -> String { text.contains("secret") && text.contains("•••") ? " · secrets hidden as •••" : "" }

    private func isProd(_ c: Context) -> Bool { c.server.map(SavedServer.isProd) ?? false }

    /// Read now, as the user sees it: a locked server asks for Touch ID; a production one, under Never Send, isn't read.
    func attach(_ c: Context) { attach([c]) }

    /// Several, read one after another: one Touch ID for a locked server, never a server's sessions all at once. How
    /// many were taken.
    @discardableResult
    func attach(_ cs: [Context]) -> Int {
        var seen = Set(chips.map(\.context.id))
        let new = cs.filter { seen.insert($0.id).inserted }
        let never = AISettings.neverProd(app.defaults), taken = new.filter { !(never && isProd($0)) }
        guard !new.isEmpty else { focus(); return 0 }
        chips += taken.map { Attached(context: $0) }
        focus()   // the chips drawn again
        if taken.count < new.count { flash("Settings › AI: nothing from a production server goes to the AI.") }
        let before = reading
        reading = Task {
            await before?.value   // after what was attached a moment ago: its Touch ID covers these
            var refused = Set<String>()   // a server that stayed locked isn't asked again for the next chip
            for c in taken {
                var r = AIResult.failure("\(c.server.map(AISession.label) ?? "This Mac") stays locked.")
                if let t = c.server, refused.contains(Self.key(t)) {}
                else if let got = await read(c) { r = got }
                else if let t = c.server { refused.insert(Self.key(t)) }
                guard let i = chips.firstIndex(where: { $0.context.id == c.id }) else { continue }   // removed meanwhile
                if r.isError { chips.remove(at: i) } else { chips[i].text = r }
                showChips()
                if r.isError { flash(r.text.bidiVisible) }
            }
        }
        return taken.count
    }
    /// The reads of what was attached, one after another.
    private var reading: Task<Void, Never>?

    /// A chip's text as the user would see it: a locked server asks for Touch ID first; nil: it stayed locked.
    private func read(_ c: Context) async -> AIResult? {
        if let t = c.server, case .locked = await app.gate([t], to: "read “\(c.title.bidiVisible)” for the AI on") { return nil }
        return await c.read()
    }

    private func showChip(_ i: Int, from v: NSView) {
        guard chips.indices.contains(i) else { return }
        let c = chips[i]
        Self.pop(c.context.title, c.text?.text ?? "Reading…", from: v, button: ("Remove", { [weak self] in
            self?.chips.removeAll { $0.context.id == c.context.id }
            self?.showChips()
        }))
    }

    @objc private func addMenu(_ sender: NSView?) { popAddMenu(at: sender, removingHash: false) }

    /// "+" or "#": what is open, a click attaches it.
    private func popAddMenu(at anchor: NSView?, removingHash: Bool) {
        let menu = NSMenu()
        let have = Set(chips.map(\.context.id))
        for c in contexts(all: true) {
            let item = MenuAction.item(c.title.bidiVisible) { [unowned self] in
                if removingHash { dropHash() }
                attach(c)
            }
            item.image = c.symbol.image()
            item.isEnabled = !have.contains(c.id)
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "Nothing open to add", action: nil, keyEquivalent: "").isEnabled = false }
        menu.autoenablesItems = false
        if let anchor {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
            return
        }
        let caret = input.firstRect(forCharacterRange: input.selectedRange(), actualRange: nil)
        let at = input.convert(input.window?.convertPoint(fromScreen: caret.origin) ?? .zero, from: nil)
        menu.popUp(positioning: nil, at: at, in: input)
    }

    /// The "#" typed just before the caret, gone once it did its work.
    private func dropHash() {
        let at = input.selectedRange().location
        guard at > 0, (input.string as NSString).substring(with: NSRange(location: at - 1, length: 1)) == "#" else { return }
        input.insertText("", replacementRange: NSRange(location: at - 1, length: 1))
    }

    // MARK: - Sending

    @objc private func sendOrStop() { turn == nil ? send(input.string) : stop() }

    func stop() { turn?.cancel() }

    /// Why this chat can't go on, in words; nil: it can. It stays with the provider it started with (its production
    /// questions named that one), and under Never Send a chat that took production text goes no further.
    private func blocked(_ e: AIEndpoint) -> String? {
        if let pinned, pinned != Self.pin(e) { return "Settings › AI names another provider now: a New Chat goes there." }
        if AISettings.neverProd(app.defaults), holdsProduction {
            return "This chat holds text from a production server, and Settings › AI says Never Send: start a New Chat."
        }
        return nil
    }
    private static func pin(_ e: AIEndpoint) -> String { "\(e.kind.rawValue) \(e.address.absoluteString)" }

    /// The words of the last question sent: Save as Tool's title.
    private var question = ""

    func send(_ typed: String) {
        guard turn == nil, card == nil, !composer.isHidden else { return }
        let question = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Follow selection: what is selected now — taken now — goes as a chip would.
        let follow = following ? selectionNow() : nil
        guard !question.isEmpty || !chips.isEmpty || follow != nil else { return }
        guard chips.allSatisfy({ $0.text != nil }) else { return flash("Still reading what you attached…") }
        guard let e = AISettings.endpoint(app.defaults) else { return note("Settings › AI: the address isn't one.", error: true, settings: true) }
        if let why = e.problem() { return note("Settings › AI: " + why, error: true, settings: true) }
        if let why = blocked(e) { return note(why, error: true) }
        if AISettings.neverProd(app.defaults), chips.contains(where: { isProd($0.context) }) {
            return note("Settings › AI: nothing from a production server goes to the AI. Remove its chip to send.", error: true)
        }
        let attached = chips, g = generation
        failedAt = nil
        turn = Task {
            var asked = attached, followed: String?
            let f = await follow?()   // where it's from: `ssh -G` may be asked (~15 ms)
            guard g == generation else { return }   // New Chat meanwhile
            guard !Task.isCancelled else { return finish() }
            if let f, !chips.contains(where: { $0.context.id == f.id }) {
                if isProd(f), AISettings.neverProd(app.defaults) {
                    flash("The followed selection is from a production server: it doesn't go (Settings › AI).")
                } else {   // as a chip is: Touch ID for a locked server. Still locked, or a Stop meanwhile: nothing goes.
                    let r = await read(f)
                    guard g == generation else { return }
                    guard let r, !r.isError, !Task.isCancelled else {
                        note("The followed selection wasn't read: \(r?.text ?? "\(f.server.map(AISession.label) ?? "this Mac") stayed locked.") Nothing was sent.", error: true)
                        return finish()
                    }
                    if following { (followed, asked) = (f.id, asked + [Attached(context: f, text: r)]) }   // turned off meanwhile: not
                }
            }
            // Production: asked once a chat for each server, ↩ = Cancel. Nothing is sent until each said yes.
            for t in Self.unique(asked.compactMap(\.context.server)) where SavedServer.isProd(t) && !prodSent.contains(Self.key(t)) {
                let answer = await app.gate([t], to: "send what you attached to the AI from", question: { [self] in sendQuestion(t, e) }) { c, _ in await self.ask(c) }
                guard g == generation else { return }   // New Chat meanwhile
                guard case .pass = answer, !Task.isCancelled else { return finish() }
                prodSent.insert(Self.key(t))
                pinned = pinned ?? Self.pin(e)   // the consent named this provider: the chat is its from now on
                append(Self.prodLine(AISession.label(t), host: e.address.host ?? "the provider"))
            }
            // What is attached now: a chip removed while a question was up doesn't go; Never Send may have come meanwhile.
            let sent = asked.filter { a in a.context.id == followed && following || chips.contains { $0.context.id == a.context.id } }   // turned off meanwhile: not
            guard !(AISettings.neverProd(app.defaults) && sent.contains { isProd($0.context) }), !sent.isEmpty || !question.isEmpty else { return finish() }
            let prod = Self.unique(sent.compactMap(\.context.server)).filter(SavedServer.isProd).map(AISession.label)
            let message = AIChat.compose(question, attached: sent.map { ($0.context.title, $0.text?.text ?? "") }, production: prod)
            if chat == nil { start(e) } else if let c = chat, c.system != system {   // switched since: the history goes on, its thinking doesn't
                chat = AIChat(system: system, tools: tools, messages: AISavedChat.resumable(c.messages))
            }
            chat?.add(message)
            // Attached from a server or a terminal: it can steer the model as its own read can (the questions' ⚠).
            if sent.contains(where: { $0.context.server != nil || $0.context.symbol == .terminal }) { session?.hasRead = true }
            self.question = question
            self.asked.append(AISavedChat.Asked(question: AISecrets.mask(question).text, chips: sent.map { AIChat.attachedName($0.context.title) },
                                           prod: sent.filter { isProd($0.context) }.map { AIChat.attachedName($0.context.title) }))
            save()   // the question is kept even if the turn never ends (New Chat, quitting)
            chips.removeAll { c in sent.contains { $0.context.id == c.context.id } }
            if input.string == typed { input.string = "" }   // words typed meanwhile stay
            append(Self.userMessage(question, sent.map { ($0.context.title, isProd($0.context)) }))
            showChips()
            await run(e, g)
        }
        updateSend()
    }

    /// The mode's instructions and tools, and the chat's session (`madeSession`).
    private func begin(_ messages: [AIMessage]) {
        chat = AIChat(system: system, tools: tools, messages: messages)
        madeSession()
    }

    /// The chat's session — made at its first send, or when the scope row gives a place View before it: nothing
    /// allowed yet. Edit reads as Ask does — a proposed change is a card, not a write.
    @discardableResult private func madeSession() -> AISession {
        if let session { return session }
        let s = AISession(app: app) { [weak self] c, _ in await self?.ask(c) ?? 1 }
        s.readOnly = mode != .agent
        s.proposes = { [weak self] p, t, path in
            guard let self else { return }
            let card = EditCard(p, on: t, path: path, app: app)
            if let answering { answering.attach(card) } else { append(card) }
        }
        s.plans = { [weak self] in self?.showPlan($0) }
        s.scopeChanged = { [weak self] in self?.showScope() }
        session = s
        showScope()
        return s
    }

    private var system: String { [AIChat.askSystem, AIChat.editSystem, AIChat.agentSystem][mode.rawValue] }
    private var tools: [AITool] { [AIChat.askTools, AIChat.editTools, AIChat.agentTools][mode.rawValue] }

    @objc private func modeChanged() { setMode(Mode(rawValue: modes.selectedSegment) ?? .ask) }

    /// The mode from the next ↩ on; a turn going on ends in the mode it began.
    func setMode(_ m: Mode) {
        mode = m
        showMode()
        if chat == nil, list.arrangedSubviews.first is Empty, !composer.isHidden { showEmpty(setup: false) }
    }

    private func showMode() {
        modes.selectedSegment = mode.rawValue
        modeNote.stringValue = switch mode {
        case .ask: "Reads what you allow and answers."
        case .edit: "Also proposes changes to files, as a diff you keep or drop."
        case .agent: "Also acts within the scope below, asking before anything else."
        }
    }

    // MARK: - Scope

    /// The scope row: what this chat may do where — a chip's click changes or takes it back; + gives a place View.
    private func showScope() {
        guard built else { return }
        var views: [NSView] = [Answer.small("Scope")]
        if granted.isEmpty { views.append(Answer.small("nothing yet — the AI asks first")) }
        for g in granted {
            let chip = ChipButton(title: g.words, symbol: g.place == .mac ? .mac : .server, suggested: false, prod: g.prod) { [unowned self] v in pop(scopeMenu(g), from: v) }
            chip.toolTip = g.words + " — click to change or take back"
            chip.setAccessibilityLabel("Scope: " + g.words)
            views.append(chip)
        }
        let plus = ChipButton(title: "", symbol: .plus, suggested: true, prod: false, plus: false) { [unowned self] v in pop(addScopeMenu(), from: v) }
        plus.toolTip = "Let the AI read on a server or this Mac"
        plus.setAccessibilityLabel("Give a place View")
        scopeRow.set(views + [plus])
    }

    /// What this chat may do where, as the scope row shows it.
    var granted: [AISession.Granted] { session?.granted ?? [] }

    private func pop(_ menu: NSMenu, from v: NSView) { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: v.bounds.maxY + 4), in: v) }

    /// A place's level, set by the user: View, Work (its folders, and commands on a server), All — in Ask and Edit
    /// View only — or taken back. The level it has is a no-op: Work from Work doesn't add commands.
    func scopeMenu(_ g: AISession.Granted) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "\(g.name.bidiVisible) in this chat", action: nil, keyEquivalent: "").isEnabled = false
        for (level, title) in [(AIScope.Level.view, "View — reads only"), (.work, "Work — its folders, and commands"), (.all, "All — anything there")] {
            let item = MenuAction.item(title) { [unowned self] in
                guard g.level != level, let session else { return }
                giving = Task { await session.set(g.place, level) }
            }
            // This Mac runs no commands: its Work is only the folders a task was given.
            (item.state, item.isEnabled) = (g.level == level ? .on : .off, (mode == .agent || level == .view) && !(level == .work && g.place == .mac))
            menu.addItem(item)
        }
        menu.addItem(MenuAction.item("Take Back") { [unowned self] in session?.takeAway(g.place) })
        menu.addItem(.separator())
        menu.addItem(withTitle: "Asked always, under All too: deleting, writing over a file, any change on production", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: g.place == .mac ? "All on this Mac: any file you can write, ~/Library/LaunchAgents too" : "A command allowed here may write over files unasked",
                     action: nil, keyEquivalent: "").isEnabled = false
        return menu
    }

    /// The places in front of the user and the saved servers, those not in the scope yet: a click gives View.
    func addScopeMenu() -> NSMenu {
        let c = app.aiContext, have = Set(granted.map(\.name))
        var all: [SFTPTarget?] = [nil]
        for t in [c.active.server, c.other.server, c.editor?.server, c.terminal?.server].compactMap({ $0?.asUser }) + ServerLock.servers().map(\.target.asUser)
        where !all.contains(where: { $0.map { ServerLock.same($0, t) } ?? false }) { all.append(t) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Let the AI read on…", action: nil, keyEquivalent: "").isEnabled = false
        let never = AISettings.neverProd(app.defaults)
        for t in all {
            let name = t.map(AISession.label) ?? "this Mac"
            guard !have.contains(name), !(never && t.map(SavedServer.isProd) == true) else { continue }
            menu.addItem(MenuAction.item(name.bidiVisible + (t.map(SavedServer.isProd) == true ? " (PROD)" : "")) { [unowned self] in
                let s = madeSession()
                giving = Task { await s.give(t) }
            })
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "View until the chat ends; its chip gives more", action: nil, keyEquivalent: "").isEnabled = false
        return menu
    }

    private func showPlan(_ steps: [(text: String, state: String)]) {
        if let planCard, let answering, planCard.isDescendant(of: answering) { return planCard.set(steps) }
        let card = PlanCard(steps)
        planCard = card
        if let answering { answering.attach(card) } else { append(card) }
    }

    // MARK: - Spending

    /// Settings › AI's cap on what one chat costs, in dollars; 0: none. Known only at Anthropic's prices (`AIPrice`).
    static func cap(_ d: UserDefaults) -> Double { d.object(forKey: "aiChatLimit") as? Double ?? 2 }

    /// A request's price into this chat's.
    private func count(_ u: AIUsage, _ g: Int) {
        guard g == generation else { return }
        if let d = u.dollars { spent += d } else { unpriced = true }
    }

    /// Before each request: past the cap the user is asked to go on, as much again; Stop answers it no.
    private func goOn() async -> Bool {
        let cap = Self.cap(app.defaults), until = allowance.flatMap { $0.cap == cap ? $0.until : nil } ?? cap
        guard cap > 0, spent >= until else { return true }
        var next = until + cap
        while next <= spent { next += cap }
        var c = Confirm("This chat has cost \(Answer.dollars(spent)). Go on, up to \(Answer.dollars(next))?", action: "Go On")
        (c.cancel, c.returnCancels) = ("Stop", true)
        c.note = "Settings › AI stops a chat at \(Answer.dollars(cap)), and asks again each time as much more. Stop keeps the chat as it is."
        guard await ask(c) == 0 else { return false }
        allowance = (cap, next)
        return true
    }

    private func start(_ e: AIEndpoint) {
        begin([])
        pinned = Self.pin(e)
        (chatID, began, beganWith, unkept) = (UUID().uuidString, Date(), e.model, !Self.keepsChats(app.defaults))
    }

    private func sendQuestion(_ t: SFTPTarget, _ e: AIEndpoint) -> Confirm? {
        guard SavedServer.isProd(t) else { return nil }   // known by now, however it was typed
        var c = Confirm("Send what you attached from \(AISession.label(t)) to \(e.address.host ?? "your AI provider")?", on: t, action: "Send")
        c.note = "A production server: asked once in this chat. Secrets Kermo recognises go as •••."
        c.returnCancels = true
        return c
    }

    /// One turn, as it comes; again for Retry. `g`: the chat it belongs to.
    private func run(_ e: AIEndpoint, _ g: Int) async {
        guard let chat, let session else { return }
        // The chat's mode as it was built at ↩ — a Retry's too — not the segment's now.
        session.readOnly = chat.system != AIChat.agentSystem
        let answer = Answer(model: e.model, panel: self, mode: chat.system == AIChat.editSystem ? "Edit" : chat.system == AIChat.agentSystem ? "Agent" : nil)
        append(answer)
        answering = answer
        let (ran, did) = (session.commands.count, session.journal.count)
        do {
            let (end, used) = try await chat.turn(e.provider(AISettings.transport), call: { await session.call($0, $1) }, show: { [weak self] in
                // A change after a server's text: its step says ⚠ (calls go one by one: the journal's last is this one).
                var warn = false
                if case .called = $0, let last = session.journal.last { warn = last.afterRead && last.changes }
                answer.show($0, warn: warn)
                self?.follow()
            }, spent: { [weak self] u in self?.count(u, g) }, goOn: { [weak self] in await self?.goOn() ?? false })
            answer.end(end, used, rounds: chat.rounds)
            if chat.system == AIChat.agentSystem { offerTool(Array(session.commands[ran...]), Array(session.journal[did...]), under: answer) }
        } catch is CancellationError {
            answer.end(note: "Stopped. Nothing more was asked or read.")
        } catch {
            let e2 = error as? AIError ?? AIError(.other, error.localizedDescription)
            if g == generation { failedAt = chat.messages.count }
            answer.end(note: e2.words, error: true, action: e2.kind == .key ? ("Settings…", { [weak self] in self?.openSettings() }) : ("Retry", { [weak self] in self?.retry() }))
        }
        if g == generation {
            // At Anthropic, a model Kermo has no price for: the cap doesn't count it. Said once a chat.
            if unpriced, !toldUnpriced, Self.cap(app.defaults) > 0, AISettings.kind(app.defaults) == .anthropic {
                toldUnpriced = true
                note("Kermo has no price for this model at this address: Settings › AI's cap doesn't count it — only the rounds a turn may take stop it.", error: false)
            }
            save()
            finish()
        }
    }

    /// A command that starts something in the background (`nohup … &`, `a & b`) — not `&&`, `2>&1`, `&>`, `|&`: a
    /// tool's run ends what it started (its watcher stops its session), so Save as Tool leaves it out.
    static func inBackground(_ command: String) -> Bool { command.contains(/(^|[^&>|])&(\s|$)/) }

    /// Save as Tool (task 23 PR 9): an Agent turn that ran two commands or more on one server, all ending well, offers
    /// them as a tool — next time one click, no model. The draft opens unsaved in the tool editor; what wasn't a
    /// command (a copy, a file written, a Tools action) is said in its `about`, not in it.
    private func offerTool(_ all: [(server: SFTPTarget, command: String, folder: String?)], _ did: [AISession.Entry], under answer: Answer) {
        let background = all.filter { Self.inBackground($0.command) }.count, ran = all.filter { !Self.inBackground($0.command) }
        guard ran.count >= 2, let t = ran.first?.server, ran.allSatisfy({ ServerLock.same($0.server, t) }), all.allSatisfy({ ServerLock.same($0.server, t) }) else { return }
        let server = AISession.label(t), said = AISession.oneLine(String(question.prefix { $0 != "\n" }), max: 40)
        let title = said.isEmpty ? "From a Chat" : said
        let left = did.filter { ["copy", "write_file", "tool_action"].contains($0.tool) && !$0.result.isError }.count
        let all = ran.map(\.command).joined(separator: "\n")
        let about = "Made from an AI chat on \(Date().formatted(date: .abbreviated, time: .omitted)): the commands it ran on \(server) that ended well, as they ran."
            + (left == 0 ? "" : " Left out: \(left) step\(left == 1 ? "" : "s") that weren't commands (copies, files written, Tools actions).")
            + (background == 0 ? "" : " Left out: \(background) command\(background == 1 ? "" : "s") started in the background (&) — a tool's run ends what it started.")
            + (all.contains("•••") ? " ••• is a secret Kermo hid: put a value the tool asks for in its place." : "")
            + (ToolTemplate.placeholders(in: all).isEmpty ? "" : " {…} in a command is a value of Kermo's in a tool: Problems names each — awk's {print} wants spaces, { print }.")
        let text = ToolNew.text(commands: ran.map { ($0.command, $0.folder) }, id: ToolNew.id(from: title) ?? "from-a-chat", title: title, about: about)
        answer.offer("It ran \(ran.count) commands on \(server): as a tool they're one click next time, with no AI.", ("Save as Tool…", { [weak self] in
            self.map { ToolEditor.draft($0.app, text) }
        }))
    }

    /// Only while the chat is as the failed request left it: an older Retry would ask for something else.
    private func retry() {
        guard turn == nil, let n = failedAt, chat?.messages.count == n, let e = AISettings.endpoint(app.defaults), e.problem() == nil else { return }
        if let why = blocked(e) { return note(why, error: true) }
        let g = generation
        turn = Task { await run(e, g) }
        updateSend()
    }

    private func finish() {
        turn = nil
        updateSend()
        follow()
    }

    private func note(_ words: String, error: Bool, settings: Bool = false) {
        let open: (String, () -> Void) = ("Settings…", { [weak self] in self?.openSettings() })
        append(Answer.noteRow(words, error: error, action: settings ? open : nil))
    }

    @objc private func newChat() {
        stop()
        giving?.cancel()
        generation += 1
        (chat, session, prodSent, turn, pinned, failedAt) = (nil, nil, [], nil, nil, nil)
        (chatID, asked, resumedProduction, unsaved, unkept, following) = (nil, [], false, false, false, false)
        (spent, allowance, unpriced, toldUnpriced) = (0, nil, false, false)
        list.setViews([], in: .top)
        refresh()
        focus()
    }

    // MARK: - Chats on this Mac

    static func keepsChats(_ d: UserDefaults) -> Bool { d.object(forKey: "aiKeepChats") as? Bool ?? true }

    /// After each send and each turn (stopped and failed too), as the history stands — what went, masked as it went,
    /// without the thinking (never sent again). Off: nothing, and this chat is never written again, even once it's on.
    private func save() {
        guard let chat, let id = chatID, !unkept else { return }
        guard Self.keepsChats(app.defaults) else { return unkept = true }
        let first = asked.first.map { $0.question.isEmpty ? $0.chips.first ?? "" : $0.question } ?? ""
        let title = String(first.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
        let saved = AISavedChat(title: title, model: beganWith, provider: pinned ?? "", started: began, production: holdsProduction,
                                messages: AISavedChat.resumable(chat.messages), asked: asked)
        let g = generation
        chats.save(id, saved) { [weak self] why in
            guard let self, g == generation, !unsaved else { return }   // in its own chat, once
            unsaved = true
            note("Not kept on this Mac: \(why). The chat goes on here.", error: true)
        }
    }

    /// The chats kept on this Mac, the latest first: a click opens one; Delete removes one for good.
    @objc private func chatsMenu(_ sender: NSView) {
        chats.list { [weak self, weak sender] in if let self, let sender { showChats($0, from: sender) } }   // off the main thread
    }

    private func showChats(_ found: (chats: [AIChatStore.Entry], unread: [String]), from sender: NSView) {
        let (saved, unread) = found
        let menu = NSMenu()
        menu.autoenablesItems = false
        if saved.isEmpty { menu.addItem(withTitle: "No chats kept on this Mac", action: nil, keyEquivalent: "").isEnabled = false }
        let label = { (c: AIChatStore.Entry) in
            "\((c.title.isEmpty ? "Untitled" : c.title).bidiVisible) — \(c.updated.formatted(date: .abbreviated, time: .shortened)) · \(c.model.bidiVisible)"
        }
        for c in saved {
            let item = MenuAction.item(label(c)) { [unowned self] in open(c.id) }
            item.state = c.id == chatID ? .on : .off
            menu.addItem(item)
        }
        if !saved.isEmpty {
            let delete = NSMenu()
            for c in saved {
                delete.addItem(MenuAction.item(label(c)) { [unowned self] in
                    var q = Confirm("Delete the chat “\((c.title.isEmpty ? "Untitled" : c.title).bidiVisible)”?", action: "Delete")
                    (q.note, q.irreversible) = ("Its file goes for good, not to the Trash.", true)
                    Task { if await app.confirm(q) == 0 { deleteChat(c.id) } }
                })
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: nil, keyEquivalent: "").submenu = delete
        }
        if !unread.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Not read — left as \(unread.count == 1 ? "it is" : "they are"):", action: nil, keyEquivalent: "").isEnabled = false
            for why in unread {
                let item = menu.addItem(withTitle: why, action: nil, keyEquivalent: "")
                (item.isEnabled, item.indentationLevel) = (false, 1)
            }
        }
        if !Self.keepsChats(app.defaults) {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings › AI: new chats aren't kept", action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    /// A kept chat, to go on with: its text and what was attached, by name — no steps. Production and reading are
    /// asked again; its provider is still its own; its thinking isn't sent (`AISavedChat.resumable`).
    func open(_ id: String) {
        guard id != chatID else { return }
        let saved: AISavedChat
        switch chats.read(id) {
        case .failure(let why): return flash("Not opened: \(why.words).")
        case .success(let c): saved = c
        }
        newChat()
        build()
        begin(AISavedChat.resumable(saved.messages))
        session?.hasRead = saved.heard   // its history still holds what a server said
        (chatID, began, beganWith, asked, resumedProduction) = (id, saved.started, saved.model, saved.asked, saved.production)
        pinned = saved.provider.isEmpty ? nil : saved.provider
        var i = 0, answer: Answer?
        for m in saved.messages {
            if m.role == .user {
                for case .text in m.parts {
                    let a = saved.asked.indices.contains(i) ? saved.asked[i] : AISavedChat.Asked(question: "…", chips: [], prod: [])
                    append(Self.userMessage(a.question, a.chips.map { ($0, a.prod.contains($0)) }))
                    (i, answer) = (i + 1, nil)
                }
            } else if !m.text.isEmpty {
                if answer == nil {
                    answer = Answer(model: saved.model, panel: self)
                    append(answer!)
                }
                answer?.show(.text(m.text + "\n\n"))
                answer?.settle()
            }
        }
        refresh()
        follow(force: true)
    }

    func deleteChat(_ id: String) {
        if id == chatID { newChat() }   // its turn ends without writing it back
        chats.delete([id])
    }

    /// Settings › AI's "Keep chats on this Mac" switched off: the open chat isn't written again, even once it's back
    /// on — a deleted one never comes back; the ones kept go only if the user says so.
    static func keepChatsChanged(_ app: AppDelegate, panel: AIPanel? = nil) {
        guard !keepsChats(app.defaults), let panel = panel ?? app.aiPanel else { return }
        panel.unkept = true
        panel.chats.list { found in
            let ids = found.chats.map(\.id)
            guard !ids.isEmpty else { return }
            Task {
                var c = Confirm("Delete the \(ids.count == 1 ? "chat" : "\(ids.count) chats") kept on this Mac?", action: "Delete")
                (c.note, c.irreversible, c.cancel) = ("New chats aren't kept either way.", true, "Keep")
                if await app.confirm(c) == 0 { panel.chats.delete(ids) }
            }
        }
    }

    @objc private func hide() { app.toggleAIChat(focusFirst: false) }
    @objc func openSettings() { SettingsWindow.show(app, tab: "AI") }

    private func updateSend() {
        guard built else { return }
        let running = turn != nil
        send.image = (running ? Symbol.stop : Symbol.send).image(running ? "Stop" : "Send")
        send.toolTip = running ? "Stop  ⎋" : "Send  ↩"
        send.contentTintColor = running ? nil : .controlAccentColor
    }

    private func updateInfo() {
        guard flashUntil <= Date() else { return }
        let followed = following ? followShown?.server : nil   // as the chip shows it: nothing read on each key
        let prod = Self.unique(chips.compactMap(\.context.server) + [followed].compactMap { $0 }).filter(SavedServer.isProd).map(AISession.label)
        if !prod.isEmpty {
            info.stringValue = "\(prod.joined(separator: ", ")) (PROD) goes to \(AISettings.address(app.defaults)?.host ?? "your provider")"
            info.textColor = Palette.prod
        } else {
            let chars = chips.reduce(input.string.count) { $0 + ($1.text?.text.count ?? 0) }
            info.stringValue = chars == 0 ? "" : "≈ \(Self.tokens(chars / 4)) tokens"
            info.textColor = .secondaryLabelColor
        }
    }

    /// "What Will Be Sent": the instructions, the message as it would go now. Earlier messages go too.
    @objc private func preview(_ sender: NSView) {
        let follow = following ? selectionNow() : nil
        Task {   // the followed selection as it is now — what ↩ would take
            var all = chips
            if let f = await follow?(), !chips.contains(where: { $0.context.id == f.id }), !(isProd(f) && AISettings.neverProd(app.defaults)) {
                all.append(Attached(context: f, text: await f.read()))
            }
            let prod = Self.unique(all.compactMap(\.context.server)).filter(SavedServer.isProd).map(AISession.label)
            let message = AIChat.compose(input.string.trimmingCharacters(in: .whitespacesAndNewlines), attached: all.map { ($0.context.title, $0.text?.text ?? "…") }, production: prod)
            let host = AISettings.address(app.defaults)?.host ?? "your provider"
            let text = "— Kermo's instructions —\n\(system)\n\n— This message —\n\(message)\n\n"
                + "— Also —\nThe tools' descriptions\(chat.map { $0.messages.isEmpty ? "" : ", and the \($0.messages.count) earlier messages of this chat" } ?? ""). "
                + "Straight to \(host), with your key from the Keychain."
            Self.pop("What goes to \(host)", text, from: sender)
        }
    }

    // MARK: - Questions in the chat

    /// The session's and the send's questions, as a card at the end of the chat. A Stop answers it Cancel.
    func ask(_ c: Confirm) async -> Int {
        if AppDelegate.answering != nil { return await app.confirm(c) }   // the tests' answers
        let cancel = c.buttons.count - 1
        guard !Task.isCancelled else { return cancel }
        if !app.aiChatShown { app.setAIChat(shown: true) }   // the user's turn waits on it: seen, but the keys stay where they are
        let asking = Asking()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<Int, Never>) in
                let v = Card(c) { [weak self] i in
                    if self?.card === asking.card { self?.card = nil }
                    k.resume(returning: i)
                }
                (asking.card, card) = (v, v)
                append(v)
                if Task.isCancelled { v.answer(cancel) }
            }
        } onCancel: {
            Task { @MainActor in asking.card?.answer(cancel) }
        }
    }
    /// The card one question shows: a Stop answers that one, whatever the chat shows by then.
    @MainActor private final class Asking { weak var card: Card? }

    // MARK: - Keys in the field

    func textView(_ v: NSTextView, doCommandBy s: Selector) -> Bool {
        switch s {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            if let card { card.answer(card.confirm.safe ? card.confirm.buttons.count - 1 : 0) } else { send(input.string) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if turn != nil { stop() } else { app.window.makeFirstResponder(app.active.table) }
            return true
        default: return false
        }
    }

    func textView(_ v: NSTextView, shouldChangeTextIn range: NSRange, replacementString s: String?) -> Bool {
        if s == "#", range.location == 0 || (v.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)).first?.isWhitespace == true {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.popAddMenu(at: nil, removingHash: true) } }
        }
        return true
    }

    func textDidChange(_ n: Notification) { updateInfo() }

    // MARK: - The chat's views

    private func append(_ v: NSView) {
        if list.arrangedSubviews.first is Empty { list.setViews([], in: .top) }   // the chat's first word
        let bottom = atBottom
        list.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -24).isActive = true
        if bottom { follow(force: true) }
    }

    private var atBottom: Bool { scroll.documentVisibleRect.maxY >= (scroll.documentView?.bounds.height ?? 0) - 24 }

    /// Kept at the end while the user is there.
    func follow(force: Bool = false) {
        guard force || atBottom else { return }
        view.layoutSubtreeIfNeeded()
        scroll.documentView?.scroll(NSPoint(x: 0, y: max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)))
    }

    /// For a moment, in the composer's line.
    func flash(_ words: String) {
        info.stringValue = words
        info.textColor = .labelColor
        flashUntil = Date() + 4
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in MainActor.assumeIsolated { self?.updateInfo() } }
    }
    /// Words said a moment ago stay that long: the chips redrawn meanwhile don't write over them.
    private var flashUntil = Date.distantPast

    /// A code block's Into Terminal: in the line of the terminal tab on the machine in front of the user — nothing runs.
    func intoTerminal(_ code: String) {
        let target = app.terminal?.isShown == true ? app.terminal.current?.target : app.active.remote?.target
        Task {
            let r = await app.toTerminal(code, run: false, on: target, folder: nil, path: nil, owner: self, askOn: view.window) { self.flash($0) }
            switch r {
            case .sent(let words), .notSent(let words): flash(words)
            case .cancelled: break
            }
        }
    }

    private static func userMessage(_ text: String, _ chips: [(String, Bool)]) -> NSView {
        var views: [NSView] = text.isEmpty ? [] : [ChatText(NSAttributedString(string: text.bidiVisible, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))]
        if !chips.isEmpty {
            let s = NSMutableAttributedString()
            for (i, (title, prod)) in chips.enumerated() {
                if i > 0 { s.append(NSAttributedString(string: "  ·  ")) }
                if prod { s.append(Chip.prod.text); s.append(NSAttributedString(string: " ")) }
                s.append(NSAttributedString(string: title.bidiVisible))
            }
            s.addAttributes([.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: 0, length: s.length))
            views.append(ChatText(s))
        }
        let stack = NSStackView(views: views)
        (stack.orientation, stack.alignment, stack.spacing) = (.vertical, .leading, 4)
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return TintBox(stack, fill: NSColor.controlAccentColor.withAlphaComponent(0.12), inset: NSSize(width: 10, height: 8))
    }

    private static func prodLine(_ server: String, host: String) -> NSView {
        let s = NSMutableAttributedString(attributedString: Chip.prod.text)
        s.append(NSAttributedString(string: " \(server): what you attach from it goes to \(host) in this chat.",
                                    attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: Palette.prod]))
        return TintBox(ChatText(s), fill: Palette.prod.withAlphaComponent(0.1), inset: NSSize(width: 8, height: 5))
    }

    // MARK: - Small things

    static func wrapped(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.preferredMaxLayoutWidth = 280
        l.alignment = .center
        return l
    }

    /// A small push button that runs `act`.
    static func button(_ title: String, _ act: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: act)
        (b.bezelStyle, b.controlSize) = (.push, .small)
        return b
    }

    static func tokens(_ n: Int) -> String { n < 1000 ? "\(n)" : String(format: "%.1fk", Double(n) / 1000) }

    private static func key(_ t: SFTPTarget) -> String { ServerLock.identity(t.asUser) ?? t.asUser.shown }
    private static func unique(_ ts: [SFTPTarget]) -> [SFTPTarget] { ts.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    /// A text in a popover: a chip's, a step's result, what will be sent.
    static func pop(_ title: String, _ text: String, from anchor: NSView, button: (String, () -> Void)? = nil) {
        let head = NSTextField(labelWithString: title.bidiVisible)
        head.font = .boldSystemFont(ofSize: 12)
        head.lineBreakMode = .byTruncatingMiddle
        let textView = NSTextView(usingTextLayoutManager: false)
        (textView.isEditable, textView.drawsBackground) = (false, false)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text.bidiVisible
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        (scroll.documentView, scroll.hasVerticalScroller, scroll.drawsBackground) = (textView, true, false)
        let popover = NSPopover()
        var views: [NSView] = [head, scroll]
        if let (title, act) = button {
            views.append(Self.button(title) { [weak popover] in popover?.close(); act() })
        }
        let stack = NSStackView(views: views)
        (stack.orientation, stack.alignment, stack.spacing, stack.edgeInsets) = (.vertical, .leading, 6, NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: 320)
        for v in [head, scroll] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true }
        let vc = NSViewController()
        vc.view = stack
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
}

// MARK: - Views

private final class Flipped: NSView { override var isFlipped: Bool { true } }

/// The question field: ↩ sends (⇧↩ a new line), ⌘↩ answers a question's action, a placeholder while empty.
final class ChatInput: NSTextView {
    var placeholder = ""
    var onCommandReturn: () -> Void = {}
    var onFocus: () -> Void = {}
    override func becomeFirstResponder() -> Bool {
        defer { onFocus() }
        return super.becomeFirstResponder()
    }
    override func keyDown(with e: NSEvent) {
        if (e.keyCode == 36 || e.keyCode == 76) && e.modifierFlags.contains(.command) { return onCommandReturn() }
        super.keyDown(with: e)
    }
    override func draw(_ r: NSRect) {
        super.draw(r)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        NSAttributedString(string: placeholder, attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
            .draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height))
    }
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// Read-only text as tall as it needs at the width it is given: a reply's paragraph, a code block.
final class ChatText: NSTextView {
    convenience init(_ s: NSAttributedString) {
        self.init(usingTextLayoutManager: false)   // TextKit 1: measured below
        (isEditable, isSelectable, drawsBackground) = (false, true, false)
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        set(s)
    }
    func set(_ s: NSAttributedString) {
        textStorage?.setAttributedString(s)
        invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(lm.usedRect(for: tc).height))
    }
    override func setFrameSize(_ size: NSSize) {
        let changed = size.width != frame.width
        super.setFrameSize(size)
        if changed { invalidateIntrinsicContentSize() }
    }
}

/// Views laid in rows, as many to a row as fit: the composer's chips.
final class ChipFlow: NSView {
    override var isFlipped: Bool { true }
    func set(_ views: [NSView]) {
        subviews = views
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        place(bounds.width, apply: true)
    }
    @discardableResult private func place(_ width: CGFloat, apply: Bool) -> CGFloat {
        var (x, y, row) = (CGFloat(0), CGFloat(0), CGFloat(0))
        for v in subviews {
            let s = v.fittingSize
            if x > 0, x + s.width > width { (x, y, row) = (0, y + row + 4, 0) }
            if apply { v.frame = NSRect(x: x, y: y, width: min(s.width, width), height: s.height) }
            (x, row) = (x + s.width + 4, max(row, s.height))
        }
        return y + row
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: place(bounds.width, apply: false)) }
    override func setFrameSize(_ size: NSSize) {
        let changed = size.width != frame.width
        super.setFrameSize(size)
        if changed { invalidateIntrinsicContentSize() }
    }
}

/// A context chip: attached (a click shows what goes), or suggested — dashed, a click attaches it. Production's
/// carries its capsule.
final class ChipButton: NSButton {
    private let act: (NSView) -> Void
    private let suggested: Bool
    /// `plus`: "+ " before a suggestion's title (not before Follow selection's).
    init(title: String, symbol: Symbol, suggested: Bool, prod: Bool, plus: Bool = true, act: @escaping (NSView) -> Void) {
        (self.act, self.suggested) = (act, suggested)
        super.init(frame: .zero)
        let s = NSMutableAttributedString()
        if prod { s.append(Chip.prod.text); s.append(NSAttributedString(string: " ")) }
        s.append(NSAttributedString(string: (suggested && plus ? "+ " : "") + title.bidiVisible,
                                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: suggested ? NSColor.secondaryLabelColor : NSColor.labelColor]))
        attributedTitle = s
        image = symbol.image()
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        (isBordered, bezelStyle, lineBreakMode) = (false, .inline, .byTruncatingMiddle)
        target = self
        action = #selector(run)
        setAccessibilityLabel((suggested ? "Suggested: " : "Attached: ") + title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { act(self) }
    override var intrinsicContentSize: NSSize { let s = super.intrinsicContentSize; return NSSize(width: min(s.width + 14, 260), height: 20) }
    override func draw(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if suggested { path.setLineDash([3, 2], count: 2, phase: 0) } else {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
        }
        NSColor.separatorColor.setStroke()
        path.stroke()
        super.draw(r)
    }
}

/// A question in the chat — the session's (reading on a server) or the send's (production): Confirm's words, its
/// buttons; once answered, one line of what was said.
final class Card: NSStackView {
    let confirm: Confirm
    private var done: ((Int) -> Void)?
    init(_ c: Confirm, done: @escaping (Int) -> Void) {
        (confirm, self.done) = (c, done)
        super.init(frame: .zero)
        (orientation, alignment, spacing) = (.vertical, .leading, 6)
        let title = ChatText(NSAttributedString(string: c.title.bidiVisible, attributes: [.font: NSFont.boldSystemFont(ofSize: 12.5), .foregroundColor: NSColor.labelColor]))
        var views: [NSView] = [title]
        if let s = Confirm.strip(c.strip, c.place) { views.append(s) }
        for line in c.items.map(\.name) + [c.runs, c.command, c.note].compactMap({ $0 }) {
            views.append(ChatText(NSAttributedString(string: line.bidiVisible, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])))
        }
        let buttons = NSStackView(views: c.buttons.enumerated().reversed().map { i, title in
            let b = AIPanel.button(title) { [weak self] in self?.answer(i) }
            if i == 0, !c.safe { b.bezelColor = .controlAccentColor }
            return b
        })
        buttons.spacing = 6
        let keys = NSTextField(labelWithString: c.safe ? "↩ \(c.cancel) · ⌘↩ \(c.action)" : "↩ \(c.action) · ⎋ \(c.cancel)")
        (keys.font, keys.textColor) = (.systemFont(ofSize: 11), .secondaryLabelColor)
        views += [NSStackView(views: [buttons, keys])]
        edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        setViews(views, in: .top)
        for v in views { v.widthAnchor.constraint(equalTo: widthAnchor, constant: -20).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    /// Once: the buttons go, a line says what was answered.
    func answer(_ i: Int) {
        guard let done else { return }
        self.done = nil
        let said = NSTextField(labelWithString: (i == 0 ? "✓ \(confirm.action)" : "✗ \(confirm.buttons[i])") + " — " + confirm.title.bidiVisible)
        (said.font, said.textColor, said.lineBreakMode) = (.systemFont(ofSize: 11.5), .secondaryLabelColor, .byTruncatingTail)
        setViews([said], in: .top)
        said.widthAnchor.constraint(equalTo: widthAnchor, constant: -20).isActive = true
        done(i)
    }
}

/// A task's steps as the model last told them (`plan`): ○ to do, ▸ doing, ✓ done, struck through skipped.
final class PlanCard: NSStackView {
    private let steps = ChatText(NSAttributedString())
    init(_ list: [(text: String, state: String)]) {
        super.init(frame: .zero)
        (orientation, alignment, spacing, edgeInsets) = (.vertical, .leading, 4, NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
        let head = NSTextField(labelWithString: "✨ Plan")
        (head.font, head.textColor) = (.systemFont(ofSize: 11.5, weight: .semibold), .secondaryLabelColor)
        setViews([head, steps], in: .top)
        for v in [head, steps] { v.widthAnchor.constraint(equalTo: widthAnchor, constant: -20).isActive = true }
        set(list)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ list: [(text: String, state: String)]) {
        let s = NSMutableAttributedString(), lines = NSMutableParagraphStyle()
        lines.headIndent = 20   // a step's second line under its words, never at the marks' edge as a step of its own
        for (i, step) in list.enumerated() {
            let (mark, tint) = switch step.state {
            case "doing": ("▸", NSColor.controlAccentColor)
            case "done": ("✓", Palette.ok)
            case "skipped": ("–", NSColor.secondaryLabelColor)
            default: ("○", NSColor.secondaryLabelColor)
            }
            var words: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: step.state == "doing" ? .semibold : .regular),
                                                        .foregroundColor: step.state == "skipped" ? NSColor.secondaryLabelColor : NSColor.labelColor]
            s.append(NSAttributedString(string: (i == 0 ? "" : "\n") + mark + "  ", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: tint]))
            if step.state == "skipped" { words[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            s.append(NSAttributedString(string: step.text.bidiVisible, attributes: words))
        }
        s.addAttribute(.paragraphStyle, value: lines, range: NSRange(location: 0, length: s.length))
        steps.set(s)
        setAccessibilityLabel("Plan: " + list.map { "\($0.text), \($0.state)" }.joined(separator: "; "))
    }

    override func draw(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}
