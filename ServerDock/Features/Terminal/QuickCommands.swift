// Handwritten common-command menu; every command is a read-only query.
import Foundation

/// Run title directly without variants, otherwise show option variants in a submenu.
struct QuickCommandItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    var variants: [QuickCommandVariant] = []
}

struct QuickCommandVariant: Identifiable {
    let id = UUID()
    let command: String
    let detail: String
}

struct QuickCommandGroup: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let items: [QuickCommandItem]
}

enum QuickCommands {
    static let groups: [QuickCommandGroup] = [
        QuickCommandGroup(title: String(localized: "Files & Folders"), symbol: "folder", items: [
            QuickCommandItem(title: "ls — List", detail: "", variants: [
                QuickCommandVariant(command: "ls -l", detail: String(localized: "Detailed list")),
                QuickCommandVariant(command: "ls -alh", detail: String(localized: "Include hidden files, readable sizes")),
                QuickCommandVariant(command: "ls -lht", detail: String(localized: "Newest first")),
                QuickCommandVariant(command: "ls -lhS", detail: String(localized: "Largest first")),
                QuickCommandVariant(command: "ls -ld */", detail: String(localized: "Folders only")),
                QuickCommandVariant(command: "ls -lR | head -50", detail: String(localized: "Recursive (first 50 lines)")),
            ]),
            QuickCommandItem(title: "pwd", detail: String(localized: "Print current folder")),
            QuickCommandItem(title: "find — Search", detail: "", variants: [
                QuickCommandVariant(command: "find . -name \"*.log\"", detail: String(localized: "Files named *.log here")),
                QuickCommandVariant(command: "find . -type f -mtime -1", detail: String(localized: "Files changed in the last day")),
                QuickCommandVariant(command: "find . -type f -size +100M", detail: String(localized: "Files over 100 MB")),
                QuickCommandVariant(command: "find . -type d -empty", detail: String(localized: "Empty folders")),
            ]),
        ]),
        QuickCommandGroup(title: String(localized: "Disk Usage"), symbol: "internaldrive", items: [
            QuickCommandItem(title: "df — Free space", detail: "", variants: [
                QuickCommandVariant(command: "df -h", detail: String(localized: "Readable sizes")),
                QuickCommandVariant(command: "df -hT", detail: String(localized: "With filesystem type")),
                QuickCommandVariant(command: "df -i", detail: String(localized: "Inode usage")),
                QuickCommandVariant(command: "df -h /", detail: String(localized: "Root partition only")),
            ]),
            QuickCommandItem(title: "du — Folder size", detail: "", variants: [
                QuickCommandVariant(command: "du -sh *", detail: String(localized: "Size of each item here")),
                QuickCommandVariant(command: "du -sh .", detail: String(localized: "Total size of this folder")),
                QuickCommandVariant(command: "du -h -d 1 . | sort -h", detail: String(localized: "Sub-folders by size")),
                QuickCommandVariant(command: "du -ah . | sort -rh | head -20", detail: String(localized: "Top 20 largest files/folders")),
            ]),
            QuickCommandItem(title: "lsblk", detail: String(localized: "Block devices and mounts")),
            QuickCommandItem(title: "mount | column -t", detail: String(localized: "Mounted filesystems")),
        ]),
        QuickCommandGroup(title: String(localized: "System"), symbol: "cpu", items: [
            QuickCommandItem(title: "uptime", detail: String(localized: "Uptime and load average")),
            QuickCommandItem(title: "free — Memory", detail: "", variants: [
                QuickCommandVariant(command: "free -h", detail: String(localized: "Readable sizes")),
                QuickCommandVariant(command: "free -m", detail: String(localized: "In megabytes")),
                QuickCommandVariant(command: "free -h -s 2", detail: String(localized: "Refresh every 2 seconds")),
            ]),
            QuickCommandItem(title: "top / ps — Processes", detail: "", variants: [
                QuickCommandVariant(command: "top", detail: String(localized: "Live process viewer")),
                QuickCommandVariant(command: "top -bn1 | head -20", detail: String(localized: "Snapshot (top 20 lines)")),
                QuickCommandVariant(command: "ps aux --sort=-%cpu | head -15", detail: String(localized: "Top CPU processes")),
                QuickCommandVariant(command: "ps aux --sort=-%mem | head -15", detail: String(localized: "Top memory processes")),
                QuickCommandVariant(command: "ps -ef", detail: String(localized: "All processes (full format)")),
            ]),
            QuickCommandItem(title: "vmstat 1 5", detail: String(localized: "Virtual memory stats (5 samples)")),
            QuickCommandItem(title: "uname -a", detail: String(localized: "Kernel and system info")),
            QuickCommandItem(title: "cat /etc/os-release", detail: String(localized: "OS distribution")),
            QuickCommandItem(title: "lscpu", detail: String(localized: "CPU details")),
            QuickCommandItem(title: "who — Users", detail: "", variants: [
                QuickCommandVariant(command: "who", detail: String(localized: "Logged-in users")),
                QuickCommandVariant(command: "w", detail: String(localized: "Users and what they run")),
                QuickCommandVariant(command: "last -n 20", detail: String(localized: "Recent logins")),
            ]),
        ]),
        QuickCommandGroup(title: String(localized: "Network"), symbol: "network", items: [
            QuickCommandItem(title: "ip — Addresses", detail: "", variants: [
                QuickCommandVariant(command: "ip -br a", detail: String(localized: "Interfaces (brief)")),
                QuickCommandVariant(command: "ip a", detail: String(localized: "Interfaces (detailed)")),
                QuickCommandVariant(command: "ip route", detail: String(localized: "Routing table")),
            ]),
            QuickCommandItem(title: "ss — Sockets", detail: "", variants: [
                QuickCommandVariant(command: "ss -tulnp", detail: String(localized: "Listening ports with process")),
                QuickCommandVariant(command: "ss -s", detail: String(localized: "Socket summary")),
                QuickCommandVariant(command: "ss -tn state established", detail: String(localized: "Established connections")),
            ]),
            QuickCommandItem(title: "ping -c 4 8.8.8.8", detail: String(localized: "Ping test (4 packets)")),
            QuickCommandItem(title: "curl -s ifconfig.me", detail: String(localized: "Public IP address")),
            QuickCommandItem(title: "cat /etc/resolv.conf", detail: String(localized: "DNS servers")),
            QuickCommandItem(title: "hostname -I", detail: String(localized: "Host IP addresses")),
        ]),
        QuickCommandGroup(title: String(localized: "Services & Logs"), symbol: "gearshape.2", items: [
            QuickCommandItem(title: "systemctl — Services", detail: "", variants: [
                QuickCommandVariant(command: "systemctl list-units --type=service --state=running", detail: String(localized: "Running services")),
                QuickCommandVariant(command: "systemctl --failed", detail: String(localized: "Failed units")),
                QuickCommandVariant(command: "systemctl list-unit-files --state=enabled", detail: String(localized: "Enabled at boot")),
            ]),
            QuickCommandItem(title: "journalctl — Logs", detail: "", variants: [
                QuickCommandVariant(command: "journalctl -n 100 --no-pager", detail: String(localized: "Last 100 entries")),
                QuickCommandVariant(command: "journalctl -p err -b --no-pager", detail: String(localized: "Errors since boot")),
                QuickCommandVariant(command: "journalctl -f", detail: String(localized: "Follow live")),
            ]),
            QuickCommandItem(title: "Log files", detail: "", variants: [
                QuickCommandVariant(command: "tail -n 100 /var/log/syslog", detail: String(localized: "syslog (Debian/Ubuntu)")),
                QuickCommandVariant(command: "tail -n 100 /var/log/messages", detail: String(localized: "messages (RHEL/CentOS)")),
                QuickCommandVariant(command: "tail -n 100 /var/log/auth.log", detail: String(localized: "Auth log")),
                QuickCommandVariant(command: "dmesg | tail -50", detail: String(localized: "Kernel messages")),
            ]),
        ]),
        QuickCommandGroup(title: String(localized: "Docker"), symbol: "shippingbox", items: [
            QuickCommandItem(title: "docker ps — Containers", detail: "", variants: [
                QuickCommandVariant(command: "docker ps", detail: String(localized: "Running containers")),
                QuickCommandVariant(command: "docker ps -a", detail: String(localized: "All containers")),
                QuickCommandVariant(command: "docker stats --no-stream", detail: String(localized: "Resource usage")),
            ]),
            QuickCommandItem(title: "docker images", detail: String(localized: "Images")),
            QuickCommandItem(title: "docker system df", detail: String(localized: "Docker disk usage")),
            QuickCommandItem(title: "docker compose ps", detail: String(localized: "Compose services")),
        ]),
        QuickCommandGroup(title: String(localized: "Git"), symbol: "arrow.triangle.branch", items: [
            QuickCommandItem(title: "git status -sb", detail: String(localized: "Short status with branch")),
            QuickCommandItem(title: "git log --oneline -20", detail: String(localized: "Last 20 commits")),
            QuickCommandItem(title: "git log --graph --oneline --all -20", detail: String(localized: "Branch graph")),
            QuickCommandItem(title: "git branch -a", detail: String(localized: "All branches")),
            QuickCommandItem(title: "git diff --stat", detail: String(localized: "Changed files summary")),
        ]),
    ]
}
