import AppKit
import DFMCore

/// The AI chat right of the panels and the terminal (⌃⌘I, the toolbar's ✨): the user's own model in Ask — it reads
/// and answers, it changes nothing. What goes is what the user attached (chips) and what the model's reads return;
/// every read is `AISession.call` (`readOnly`: the user is only ever asked to let it read). Without a key: a card that
/// leads to Settings › AI. Nothing is made before the panel is first shown, and the key is read at the first send.
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
    private var session: AISession?
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
    private var holdsProduction: Bool { !prodSent.isEmpty || session?.readProduction == true || resumedProduction }

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
        let all = NSStackView(views: [head, line(), scroll, line(), composer])
        all.orientation = .vertical
        all.spacing = 0
        all.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(all)
        NSLayoutConstraint.activate([
            all.topAnchor.constraint(equalTo: view.topAnchor), all.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            all.leadingAnchor.constraint(equalTo: view.leadingAnchor), all.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            head.heightAnchor.constraint(equalToConstant: 36),
        ])
        for v in [head, scroll, composer] as [NSView] { v.widthAnchor.constraint(equalTo: all.widthAnchor).isActive = true }
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
        session?.noProduction = AISettings.neverProd(app.defaults)   // back from Settings: the next read already knows
        let d = app.defaults, hasKey = AISettings.hasKey(d) || AISettings.address(d).map(AIEndpoint.isLocal) == true && AISettings.kind(d) == .openai
        model.title = d.string(forKey: "aiModel").flatMap { $0.isEmpty ? nil : $0 } ?? (AISettings.kind(d) == .anthropic ? AISettings.anthropicModel : "Choose a model")
        composer.isHidden = !hasKey
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
        let text = Self.wrapped(setup
            ? "Kermo sends your questions straight from this Mac to the provider you choose, with your key: Anthropic, or an OpenAI-compatible server — Ollama or LM Studio on your Mac too. No Kermo server, no Kermo account."
            : "Kermo suggests what's open below: the panel's folder, the file under the cursor, the editor, the terminal. Nothing goes anywhere until you add it and press ↩. The model only reads: it changes nothing.")
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
            // A terminal's or a comparison's copy is its origin's: a production server's output is production's.
            let name = e.name, t = e.origin?.asUser
            let range = e.textView.selectedRange()
            if range.length > 0 {
                let selected = (e.textView.string as NSString).substring(with: range)
                out.append(Context(id: "sel:\(e.id):\(range)", title: "Selection · \(name)", symbol: .document, server: t) { AISession.handOver(selected) })
            }
            out.append(Context(id: "editor:\(e.id)", title: "\(name) · editor", symbol: .document, server: t) { [weak e] in
                e.map { AISession.handOver($0.textView.string) } ?? .failure("The document was closed.")
            })
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
            out.append(Context(id: "term:\(tab.id)", title: "Last command · \(tab.label)", symbol: .terminal, server: tab.target?.asUser) {
                guard let o = tab.view.output() else { return .failure("Nothing to read there: no command printed anything, or a full-screen program is running.") }
                return AISession.handOver((tab.view.marks.last?.text).map { $0 + "\n" + o } ?? o, limit: 16_000, keepEnd: true)
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

    /// Attached chips, then up to four suggestions (dashed: a click adds one).
    private func showChips() {
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
        chipRow.set(added + suggested)
        updateInfo()
    }

    private static func hiddenWords(_ text: String) -> String { text.contains("secret") && text.contains("•••") ? " · secrets hidden as •••" : "" }

    private func isProd(_ c: Context) -> Bool { c.server.map(SavedServer.isProd) ?? false }

    /// Read now, as the user sees it: a locked server asks for Touch ID; a production one, under Never Send, isn't read.
    func attach(_ c: Context) {
        guard !chips.contains(where: { $0.context.id == c.id }) else { return }
        if isProd(c), AISettings.neverProd(app.defaults) { return flash("Settings › AI: nothing from a production server goes to the AI.") }
        chips.append(Attached(context: c))
        showChips()
        Task {
            var r = AIResult.failure("\(c.server.map(AISession.label) ?? "This Mac") stays locked.")
            if let t = c.server, case .locked = await app.gate([t], to: "read “\(c.title.bidiVisible)” for the AI on") {} else { r = await c.read() }
            guard let i = chips.firstIndex(where: { $0.context.id == c.id }) else { return }   // removed meanwhile
            if r.isError { chips.remove(at: i) } else { chips[i].text = r }
            showChips()
            if r.isError { flash(r.text.bidiVisible) }   // after: the chips' line would write over it
        }
        focus()
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

    func send(_ typed: String) {
        guard turn == nil, card == nil, !composer.isHidden else { return }
        let question = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !chips.isEmpty else { return }
        guard chips.allSatisfy({ $0.text != nil }) else { return flash("Still reading what you attached…") }
        guard let e = AISettings.endpoint(app.defaults) else { return note("Settings › AI: the address isn't one.", error: true, settings: true) }
        if let why = e.problem() { return note("Settings › AI: " + why, error: true, settings: true) }
        if let why = blocked(e) { return note(why, error: true) }
        if AISettings.neverProd(app.defaults), chips.contains(where: { isProd($0.context) }) {
            return note("Settings › AI: nothing from a production server goes to the AI. Remove its chip to send.", error: true)
        }
        let asked = chips, g = generation
        failedAt = nil
        turn = Task {
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
            let sent = asked.filter { a in chips.contains { $0.context.id == a.context.id } }
            guard !(AISettings.neverProd(app.defaults) && sent.contains { isProd($0.context) }), !sent.isEmpty || !question.isEmpty else { return finish() }
            let prod = Self.unique(sent.compactMap(\.context.server)).filter(SavedServer.isProd).map(AISession.label)
            let message = AIChat.compose(question, attached: sent.map { ($0.context.title, $0.text?.text ?? "") }, production: prod)
            if chat == nil { start(e) }
            chat?.add(message)
            self.asked.append(AISavedChat.Asked(question: AISecrets.mask(question).text, chips: sent.map { AIChat.attachedName($0.context.title) },
                                           prod: sent.filter { isProd($0.context) }.map { AIChat.attachedName($0.context.title) }))
            chips.removeAll { c in sent.contains { $0.context.id == c.context.id } }
            if input.string == typed { input.string = "" }   // words typed meanwhile stay
            append(Self.userMessage(question, sent.map { ($0.context.title, isProd($0.context)) }))
            showChips()
            await run(e, g)
        }
        updateSend()
    }

    /// Ask's instructions and tools, and a session of its own: nothing allowed yet.
    private func begin(_ messages: [AIMessage]) {
        chat = AIChat(system: AIChat.askSystem, tools: AIChat.askTools, messages: messages)
        session = AISession(app: app) { [weak self] c, _ in await self?.ask(c) ?? 1 }
        session?.readOnly = true
    }

    private func start(_ e: AIEndpoint) {
        begin([])
        pinned = Self.pin(e)
        (chatID, began, beganWith) = (UUID().uuidString, Date(), e.model)
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
        session.noProduction = AISettings.neverProd(app.defaults)
        let answer = Answer(model: e.model, panel: self)
        append(answer)
        do {
            let (end, used) = try await chat.turn(e.provider(AISettings.transport), call: { await session.call($0, $1) }) { [weak self] in
                answer.show($0)
                self?.follow()
            }
            answer.end(end, used)
        } catch is CancellationError {
            answer.end(note: "Stopped. Nothing more was asked or read.")
        } catch {
            let e2 = error as? AIError ?? AIError(.other, error.localizedDescription)
            if g == generation { failedAt = chat.messages.count }
            answer.end(note: e2.words, error: true, action: e2.kind == .key ? ("Settings…", { [weak self] in self?.openSettings() }) : ("Retry", { [weak self] in self?.retry() }))
        }
        if g == generation {
            save()
            finish()
        }
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
        generation += 1
        (chat, session, prodSent, turn, pinned, failedAt) = (nil, nil, [], nil, nil, nil)
        (chatID, asked, resumedProduction, unsaved) = (nil, [], false, false)
        list.setViews([], in: .top)
        refresh()
        focus()
    }

    // MARK: - Chats on this Mac

    static func keepsChats(_ d: UserDefaults) -> Bool { d.object(forKey: "aiKeepChats") as? Bool ?? true }

    /// After each turn (stopped and failed too), as the history stands — what went, masked as it went, without the
    /// thinking (never sent again). Off: nothing, and this chat is never written again, even once it's back on.
    private func save() {
        guard let chat, let id = chatID else { return }
        guard Self.keepsChats(app.defaults) else { return chatID = nil }
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
    /// on; the ones kept go only if the user says so.
    static func keepChatsChanged(_ app: AppDelegate, panel: AIPanel? = nil) {
        guard !keepsChats(app.defaults), let panel = panel ?? app.aiPanel else { return }
        panel.chatID = nil
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
        let prod = Self.unique(chips.compactMap(\.context.server)).filter(SavedServer.isProd).map(AISession.label)
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
        let prod = Self.unique(chips.compactMap(\.context.server)).filter(SavedServer.isProd).map(AISession.label)
        let message = AIChat.compose(input.string.trimmingCharacters(in: .whitespacesAndNewlines), attached: chips.map { ($0.context.title, $0.text?.text ?? "…") }, production: prod)
        let host = AISettings.address(app.defaults)?.host ?? "your provider"
        let text = "— Kermo's instructions —\n\(chat?.system ?? AIChat.askSystem)\n\n— This message —\n\(message)\n\n"
            + "— Also —\nThe tools' descriptions\(chat.map { $0.messages.isEmpty ? "" : ", and the \($0.messages.count) earlier messages of this chat" } ?? ""). "
            + "Straight to \(host), with your key from the Keychain."
        Self.pop("What goes to \(host)", text, from: sender)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in MainActor.assumeIsolated { self?.updateInfo() } }
    }

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
    init(title: String, symbol: Symbol, suggested: Bool, prod: Bool, act: @escaping (NSView) -> Void) {
        (self.act, self.suggested) = (act, suggested)
        super.init(frame: .zero)
        let s = NSMutableAttributedString()
        if prod { s.append(Chip.prod.text); s.append(NSAttributedString(string: " ")) }
        s.append(NSAttributedString(string: (suggested ? "+ " : "") + title.bidiVisible,
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
