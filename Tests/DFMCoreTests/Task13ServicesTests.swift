import Foundation
import Testing
@testable import DFMCore

// What servers print, made up after real ones (systemd 255 on Ubuntu 24.04, podman 4.9): each quirk once.

/// `systemctl list-units --type=service --all --output=json`: `job` too, `not-found` units from `--all`.
let unitsJSON = """
    [{"unit":"web.service","load":"loaded","active":"active","sub":"running","job":"","description":"Web server"},
    {"unit":"cron.service","load":"loaded","active":"active","sub":"running","job":"","description":"Regular background program processing daemon"},
    {"unit":"backup.service","load":"loaded","active":"failed","sub":"failed","job":"","description":"Nightly backup"},
    {"unit":"ghost.service","load":"not-found","active":"inactive","sub":"dead","job":"","description":"ghost.service"},
    {"unit":"getty@tty1.service","load":"loaded","active":"active","sub":"running","job":"","description":"Getty on tty1"},
    {"unit":"Alpha.service","load":"loaded","active":"inactive","sub":"dead","job":"","description":""}]
    """

/// `--plain --no-legend`: columns padded, the description last with its spaces; an old one may still mark a failed unit.
let unitsPlain = """
    web.service                 loaded    active   running Web server
    backup.service              loaded    failed   failed  Nightly backup
    ghost.service               not-found inactive dead    ghost.service
    ● db.service                loaded    failed   failed  Data  base
    """

@Test func servicesReadFromJSONAndFromTheTable() {
    let json = Services.parse(json: unitsJSON)
    #expect(json?.count == 6 && json?.first == ServiceUnit(unit: "web.service", active: "active", sub: "running", description: "Web server"))
    #expect(Services.parse(plain: unitsPlain) == [
        ServiceUnit(unit: "web.service", active: "active", sub: "running", description: "Web server"),
        ServiceUnit(unit: "backup.service", active: "failed", sub: "failed", description: "Nightly backup"),
        ServiceUnit(unit: "ghost.service", load: "not-found", active: "inactive", sub: "dead", description: "ghost.service"),
        ServiceUnit(unit: "db.service", active: "failed", sub: "failed", description: "Data  base"),
    ])
    #expect(Services.parse(json: "[{\"unit\": 1}]") == nil)
}

/// After the tool's line (a login script's words before it don't count): failed first, then by name, the not-found
/// ones gone; a server without systemd, a failing systemctl, a failed login — in words.
@Test func aServicesLookSaysWhatWentWrong() {
    func said(_ status: Int32, _ output: String, _ errors: String = "") -> String {
        switch Services.outcome(status: status, output: output, errors: errors, server: "web1") {
        case .success(let units): units.map(\.name).joined(separator: " ")
        case .failure(let e): e.message
        }
    }
    #expect(said(0, "Welcome!\nkermo-json\n" + unitsJSON) == "backup Alpha cron getty@tty1 web")
    #expect(said(0, "kermo-plain\n" + unitsPlain + "\n") == "backup db web")
    #expect(said(0, "kermo-json\n[]\n") == "")
    #expect(said(0, "kermo-none\n") == "web1 has no systemd (no systemctl there)")
    #expect(said(1, "kermo-plain\n", "Failed to connect to bus: No medium found") == "systemctl failed on web1: Failed to connect to bus: No medium found")
    #expect(said(0, "kermo-json\n[{oops\n") == "systemctl on web1 said something Kermo can't read")
    #expect(said(255, "", "me@web1: Permission denied (publickey).") == "me@web1: Permission denied (publickey).")
    #expect(said(127, "") == "Couldn't look at the services of web1 (exit 127)")
}

