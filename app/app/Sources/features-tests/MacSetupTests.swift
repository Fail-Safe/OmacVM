import Foundation
import OmacVMFeatures

/// Is this Mac set up for a VM (MacSetup): the lines of `src/mac/install.sh
/// --status` (src/tests/mac-setup.sh checks the script), read and worded for
/// the alert before a start and the window's notice.
func macSetupTests() {
    // A VM folder copied from another Mac (the M1 Max, 2026-10-20): nothing installed.
    let copied = MacSetup.parse("""
        verdict\tsetup
        fix\tupdate-vm
        why\tother-mac
        helpers\tOmacVM Bridge|OmacVM Gestures
        needed\tOmacVM Bridge|OmacVM Gestures
        missing\t
        version\t3.1.28
        vm-version\t3.1.27
        text\tset up on another Mac: OmacVM Bridge, OmacVM Gestures not set up for this Mac
        helper\tOmacVM Bridge\tmissing\tnot installed
        helper\tOmacVM Gestures\tmissing\tnot installed

        """)
    expect(copied?.verdict == .setup && copied?.fix == .updateVM && copied?.why == "other-mac", "mac setup: parsed")
    expect(copied?.helpers == ["OmacVM Gestures", "OmacVM Bridge"] && copied?.lines.count == 2
           && copied?.lines[0] == MacSetup.Helper(name: "OmacVM Gestures", state: "missing", detail: "not installed"), "mac setup: helpers and lines, Gestures first")
    expect(copied?.needsAction == true && copied?.wantsUpdateVM == true, "mac setup: copied VM: Update VM")
    expect(copied?.title(vm: "Omarchy") == "Omarchy was set up on another Mac", "mac setup: title names the cause")
    let m = copied?.message(vm: "Omarchy") ?? ""
    expect(m.contains("OmacVM Gestures and OmacVM Bridge aren't set up for it on this Mac yet")
           && m.contains("Update VM sets them up") && m.contains("then starts it as usual"), "mac setup: message says what Update VM does: \(m)")
    expect(m.contains("OmacVM Bridge (Accessibility, Input Monitoring, Location Services and Bluetooth)")
           && m.contains("OmacVM Gestures (Accessibility and Input Monitoring)"), "mac setup: every prompt macOS shows is named")
    expect(m.contains("trackpad gestures, scroll momentum and ⌃⌥ Esc") && m.contains("Wi-Fi"), "mac setup: what does nothing")
    expect(copied?.button == "Update VM" && copied?.settingsURL == nil, "mac setup: Update VM button")
    expect(copied?.notice(vm: "Omarchy").hasPrefix("Omarchy was set up on another Mac: ") == true
           && copied?.notice(vm: "Omarchy").hasSuffix(": trackpad gestures and the Mac's Wi-Fi, sound and keys in the bar do nothing until Update VM sets up OmacVM Gestures and OmacVM Bridge.") == true,
           "mac setup: the window's notice: \(copied?.notice(vm: "Omarchy") ?? "")")
    expect(copied?.info(vm: "Omarchy").contains("• OmacVM Gestures (trackpad gestures, scroll momentum and ⌃⌥ Esc): not installed") == true
           && copied?.info(vm: "Omarchy").contains("Copied from another Mac? Update VM once sets it up here") == true, "mac setup: the (i)")
    expect(copied?.record == "setup other-mac (OmacVM Gestures, OmacVM Bridge), fix update-vm", "mac setup: the qemu.log record")

    // Helpers there, only the token another Mac's: no prompts named.
    let token = MacSetup.parse("verdict\tsetup\nfix\tupdate-vm\nwhy\tother-mac\nhelpers\tOmacVM Gestures\nneeded\tOmacVM Gestures\n"
        + "helper\tOmacVM Gestures\tok\trunning (pid 4)\n")
    expect(token?.message(vm: "V").contains("macOS then asks") == false, "mac setup: helpers installed already: no prompts named")
    expect(token?.title(vm: "V") == "V was set up on another Mac" && token?.message(vm: "V").contains("Update VM sets it up") == true,
           "mac setup: one helper: it")

    // Not installed (this Mac's token, helpers removed).
    let gone = MacSetup.parse("verdict\tsetup\nfix\tupdate-vm\nwhy\tnot-installed\nhelpers\tOmacVM Gestures\nhelper\tOmacVM Gestures\tmissing\tnot installed\n")
    expect(gone?.title(vm: "V") == "OmacVM Gestures isn't set up on this Mac", "mac setup: not installed title")
    expect(gone?.message(vm: "V").hasPrefix("Trackpad gestures, scroll momentum and ⌃⌥ Esc do nothing without it.") == true, "mac setup: not installed text")
    let stopped = MacSetup.parse("verdict\tsetup\nfix\tupdate-vm\nwhy\tnot-running\nhelpers\tOmacVM Bridge|OmacVM Gestures\n")
    expect(stopped?.title(vm: "V") == "OmacVM Gestures and OmacVM Bridge aren't running", "mac setup: not running (test identity)")

    // A VM from a newer OmacVM: the app first (Update VM would stop before the Mac side).
    let newer = MacSetup.parse("verdict\tsetup\nfix\tupdate-app\nwhy\tother-mac\nhelpers\tOmacVM Gestures\nversion\t3.1.28\nvm-version\t3.2.0\n")
    expect(newer?.wantsUpdateVM == false && newer?.button == "Check for Updates…", "mac setup: newer VM: Check for Updates")
    expect(newer?.title(vm: "V") == "V needs a newer OmacVM" && newer?.message(vm: "V").contains("OmacVM 3.2.0 from a newer app; this app is 3.1.28") == true,
           "mac setup: newer VM text")

    // Permissions: the right pane.
    let both = MacSetup.parse("verdict\tpermission\nfix\tsettings\nhelpers\tOmacVM Gestures\nmissing\tAccessibility, Input Monitoring\n")
    expect(both?.title(vm: "V") == "OmacVM Gestures isn't allowed yet" && both?.button == "Open System Settings", "mac setup: permission title")
    expect(both?.settingsURL == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", "mac setup: Accessibility pane")
    expect(both?.message(vm: "V").contains("no restart needed") == true, "mac setup: works without a restart")
    let im = MacSetup.parse("verdict\tpermission\nfix\tsettings\nhelpers\tOmacVM Gestures\nmissing\tInput Monitoring\n")
    expect(im?.settingsURL == "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent", "mac setup: only Input Monitoring: its pane")
    expect(im?.wantsUpdateVM == false, "mac setup: permissions are no Update VM")

    // Login Items.
    let li = MacSetup.parse("verdict\tlogin-items\nfix\tlogin-items\nhelpers\tOmacVM Bridge\n")
    expect(li?.title(vm: "V") == "OmacVM Bridge is turned off in Login Items" && li?.button == "Open Login Items"
           && li?.settingsURL == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension", "mac setup: Login Items")

    // Fine: nothing to say.
    let ok = MacSetup.parse("verdict\tok\nneeded\tOmacVM Bridge|OmacVM Gestures\n")
    expect(ok?.needsAction == false && ok?.notice(vm: "V") == "" && ok?.record == "ok (OmacVM Gestures, OmacVM Bridge)", "mac setup: ok")
    expect(MacSetup.parse("verdict\tnone\n")?.needsAction == false, "mac setup: nothing needed")
    expect(MacSetup.parse("") == nil && MacSetup.parse("verdict\tmaybe\n") == nil, "mac setup: no verdict: nil")

    // Later: quiet for the same problem and app version only.
    let k = copied?.laterKey(appVersion: "3.1.28")
    expect(k == "setup:update-vm:other-mac:OmacVM Gestures|OmacVM Bridge@3.1.28", "mac setup: Later's key")
    var stoppedToo = copied
    stoppedToo?.why = "not-running"
    expect(stoppedToo?.laterKey(appVersion: "3.1.28") != k, "mac setup: the same helpers for another cause ask again")
    expect(k != copied?.laterKey(appVersion: "3.1.29"), "mac setup: a new app version asks again")
    expect(k != gone?.laterKey(appVersion: "3.1.28") && both?.laterKey(appVersion: "3.1.28") != k, "mac setup: another problem asks again")

    expect(MacSetup.list(["A"]) == "A" && MacSetup.list(["A", "B"]) == "A and B" && MacSetup.list(["A", "B", "C"]) == "A, B and C", "mac setup: lists")
}
