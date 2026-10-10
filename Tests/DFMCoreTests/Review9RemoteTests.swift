import Foundation
import Testing
@testable import DFMCore

/// S1: the saved password answers the target's own prompt only — never a ProxyJump bastion's, never anything else.
/// The askpass script's real first line, with synthetic prompts; no server.
@Test func savedPasswordAnswersOnlyTheTargetsPrompt() {
    func askpass(_ prompt: String, _ env: [String: String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", SFTP.askpassSavedPassword + "\nexit 3", "askpass", prompt]   // exit 3: where the dialog would ask
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return "no sh" }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    // withSecret: what withPassword runs with promptLogin's answer (SFTP.password is a global other tests set).
    SFTP.withSecret("s3cr et", for: "me@203.0.113.9") { env in
        #expect(env["DFM_ASKPASS_FOR"] == "me@203.0.113.9")
        for wrong in ["me@bastion.example's password: ", "(me@bastion.example) Password:", "root@203.0.113.9's password: ",
                      "me@203.0.113.99's password: ", "x me@203.0.113.9's password: ", "(me@203.0.113.9) Verification code:",
                      "Enter passphrase for key '/Users/me/.ssh/id_ed25519': ", "Password:"] {
            #expect(askpass(wrong, env) == "", "\(wrong)")
        }
        #expect(askpass("me@203.0.113.9's password: ", env) == "s3cr et", "the bastion's prompts left it for the target")
    }
    SFTP.withSecret("s3cr et", for: "me@203.0.113.9") { env in
        #expect(askpass("(me@203.0.113.9) Password:", env) == "s3cr et", "keyboard-interactive")
    }
    // No expected login in the environment: nothing served.
    SFTP.withSecret("s3cr et", for: "me@203.0.113.9") { env in
        #expect(askpass("'s password: ", env.filter { $0.key != "DFM_ASKPASS_FOR" }) == "")
    }
}

@Test func promptLoginIsWhatSshPrints() {
    #expect(SFTP.promptLogin(sshG: "user Me\nhostname 10.0.0.5\nport 22\n") == "Me@10.0.0.5")
    #expect(SFTP.promptLogin(sshG: "user me\nhostname 10.0.0.5\nhostkeyalias nas\n") == "me@nas", "ssh names HostKeyAlias")
    #expect(SFTP.promptLogin(sshG: "port 22\n") == nil)
    #expect(SFTP.promptLogin(SFTPTarget(host: "me@203.0.113.9", port: 2222)) == "me@203.0.113.9")
}