/// A name goes into a command only if it's made of what systemd or docker allow — never a shell word or an option —
/// and then quoted; anything else is shown, with nothing to run.
@Test func onlyPlainNamesGoIntoCommands() {
    let unit = { (u: String) in ServiceUnit(unit: u, active: "active", sub: "running").safe }
    #expect(unit("nginx.service") && unit("getty@tty1.service") && unit("systemd-fsck@dev-disk-by\\x2duuid-1.service") && unit("a:b_c.service"))
    for evil in ["x;reboot.service", "$(reboot).service", "a b.service", "a\nb.service", "-x.service", "nginx", "nginx.socket",
                 "`id`.service", "a'b.service", "ünit.service", ""] {
        #expect(!unit(evil), "\(evil)")
    }
    let box = { (n: String) in ContainerInfo(name: n, state: "running", status: "", image: "").safe }
    #expect(box("web") && box("web-1.blue_2"))
    for evil in ["-web", ".web", "a;b", "$(x)", "a b", "a\nb", "a/b", "a:b", "a@b", ""] { #expect(!box(evil), "\(evil)") }
    let u = ServiceUnit(unit: "getty@tty1.service", active: "active", sub: "running")
    #expect(Services.status(u) == "systemctl status --no-pager -- getty@tty1.service")
    #expect(Services.log(u) == "journalctl -u getty@tty1.service -n 200 -f --no-pager")
    #expect(Services.restart(u) == "systemctl restart -- getty@tty1.service")
    #expect(Services.status(ServiceUnit(unit: "fsck@a\\x2db.service", active: "active", sub: "exited")) == "systemctl status --no-pager -- 'fsck@a\\x2db.service'")
    let c = ContainerInfo(name: "web", state: "running", status: "Up 3 hours", image: "nginx:1")
    #expect(Containers.logs(c, tool: "podman") == "podman logs --tail 200 -f -- web" && Containers.restart(c, tool: "docker") == "docker restart -- web")
}

/// Running first, then by name; the tool said; tabs split the fields (an image name has none, a status has spaces).
@Test func aContainersLookSaysWhatWentWrong() {
    func said(_ status: Int32, _ output: String, _ errors: String = "") -> String {
        switch Containers.outcome(status: status, output: output, errors: errors, server: "web1") {
        case .success(let r): r.tool + ": " + r.containers.map { "\($0.name)=\($0.state)/\($0.status)/\($0.image)" }.joined(separator: " ")
        case .failure(let e): e.message
        }
    }
    let ps = "old\tExited (0) 2 days ago\tbusybox:1\nweb\tUp 3 hours\tnginx:1\napi\tUp 5 minutes (healthy)\tregistry.example.com/api:2\n"
        + "held\tUp 2 days (Paused)\tredis:7\nnew\tCreated\tpostgres:16\n"
    #expect(said(0, "Hi!\nkermo-podman\n" + ps) == "podman: api=running/Up 5 minutes (healthy)/registry.example.com/api:2 web=running/Up 3 hours/nginx:1 "
            + "held=paused/Up 2 days (Paused)/redis:7 new=created/Created/postgres:16 old=exited/Exited (0) 2 days ago/busybox:1")
    #expect(said(0, "kermo-docker\n") == "docker: ")
    #expect(said(0, "kermo-none\n") == "web1 has neither docker nor podman")
    #expect(said(1, "kermo-docker\n", "permission denied while trying to connect to the Docker daemon socket")
            == "docker failed on web1: permission denied while trying to connect to the Docker daemon socket")
    #expect(said(255, "", "ssh: connect to host web1 port 22: Connection refused") == "ssh: connect to host web1 port 22: Connection refused")
}

