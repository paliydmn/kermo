import Testing
@testable import DFMCore

// Task 13 (В7): Touch ID for sudo, on copies of macOS's sudo_local.template — never the real /etc/pam.d.

private let template = "# sudo_local: local config file which survives system update and is included for sudo\n"
    + "# uncomment following line to enable Touch ID for sudo\n#auth       sufficient     pam_tid.so\n"

/// On: an `auth … pam_tid.so` line not commented out, however it's spaced; no file is a state of its own.
@Test func sudoLocalSaysWhetherTouchIDIsOn() {
    #expect(SudoTouchID.state(nil) == .noFile)
    #expect(SudoTouchID.state(template) == .off)
    #expect(SudoTouchID.state("") == .off)
    #expect(SudoTouchID.state("auth sufficient pam_tid.so") == .on)
    #expect(SudoTouchID.state("# x\n\tauth\tsufficient\tpam_tid.so\n") == .on)
    #expect(SudoTouchID.state("auth       sufficient     /usr/lib/pam/pam_tid.so.2\n") == .on)
    #expect(SudoTouchID.state("  # auth sufficient pam_tid.so\n") == .off)
    #expect(SudoTouchID.state("account sufficient pam_tid.so\nauth optional pam_reattach.so\n") == .off)
}

/// From the template: its pam_tid line uncommented, the rest as it was.
@Test func touchIDOnFromTheTemplate() {
    let on = SudoTouchID.enabled(nil, template: template)
    #expect(on == "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "# uncomment following line to enable Touch ID for sudo\nauth       sufficient     pam_tid.so\n")
    #expect(SudoTouchID.state(on) == .on)
}

/// A sudo_local of one's own keeps its lines: pam_tid goes after them (pam_reattach must come first), or its own
/// commented line is uncommented where it is.
@Test func touchIDOnKeepsWhatSudoLocalHad() {
    let reattach = "auth       optional       /opt/homebrew/lib/pam/pam_reattach.so\n"
    #expect(SudoTouchID.enabled(reattach, template: template) == reattach + "auth       sufficient     pam_tid.so\n")
    #expect(SudoTouchID.enabled("auth optional pam_reattach.so", template: template) == "auth optional pam_reattach.so\nauth       sufficient     pam_tid.so\n",
            "no newline at the end")
    #expect(SudoTouchID.enabled("# mine\n# auth sufficient pam_tid.so\n", template: template) == "# mine\nauth sufficient pam_tid.so\n")
    #expect(SudoTouchID.enabled(template + reattach, template: template) == "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "# uncomment following line to enable Touch ID for sudo\n" + reattach + "auth       sufficient     pam_tid.so\n", "reattach added below the template's line: after it")
}

/// The one write: the text itself into /etc/pam.d/sudo_local (no temp file to swap meanwhile), never through a symlink,
/// 0644 if new; quoted, whatever the text holds.
@Test func touchIDWritesSudoLocalOnly() {
    #expect(SudoTouchID.command(writing: "auth x\n") == "umask 022 && [ ! -L /etc/pam.d/sudo_local ] && /usr/bin/printf '%s' 'auth x\n' > /etc/pam.d/sudo_local")
    #expect(SudoTouchID.command(writing: "it's $(x) %s\n").contains(#"'it'\''s $(x) %s"#))
}
