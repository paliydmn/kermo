import Foundation
import Testing
@testable import DFMCore

/// "text of token" → token, for readable assertions.
private func tokens(_ text: String, _ lang: Syntax.Language) -> [String: Syntax.Token] {
    let ns = text as NSString
    return Dictionary(Syntax.tokens(text, lang).map { (ns.substring(with: $0.range), $0.token) }, uniquingKeysWith: { a, _ in a })
}

@Test func shellStringsCommentsVariables() {
    let t = tokens(#"echo "path # not a comment" $HOME ${#arr} # real comment"# + "\nif [ -f x ]; then exit 1; fi", .shell)
    #expect(t["\"path # not a comment\""] == .string)
    #expect(t["# real comment"] == .comment)
    #expect(t["$HOME"] == .variable)
    #expect(t["${#arr}"] == .variable)          // ${#…} is length, not a comment
    #expect(t["if"] == .keyword && t["fi"] == .keyword)
    #expect(t["1"] == .number)
}

@Test func commentWithQuoteIsNotAString() {
    let t = tokens("# it's fine\nkey = 'v'", .ini)
    #expect(t["# it's fine"] == .comment)
    #expect(t["key"] == .key && t["'v'"] == .string)
}

@Test func jsonKeysVsValues() {
    let t = tokens(#"{"name": "web", "port": 8080, "tls": true, "x": null}"#, .json)
    #expect(t["\"name\""] == .key && t["\"web\""] == .string)
    #expect(t["8080"] == .number && t["true"] == .keyword && t["null"] == .keyword)
}

@Test func yamlAndConfAndXml() {
    let y = tokens("server:\n  - host: example.com # main\n    enabled: yes\n", .yaml)
    #expect(y["server"] == .key && y["- host"] == .key && y["enabled"] == .key)
    #expect(y["# main"] == .comment && y["yes"] == .keyword)

    let c = tokens("server {\n    listen 443 ssl; # https\n    root \"/var/www\";\n}\nPermitRootLogin no", .conf)
    #expect(c["listen"] == .key && c["443"] == .number && c["# https"] == .comment)
    #expect(c["\"/var/www\""] == .string && c["PermitRootLogin"] == .key && c["no"] == .keyword)

    let x = tokens(#"<!-- c --><key>Label</key><string a="1">x</string>"#, .xml)
    #expect(x["<!-- c -->"] == .comment && x["<key"] == .tag && x["a"] == .key && x["\"1\""] == .string)
}

@Test func languageDetection() {
    #expect(Syntax.language(forFileName: "deploy.SH") == .shell)
    #expect(Syntax.language(forFileName: "nginx.conf") == .conf)
    #expect(Syntax.language(forFileName: "com.app.plist") == .xml)
    #expect(Syntax.language(forFileName: "Dockerfile") == .dockerfile)
    #expect(Syntax.language(forFileName: "run", firstLine: "#!/usr/bin/env python3") == .python)
    #expect(Syntax.language(forFileName: ".zshrc") == .shell)
    #expect(Syntax.language(forFileName: "notes.txt") == nil)
}

@Test func pythonDockerfileMakefileAndCLike() {
    let py = tokens("@app.route('/x')\ndef f(x):\n    \"\"\"doc # not comment\n    second line\"\"\"\n    return None  # note\n", .python)
    #expect(py["@app.route"] == .variable && py["'/x'"] == .string)
    #expect(py["def"] == .keyword && py["return"] == .keyword && py["None"] == .keyword)
    #expect(py["\"\"\"doc # not comment\n    second line\"\"\""] == .string && py["# note"] == .comment)

    let docker = tokens("# base\nFROM ubuntu:22.04 AS build\nENV X=\"a b\" ${Y}\nRUN echo $HOME\n", .dockerfile)
    #expect(docker["# base"] == .comment && docker["FROM"] == .keyword && docker["AS"] == .keyword)
    #expect(docker["\"a b\""] == .string && docker["${Y}"] == .variable && docker["$HOME"] == .variable)

    let make = tokens("CC = gcc\nall: build # c\n\t$(CC) -o $@ main.c\n\techo \\# literal\nifeq ($(OS),Windows_NT)\nendif\n", .makefile)
    #expect(make["all"] == .key && make["# c"] == .comment && make["CC"] == nil)   // targets are keys, assignments aren't
    #expect(make["$(CC)"] == .variable && make["$@"] == .variable)
    #expect(make["ifeq"] == .keyword && make["endif"] == .keyword)
    #expect(make["# literal"] == nil)   // escaped hash is not a comment

    let c = tokens("#include <stdio.h>\n/* multi\nline */ int x = 0xFF; // tail\nlet s = `raw`; var n = foo123 + 1.5e3;\n", .clike)
    #expect(c["#include"] == .tag && c["/* multi\nline */"] == .comment && c["// tail"] == .comment)
    #expect(c["int"] == .keyword && c["0xFF"] == .number && c["`raw`"] == .string && c["1.5e3"] == .number)
    #expect(c["123"] == nil && c["foo123"] == nil)   // digits inside an identifier are not a number
}

@Test func yamlJsonIniDetails() {
    let y = tokens("---\nbase: &anchor\n  nested: ~\nother: *anchor\nflag: Off\n", .yaml)
    #expect(y["---"] == .tag && y["&anchor"] == .variable && y["*anchor"] == .variable)
    #expect(y["nested"] == .key && y["  nested"] == nil)   // indentation isn't painted
    #expect(y["~"] == .keyword && y["Off"] == .keyword)

    let j = tokens("{\"a\": [1, -2.5, \"x\"], // c\n \"b\": {\"c\": false}}", .json)
    #expect(j["\"a\""] == .key && j["\"c\""] == .key && j["\"x\""] == .string)
    #expect(j["-2.5"] == .number && j["false"] == .keyword && j["// c"] == .comment)

    let i = tokens("[section]\n; semi\nname = \"v\" ; not a comment here\nenabled: yes\n", .ini)
    #expect(i["[section]"] == .tag && i["; semi"] == .comment && i["name"] == .key && i["\"v\""] == .string)
    #expect(i["enabled"] == .key && i["yes"] == .keyword)
}

@Test func tokensAreOrderedNonOverlappingAndInBounds() {
    let sample = """
        #!/bin/sh
        # c "q" 'q' 0x1f 42 ${x} $y
        key = "value # \\" still" ; tail
        <a href="x">t</a> <!-- c --> {"k": [1, true, null]}
        /* block */ // line
        FROM x AS y
        ---
        - item: &a *a ~
        \"\"\"py\"\"\" '''q'''
        """
    let langs: [Syntax.Language] = [.shell, .python, .json, .yaml, .ini, .conf, .xml, .dockerfile, .makefile, .clike]
    let length = (sample as NSString).length
    for lang in langs {
        let t = Syntax.tokens(sample, lang)
        #expect(!t.isEmpty, "\(lang)")
        for (a, b) in zip(t, t.dropFirst()) { #expect(NSMaxRange(a.range) <= b.range.location, "\(lang): overlap") }
        for x in t { #expect(x.range.length > 0 && NSMaxRange(x.range) <= length, "\(lang): bounds") }
        #expect(Syntax.tokens("", lang).isEmpty)
    }
}

@Test func moreLanguageDetection() {
    #expect(Syntax.language(forFileName: "Makefile") == .makefile && Syntax.language(forFileName: "rules.mk") == .makefile)
    #expect(Syntax.language(forFileName: "Dockerfile.prod") == .dockerfile)
    #expect(Syntax.language(forFileName: "pyproject.toml") == .ini)
    #expect(Syntax.language(forFileName: ".gitconfig") == .ini)   // a dotfile has no extension for NSString
    #expect(Syntax.language(forFileName: "x.PY") == .python && Syntax.language(forFileName: "main.rs") == .clike)
    #expect(Syntax.language(forFileName: "index.html") == .xml && Syntax.language(forFileName: "my.cnf") == .conf)
    #expect(Syntax.language(forFileName: "run", firstLine: "#!/bin/bash") == .shell)
    #expect(Syntax.language(forFileName: "run", firstLine: "#!/usr/bin/env node") == nil)
    #expect(Syntax.language(forFileName: "README") == nil)
}