extension SudoPasswordTests {

/// One ssh command looks (`.local()`: this Mac's sh), with stand-ins first in PATH: systemd's JSON where it has it, the
/// table where `--output=json` is ignored (an old one); docker before podman, podman where there's no docker.
@Test func servicesAndContainersAreReadWithTheServersTools() throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-services-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    func fake(_ name: String, _ body: String) throws {
        try Data(("#!/bin/sh\n" + body).utf8).write(to: URL(fileURLWithPath: d + "/" + name))
        chmod(d + "/" + name, 0o755)
    }
    let env = ["PATH": d + ":/usr/bin:/bin"]
    try fake("systemctl", """
        [ "$*" = "list-units --type=service --all --output=json --no-pager" ] || { echo "wrong: $*" >&2; exit 9; }
        cat <<'END'
        \(unitsJSON)
        END
        """)
    #expect(try Services.read(on: .local(), server: "web1", env: env).map(\.name) == ["backup", "Alpha", "cron", "getty@tty1", "web"])
    try fake("systemctl", """
        case "$*" in
        *--plain*) [ "$*" = "list-units --type=service --all --plain --no-legend --no-pager" ] || exit 9; cat <<'END'
        \(unitsPlain)
        END
        ;;
        *) echo "UNIT LOAD ACTIVE SUB DESCRIPTION"; echo "web.service loaded active running Web server" ;;
        esac
        """)
    #expect(try Services.read(on: .local(), server: "web1", env: env).map(\.name) == ["backup", "db", "web"], "an old systemd: the table")

    try fake("podman", """
        [ "$*" = "ps -a --format {{.Names}}\\t{{.Status}}\\t{{.Image}}" ] || { echo "wrong: $*" >&2; exit 9; }
        printf 'web\\tUp 3 hours\\tnginx:1\\n'
        """)
    var r = try Containers.read(on: .local(), server: "web1", env: env)
    #expect(r.tool == "podman" && r.containers == [ContainerInfo(name: "web", state: "running", status: "Up 3 hours", image: "nginx:1")])
    try fake("docker", "echo 'permission denied while trying to connect to the Docker daemon socket' >&2; exit 1\n")
    let e = try #require(throws: SFTPError.self) { try Containers.read(on: .local(), server: "web1", env: env) }
    #expect(e.message == "docker failed on web1: permission denied while trying to connect to the Docker daemon socket")
    try fake("docker", "printf 'db\\tExited (1) 1 hour ago\\tpostgres:16\\n'\n")
    r = try Containers.read(on: .local(), server: "web1", env: env)
    #expect(r.tool == "docker" && r.containers.map(\.name) == ["db"])
}

/// A follow ends with ssh: once the stdin ssh held is closed there (what sshd does when ssh goes), the command is
/// stopped; one that ends by itself ends the run at once, with nothing left behind waiting on stdin.
@Test(.timeLimit(.minutes(1))) func aFollowEndsWithSSH() async throws {
    let d = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/dfm-follow-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: d) }
    func start(_ command: String) throws -> (Process, Pipe) {
        let p = Process(), input = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")   // a session of its own: only the pipe reaches it, as over ssh
        p.arguments = ["-MPOSIX", "-e", "POSIX::setsid(); exec @ARGV", "/bin/sh", "-c", SSHCommand.endsWithSSH(command)]
        (p.standardInput, p.standardOutput, p.standardError) = (input, FileHandle.nullDevice, FileHandle.nullDevice)
        try p.run()
        return (p, input)
    }
    func pid() async throws -> Int32 {
        for _ in 0..<50 {
            if let n = Int32(String(decoding: FileManager.default.contents(atPath: d + "/pid") ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)) { return n }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }
    let (_, input) = try start("sh -c 'echo $$ > \(d)/pid; exec sleep 30'")
    let quiet = try await pid()
    try await Task.sleep(for: .milliseconds(300))
    #expect(kill(quiet, 0) == 0, "it runs while ssh does")
    try input.fileHandleForWriting.close()   // ssh gone
    var gone = false
    for _ in 0..<50 where !gone {
        gone = kill(quiet, 0) != 0
        if !gone { try await Task.sleep(for: .milliseconds(100)) }
    }
    #expect(gone, "sleep \(quiet) still runs")
    if !gone { kill(quiet, SIGKILL) }

    let started = Date()
    let (p, held) = try start("sh -c 'echo done; exit 3'")
    while p.isRunning, Date().timeIntervalSince(started) < 5 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!p.isRunning && p.terminationStatus == 3, "its own status, at once, though stdin is still open")
    try held.fileHandleForWriting.close()
}
}
