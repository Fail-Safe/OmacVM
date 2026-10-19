import Foundation

/// SSH access to an app VM, repaired through the guest agent (VMKey in the
/// app does the work; the rules are here, for window-tests).
///
/// OmacVM reaches an app VM over SSH with its folder's own key (ssh-key,
/// ssh-key.pub; app_ssh_key in src/lib/app.sh). A VM set up on another Mac,
/// or before 3.0.12, may know only that Mac's key. The app then adds the
/// folder's key to root's authorized_keys through the guest agent: at each
/// window start, and in Update VM when SSH turns the key down.
public enum SSHRepair {
    /// Run in the VM as `/bin/sh -c script omacvm-key KEY` (`command`): the
    /// key is $1, never part of this text. It checks the key again (one line,
    /// the characters of a key, 200 bytes at most), writes root's file only,
    /// and restarts sshd only when the key was just added: that also clears
    /// sshd's PerSourcePenalties for the Mac's earlier tries. try-restart
    /// keeps open sessions (KillMode=process). Prints added or present.
    public static let script = """
    k=$1
    [ ${#k} -le 200 ] || { echo bad; exit 2; }
    case $k in "ssh-ed25519 "*) ;; *) echo bad; exit 2 ;; esac
    [ "$(printf '%s' "$k" | tr -d 'A-Za-z0-9+/=._@ -'; echo .)" = . ] || { echo bad; exit 2; }
    f=/root/.ssh/authorized_keys
    if [ -f "$f" ] && grep -qxF -- "$k" "$f"; then echo present; exit 0; fi
    install -d -m 700 /root/.ssh || exit 1
    if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then echo >> "$f"; fi
    printf '%s\\n' "$k" >> "$f" || exit 1
    chmod 600 "$f" || exit 1
    systemctl try-restart sshd >/dev/null 2>&1 || true
    echo added
    """

    /// The guest-exec call: the program and its arguments, no shell around them.
    public static func command(key: String) -> (path: String, args: [String]) {
        ("/bin/sh", ["-c", script, "omacvm-key", key])
    }

    /// The folder's ssh-key.pub as one key line, nil when it is not one.
    public static func keyLine(pub data: Data) -> String? {
        guard data.count <= 201, var line = String(data: data, encoding: .utf8) else { return nil }
        if line.hasSuffix("\n") { line.removeLast() }
        return valid(line) ? line : nil
    }

    /// One line: "ssh-ed25519 ", base64, an optional plain comment; 200 bytes at most.
    public static func valid(_ line: String) -> Bool {
        line.utf8.count <= 200 && line.hasPrefix("ssh-ed25519 ") && line.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=._@ -")

    /// The command for the VM's terminal when the app could not add the key
    /// (Copy Command): src/lib/vm.sh's ssh_setup_command for app VMs, with
    /// the folder's key. Built here from the folder's .pub, never taken from
    /// the update's output (a guest could fake that).
    public static func manualCommand(key: String) -> String? {
        guard valid(key) else { return nil }
        return "sudo bash -c 'install -d -m700 /root/.ssh && echo \"\(key)\" >> /root/.ssh/authorized_keys && "
            + "{ pacman -Q openssh >/dev/null 2>&1 || pacman -S --noconfirm openssh >/dev/null; } && "
            + "systemctl enable sshd && systemctl restart sshd && "
            + "{ ufw allow from 10.0.2.0/24 to any port 22 proto tcp comment \"omacvm: ssh from the Mac\" || true; }'"
    }

    /// The (i) beside Copy Command.
    public static let info = "OmacVM reaches the VM over SSH with a key kept in the VM's folder. A VM set up on another Mac, "
        + "or before OmacVM 3.0.12, may only know that Mac's key. OmacVM normally adds the folder's key itself when the VM "
        + "starts. This command does the same by hand: it adds that one public key for root and keeps SSH on, reachable "
        + "from this Mac only. It changes no passwords and removes no keys. It asks for your password because it uses sudo."

    /// What the repair found.
    public enum Result: Equatable {
        case added, present, noAgent
        case failed(String)
    }

    /// The answer to update-vm.sh's "FIX ssh-key" (one word on its fd 3).
    public static func answer(_ r: Result) -> String {
        switch r {
        case .added: return "added"
        case .present: return "present"
        case .noAgent: return "noagent"
        case .failed: return "failed"
        }
    }

    /// qemu.log's line after a window start's repair: only when the key was
    /// added or could not be. No agent is said only while the VM still runs
    /// (a VM shut down during the wait has nothing to say).
    public static func logLine(_ r: Result, stillRunning: Bool) -> String? {
        switch r {
        case .added: return "OmacVM: SSH: this VM folder's key added in the VM (it only knew another Mac's key)"
        case .present: return nil
        case .noAgent: return stillRunning ? "OmacVM: SSH: the VM's guest agent did not answer: this VM folder's key was not checked" : nil
        case .failed(let why): return "OmacVM: SSH: could not add this VM folder's key in the VM: \(why)"
        }
    }

    /// update-vm.sh's own lines for the repair. Only the script prints them,
    /// in its first step: SSH is not up then, so nothing of the guest reaches
    /// its output. Later steps pass the guest's lines through (run_logged), so
    /// they count only in step 1 of an update, each once per run.
    public struct Lines {
        public enum Event: Equatable { case fix, refused }
        private var fixed = false, refused = false

        public init() {}

        public mutating func take(_ line: String, update: Bool, step: Int) -> Event? {
            guard update, step == 1 else { return nil }
            if line == "FIX ssh-key", !fixed { fixed = true; return .fix }
            if line == "SSHKEY refused", !refused { refused = true; return .refused }
            return nil
        }
    }
}
