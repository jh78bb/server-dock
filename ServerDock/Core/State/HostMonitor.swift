import Network
import SwiftUI

/// NWPathMonitor detects Wi-Fi/wired transitions and recovery immediately at system level,
/// restarting monitors without waiting roughly ten seconds for SSH keepalive timeout.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    /// Called only on real network changes with current online status.
    var onChange: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private var lastKey = ""

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // Use online status plus available interface names to deduplicate changes.
            let key = "\(online)|" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor in self?.apply(online: online, key: key) }
        }
        monitor.start(queue: DispatchQueue(label: "com.serverdock.netpath"))
    }

    private func apply(online: Bool, key: String) {
        guard key != lastKey else { return }
        let first = lastKey.isEmpty
        lastKey = key
        isOnline = online
        if !first { onChange?(online) }   // Skip the initial frame; trigger only on a real transition.
    }
}

/// Per-host live SSH sampling supports Linux/Android /proc and macOS tools.
/// Deploy no server files; stopping terminates remote sampling. Compute CPU/network deltas locally between samples.
@MainActor
final class HostMonitor: ObservableObject {
    /// stopped gives up after repeated failure until manual Retry or changed connection settings.
    enum Phase: Equatable { case connecting, live, unsupported, error, stopped, authenticationFailed }

    @Published private(set) var metrics: HostMetrics?
    @Published private(set) var phase: Phase = .connecting
    /// Latest connection/script-output/exit-code failure for UI/diagnostics; clear on successful samples.
    @Published private(set) var lastError: String?
    @Published private(set) var netHistory: [NetSample] = []   // Recent network-rate samples for the traffic chart.
    @Published private(set) var netTick = 0                    // Increment for every appended sample to shift the entire chart left one step.
    private static let netHistoryCap = 42                       // Match the chart window (visible+2) so no padding is needed once full.

    /// Notify the caller per parsed sample for threshold decisions; this monitor produces data, not alerts.
    var onSample: ((HostMetrics) -> Void)?
    /// Request refreshed credentials if password-based authentication is rejected.
    var onAuthenticationFailure: (() -> Void)?

    private var ssh: SSHConnection
    private var session: SSHSession?     // In-process libssh2 session, replacing a spawned /usr/bin/ssh process.
    private var localProcess: Process?   // Local hosts run the same sampling script directly on this Mac.
    private var launchGen = 0            // Increment on each launch to invalidate callbacks from older connections, replacing Process terminationHandler=nil.
    private var buffer = Data()
    private var running = false            // Whether monitoring is expected to run; determines reconnection after unexpected termination.
    private var restartWork: DispatchWorkItem?
    private var failures = 0               // Consecutive failures, used for reconnection backoff.
    private var scriptFailures = 0         // Consecutive connections that terminate before producing a sample; the remote sampling script cannot run.
    private var gaveUp = false             // Give-up state: start() no longer reconnects automatically, even though every overview appearance calls start().
    private var gotFrame = false           // Whether this launch has parsed any sample.
    private var strayOutput = ""           // Truncated non-sample output from this launch, usually remote shell/command errors.
    private static let maxAttempts = 3     // Stop retrying after this many consecutive failures.

    // Previous raw counters for delta calculations.
    private var prevCpu: [String: (idle: Double, total: Double)] = [:]   // Keys are cpu / cpu0 / cpu1, etc.
    private var prevRx: Double?
    private var prevTx: Double?
    private var prevUptime: Double?
    private var prevIowait: Double?
    private var prevCpuTotal: Double?
    private var prevIO: (rs: Double, ws: Double, rio: Double, wio: Double)?
    private var prevIF: [String: (rx: Double, tx: Double)] = [:]

    // Sampling interval matches remote sleep; prefer uptime differences over this network-rate delta-time fallback.
    private static let interval = 2

    /// Frame interval in seconds synchronizes chart-scroll animation with sampling.
    var sampleInterval: Double { Double(Self.interval) }

    /// Remote script uses Linux/Android /proc or macOS sysctl/vm_stat/top/netstat.
    /// Output total/per-core CPU counters. Exclude loopback lo and replace interface-name colons with spaces
    /// before parsing counters to prevent high-traffic byte counts adjoining colons. List only /dev-backed mounts.
    /// Emit one pipe-delimited GPU row for nvidia-smi, preserving spaced model names; memory kB, disk 1K blocks, VRAM MiB.
    private static let script = """
    OS=$(uname -s 2>/dev/null || echo unknown)
    if [ "$OS" = Darwin ]; then
      PAGESIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
      MEMTOTAL=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))
      BOOT=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[ =,}]+' '{for(i=1;i<=NF;i++)if($i=="sec"){print $(i+1); exit}}')
      command -v nvidia-smi >/dev/null 2>&1 && HASGPU=1 || HASGPU=0
      while :; do
        top -l 1 -n 0 2>/dev/null | awk '/^CPU usage:/{gsub(/%/,"",$3); gsub(/%/,"",$5); print "CPU_PCT " ($3+$5); exit}'
        FREEP=$(vm_stat 2>/dev/null | awk '/Pages free:|Pages inactive:|Pages speculative:/{gsub(/\\./,"",$3); p+=$3} END{print p+0}')
        echo "MEM MemTotal $MEMTOTAL"
        echo "MEM MemAvailable $(( FREEP * PAGESIZE / 1024 ))"
        netstat -ibn 2>/dev/null | awk '$1 !~ /^lo/ && $3 ~ /^<Link#/ && $7 ~ /^[0-9]+$/ && $10 ~ /^[0-9]+$/ {r+=$7; t+=$10} END{print "NET " r " " t}'
        NOW=$(date +%s 2>/dev/null || echo 0)
        echo "UP $(( NOW - ${BOOT:-NOW} ))"
        sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print "LOAD " $1 " " $2 " " $3}'
        # Exclude read-only volumes such as system snapshots.
        RO=$(mount 2>/dev/null | awk '/read-only/{s=$0; sub(/^.* on /,"",s); sub(/ \\(.*$/,"",s); print s}' | tr '\\n' '|')
        df -kP 2>/dev/null | awk -v ro="$RO" 'BEGIN{n=split(ro,a,"|"); for(i=1;i<=n;i++) r[a[i]]=1} NR>1 && index($1,"/dev/")==1 && !($6 in r){print "DISK "$6" "$3" "$2}'
        [ "$HASGPU" = 1 ] && nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | awk -F", *" '{print "GPU "$1"|"$2"|"$3"|"$4"|"$5"|"$6}'
        echo "==="
        sleep __INTERVAL__
      done
    fi
    # Android/Termux can restrict /proc/stat for app UIDs even when other system
    # counters remain readable. Use its standard utilities and sysfs counters as a fallback.
    if [ ! -r /proc/stat ]; then
      while :; do
        top -b -n 1 2>/dev/null | awk '/^(CPU|CPU usage):/{for(i=1;i<=NF;i++){x=tolower($i); if(x ~ /%/ && x !~ /idle/){v=$i; sub(/[^0-9.].*/,"",v); if(v ~ /^[0-9.]+$/) s+=v}} print "CPU_PCT " s; exit}'
        if [ -r /proc/meminfo ]; then
          awk '/^(MemTotal|MemAvailable):/{gsub(/:/,"",$1); print "MEM "$1" "$2}' /proc/meminfo
        else
          free -k 2>/dev/null | awk '$1=="Mem:"{print "MEM MemTotal "$2; print "MEM MemAvailable "$NF; exit}'
        fi
        RX=0; TX=0
        for n in /sys/class/net/*; do
          [ -r "$n/statistics/rx_bytes" ] && [ -r "$n/statistics/tx_bytes" ] || continue
          case "${n##*/}" in lo) continue;; esac
          r=$(cat "$n/statistics/rx_bytes" 2>/dev/null); t=$(cat "$n/statistics/tx_bytes" 2>/dev/null)
          case "$r" in ''|*[!0-9]*) continue;; esac
          case "$t" in ''|*[!0-9]*) continue;; esac
          RX=$(( RX + r )); TX=$(( TX + t ))
        done
        echo "NET $RX $TX"
        [ -r /proc/uptime ] && echo "UP $(cut -d' ' -f1 /proc/uptime)" || echo "UP 0"
        [ -r /proc/loadavg ] && echo "LOAD $(cut -d' ' -f1-3 /proc/loadavg)" || echo "LOAD 0 0 0"
        df -kP 2>/dev/null | awk 'FILENAME=="/proc/mounts"{if($4 ~ /^rw(,|$)/)rw[$2]=1; n++; next} FNR>1 && (index($1,"/dev/")==1 || index($1,"/data")==1) && (n==0 || ($6 in rw)){print "DISK "$6" "$3" "$2}' /proc/mounts -
        echo "==="
        sleep __INTERVAL__
      done
    fi
    command -v nvidia-smi >/dev/null 2>&1 && HASGPU=1 || HASGPU=0
    while :; do
      awk '/^cpu[0-9]* /{print "CPU "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9}' /proc/stat
      awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/{gsub(/:/,"",$1); print "MEM "$1" "$2}' /proc/meminfo
      awk 'NR>2{sub(/:/," "); if($1!="lo" && NF>=10){r+=$2; t+=$10}} END{print "NET "r" "t}' /proc/net/dev
      echo "UP $(cut -d" " -f1 /proc/uptime)"
      echo "LOAD $(cut -d" " -f1-3 /proc/loadavg)"
      df -kP 2>/dev/null | awk 'FILENAME=="/proc/mounts"{if($4 ~ /^rw(,|$)/)rw[$2]=1; n++; next} FNR>1 && index($1,"/dev/")==1 && (n==0 || ($6 in rw)){print "DISK "$6" "$3" "$2}' /proc/mounts -
      [ "$HASGPU" = 1 ] && nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | awk -F", *" '{print "GPU "$1"|"$2"|"$3"|"$4"|"$5"|"$6}'
      # CPU temperature (hwmon/thermal_zone), physical-disk cumulative I/O, and interface state/address/byte counters.
      t=""
      for z in /sys/class/hwmon/hwmon*; do n=$(cat "$z/name" 2>/dev/null); case "$n" in coretemp|k10temp|zenpower|cpu_thermal|cpu-thermal|soc_thermal) v=$(cat "$z/temp1_input" 2>/dev/null); if [ -n "$v" ]; then t=$v; break; fi;; esac; done
      if [ -z "$t" ]; then for z in /sys/class/thermal/thermal_zone*; do ty=$(cat "$z/type" 2>/dev/null); case "$ty" in x86_pkg_temp|cpu*|soc*|acpitz|k10temp) v=$(cat "$z/temp" 2>/dev/null); if [ -n "$v" ]; then t=$v; break; fi;; esac; done; fi
      [ -n "$t" ] && echo "TEMP $t"
      awk '$3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/ {rio+=$4; rs+=$6; wio+=$8; ws+=$10; f=1} END{if(f) print "IO " rs " " ws " " rio " " wio}' /proc/diskstats 2>/dev/null
      for n in /sys/class/net/*; do nm=${n##*/}; case "$nm" in lo|veth*|br-*|docker*|virbr*) continue;; esac; st=$(cat "$n/operstate" 2>/dev/null); sp=$(cat "$n/speed" 2>/dev/null); rx=$(cat "$n/statistics/rx_bytes" 2>/dev/null); tx=$(cat "$n/statistics/tx_bytes" 2>/dev/null); ad=$(ip -o -4 addr show dev "$nm" 2>/dev/null | awk '{print $4}' | tr '\\n' ','); echo "IF $nm|$st|$sp|$rx|$tx|$ad"; done
      echo "==="
      sleep __INTERVAL__
    done
    """

    /// Pass the original multiline sampling script directly to sh -c.
    /// Compressing if/while into one line risks invalid semicolons after then/do,
    /// so preserve newlines and use POSIX sh independently of the login shell.
    private static var remoteCommand: String {
        let body = script.replacingOccurrences(of: "__INTERVAL__", with: String(interval))
        return "sh -c '" + body.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    init(ssh: SSHConnection) {
        self.ssh = ssh
    }

    /// stop() normally cleans up. If released before stop(),
    /// cancel the thread-safe stream because the remote while/sleep loop never exits itself;
    /// otherwise worker thread, TCP connection, and remote process remain alive.
    deinit {
        session?.cancel()
        restartWork?.cancel()
    }

    /// Refresh current connection details after corrected ask-mode passwords replace cached invalid ones.
    /// Reconnect immediately when important settings change to avoid repeated failures with stale credentials.
    func updateConnection(_ s: SSHConnection) {
        let changed = s.password != ssh.password || s.host != ssh.host
            || s.port != ssh.port || s.user != ssh.user || s.keyId != ssh.keyId || s.keyPath != ssh.keyPath
            || s.authMethod != ssh.authMethod || s.agentSocket != ssh.agentSocket
        guard changed else { return }
        ssh = s
        failures = 0; scriptFailures = 0; lastError = nil
        gaveUp = false                     // Allow another attempt when connection settings change, such as the key/password.
        guard running else { return }
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        phase = .connecting
        launch()
    }

    func start() {
        guard !running, !gaveUp else { return }
        guard ssh.isLocal || !ssh.host.isEmpty else { phase = .unsupported; return }
        running = true
        failures = 0; scriptFailures = 0; lastError = nil
        phase = .connecting
        launch()
    }

    /// Manual Retry resets give-up state/failure count and reconnects.
    func retry() {
        gaveUp = false
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        running = false
        start()
    }

    func stop() {
        running = false
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        buffer.removeAll()
    }

    /// Discard/reconnect on network changes without waiting for keepalive timeout.
    /// launch handles offline state by retaining an error until network recovery.
    func handleNetworkChange() {
        guard running else { return }
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        phase = .connecting
        launch()
    }

    private func teardownProcess() {
        launchGen &+= 1        // Invalidate callbacks from the old stream, including ingestion and reconnection.
        session?.cancel()      // Interrupt the stream; its background thread closes it during cleanup.
        session = nil
        if let p = localProcess {
            p.terminationHandler = nil
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
            localProcess = nil
        }
    }

    /// Local hosts execute the same script through /bin/sh -c and stream stdout without SSH.
    private func launchLocal() {
        prevCpu.removeAll(); prevRx = nil; prevTx = nil; prevUptime = nil
        buffer.removeAll()
        gotFrame = false; strayOutput = ""
        launchGen &+= 1
        let gen = launchGen
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.remoteCommand]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in guard gen == self?.launchGen else { return }; self?.ingest(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = Int(proc.terminationStatus)
            Task { @MainActor in self?.streamEnded(gen: gen, end: .streamEnded(error: nil, exitCode: code)) }
        }
        do {
            try p.run()
            localProcess = p
        } catch {
            streamEnded(gen: gen, end: .connectFailed(error.localizedDescription))
        }
    }

    private func launch() {
        if ssh.isLocal { launchLocal(); return }
        // Do not retry offline; handleNetworkChange reconnects after recovery.
        guard NetworkMonitor.shared.isOnline else {
            phase = .error; lastError = String(localized: "Waiting for Network"); return
        }
        let cmd = Self.remoteCommand
        // Authentication arguments for a dedicated connection without master reuse; probe scripts retain accept-new behavior.
        let (password, keyPath, keyPass) = ssh.libssh2Auth
        let (h, p, u) = (ssh.host, ssh.port, ssh.user)
        let jump = ssh.jumpHost

        prevCpu.removeAll(); prevRx = nil; prevTx = nil; prevUptime = nil
        buffer.removeAll()
        gotFrame = false; strayOutput = ""
        launchGen &+= 1
        let gen = launchGen
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let session: SSHSession
            do {
                session = try SSHSession.connect(host: h, port: p, user: u,
                                                 password: password, keyPath: keyPath, keyPassphrase: keyPass, jump: jump)
            } catch {
                let msg = (error as? SSHSession.SSHError)?.message ?? error.localizedDescription
                Task { @MainActor in self?.streamEnded(gen: gen, end: .connectFailed(msg)) }   // Reconnect after a connection failure.
                return
            }
            Task { @MainActor in self?.adoptSession(session, gen: gen) }
            let result = session.execStream(cmd) { data in           // Block synchronously until cancel/EOF.
                Task { @MainActor in guard gen == self?.launchGen else { return }; self?.ingest(data) }
            }
            session.close()                                          // Close on this thread after the stream ends, avoiding a race.
            Task { @MainActor in self?.streamEnded(gen: gen, end: .streamEnded(error: result.error, exitCode: result.exitCode)) }
        }
    }

    /// Accept background-established sessions on main; cancel immediately if the launch was superseded/stopped.
    private func adoptSession(_ s: SSHSession, gen: Int) {
        if gen == launchGen { session = s } else { s.cancel() }
    }

    private enum StreamEnd {
        case connectFailed(String)
        case streamEnded(error: String?, exitCode: Int)
    }

    /// Handle stream EOF/error/setup failure only for the current generation; record causes and reconnect later unless explicitly stopped.
    /// Stop retrying repeated connections without frames, as restricted shells/network devices may not support the sampling script.
    private func streamEnded(gen: Int, end: StreamEnd) {
        guard gen == launchGen else { return }   // Ignore callbacks superseded by a newer launch.
        session = nil
        localProcess = nil
        guard running else { return }            // Do not reconnect after an explicit stop.
        // Unframed trailing output usually contains remote errors.
        if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) { appendStray(tail) }
        buffer.removeAll()

        let target = "\(ssh.user)@\(ssh.host):\(ssh.port)"
        let output = strayOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason: String
        switch end {
        case .connectFailed(let msg):
            reason = String(localized: "Connection failed: \(msg)")
        case .streamEnded(let error, let exitCode) where gotFrame:
            reason = String(localized: "Monitoring stream ended") + (error.map { ": \($0)" } ?? "")
                + (exitCode >= 0 ? " (exit \(exitCode))" : "")
            scriptFailures = 0
        case .streamEnded(let error, let exitCode):
            scriptFailures += 1
            var r = String(localized: "The monitoring script exited without producing data")
            if exitCode >= 0 { r += " (exit \(exitCode))" }
            if let error { r += ": \(error)" }
            r += output.isEmpty ? " — " + String(localized: "no output") : "\n" + output
            reason = r
        }
        lastError = reason
        failures = gotFrame ? 1 : failures + 1
        NSLog("[Monitor] %@ — %@ (failure %d)", target, reason, failures)

        // Background monitoring has no interactive SSH stdin. Stop on rejected credentials
        // instead of retrying with the same password and then reporting a misleading banner error.
        let authenticationFailed: Bool
        if case .connectFailed(let message) = end {
            authenticationFailed = message.localizedCaseInsensitiveContains("Authentication failed")
        } else {
            authenticationFailed = false
        }
        if authenticationFailed {
            running = false
            gaveUp = true
            phase = .authenticationFailed
            if ssh.authMethod == .ask { onAuthenticationFailure?() }
            return
        }

        if failures >= Self.maxAttempts {
            // Repeated auth/connection/script failures stop retries while preserving diagnostics until manual Retry.
            NSLog("[Monitor] %@ — giving up after %d failed attempts", target, failures)
            running = false
            gaveUp = true
            phase = scriptFailures >= Self.maxAttempts ? .unsupported : .stopped
            return
        }
        phase = .error
        scheduleRestart()
    }

    private func appendStray(_ text: String) {
        guard strayOutput.count < 800 else { return }
        strayOutput += text
        if strayOutput.count > 800 { strayOutput = String(strayOutput.prefix(800)) + "…" }
    }

    /// Unexpected disconnect backoff: 5 -> 10 -> 20 -> 40 -> maximum 60 seconds while the host remains open.
    private func scheduleRestart() {
        guard running, restartWork == nil else { return }
        let delay = min(60, 5 * pow(2, Double(max(0, failures - 1))))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork = nil
            if self.running { self.phase = .connecting; self.launch() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        // Parse frames delimited by "===\n", retaining incomplete tails until more input arrives.
        let delim = Data("===\n".utf8)
        while let r = buffer.range(of: delim) {
            let frame = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            if let text = String(data: frame, encoding: .utf8) { parse(text) }
        }
        // Long unframed output is not sampling data; move it into diagnostics instead of growing buffers indefinitely.
        if !gotFrame, buffer.count > 4096 {
            appendStray(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
    }

    private func parse(_ frame: String) {
        if frame.contains("UNSUPPORTED") {
            lastError = String(localized: "This host does not provide the system interfaces needed for real-time monitoring.")
            NSLog("[Monitor] %@@%@:%d — monitoring interfaces unavailable", ssh.user, ssh.host, ssh.port)
            gaveUp = true
            phase = .unsupported
            running = false            // Do not reconnect if the remote system has no /proc and the script has exited.
            return
        }

        var m = HostMetrics()
        var memAvail: Int64 = 0
        var swapFree: Int64 = 0
        var curCpu: [String: (idle: Double, total: Double)] = [:]
        var cores: [(idx: Int, pct: Double)] = []
        var curRx: Double?, curTx: Double?
        var recognized = false
        var curIowait: Double?, curCpuTotal: Double?
        var curIO: (rs: Double, ws: Double, rio: Double, wio: Double)?
        var ifaces: [NetInterface] = []

        for raw in frame.split(separator: "\n") {
            let p = raw.split(separator: " ").map(String.init)
            guard let key = p.first else { continue }
            if ["CPU", "CPU_PCT", "MEM", "NET", "UP", "LOAD", "DISK", "GPU", "TEMP", "IO", "IF"].contains(key) { recognized = true }
            else { appendStray(raw + "\n") }   // Retain non-data lines, including mixed-in stderr, for diagnostics.
            switch key {
            case "CPU":
                // CPU name user nice system idle iowait irq softirq steal; name is cpu for total or cpuN per core.
                guard p.count >= 6 else { break }
                let name = p[1]
                let v = p.dropFirst(2).compactMap { Double($0) }
                guard v.count >= 4 else { break }
                let total = v.reduce(0, +)
                let idle = v[3] + (v.count > 4 ? v[4] : 0)        // idle + iowait
                curCpu[name] = (idle, total)
                if name == "cpu", v.count > 4 { curIowait = v[4]; curCpuTotal = total }
                if let prev = prevCpu[name], total > prev.total {
                    let pct = max(0, min(100, (1 - (idle - prev.idle) / (total - prev.total)) * 100))
                    if name == "cpu" { m.cpuPercent = pct }
                    else if let n = Int(name.dropFirst(3)) { cores.append((n, pct)) }
                }
            case "TEMP":
                if p.count >= 2, let milli = Double(p[1]), milli > 0 { m.cpuTempC = milli / 1000 }
            case "IO":
                if p.count >= 5, let rs = Double(p[1]), let ws = Double(p[2]), let rio = Double(p[3]), let wio = Double(p[4]) { curIO = (rs, ws, rio, wio) }
            case "IF":
                // IF name|state|speed|rx|tx|IPv4-list uses pipes to avoid whitespace ambiguity.
                let f = raw.dropFirst(3).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if f.count >= 5, let rx = Double(f[3]), let tx = Double(f[4]) {
                    let sp = Int(f[2]).flatMap { $0 > 0 ? $0 : nil }
                    ifaces.append(NetInterface(name: f[0], state: f[1].isEmpty ? "unknown" : f[1], speedMbps: sp,
                                               addresses: f.count > 5 ? f[5].split(separator: ",").joined(separator: ", ") : "", rxTotal: rx, txTotal: tx))
                }
            case "CPU_PCT":
                if p.count >= 2, let pct = Double(p[1]) {
                    m.cpuPercent = max(0, min(100, pct))
                }
            case "MEM":
                if p.count >= 3, let kb = Int64(p[2]) {
                    switch p[1] {
                    case "MemTotal": m.memTotalKB = kb
                    case "MemAvailable": memAvail = kb
                    case "SwapTotal": m.swapTotalKB = kb
                    case "SwapFree": swapFree = kb
                    default: break
                    }
                }
            case "NET":
                if p.count >= 3, let rx = Double(p[1]), let tx = Double(p[2]) { curRx = rx; curTx = tx }
            case "UP":
                if p.count >= 2, let up = Double(p[1]) { m.uptimeSecs = up }
            case "LOAD":
                if p.count >= 4 {
                    m.load1 = Double(p[1]) ?? 0
                    m.load5 = Double(p[2]) ?? 0
                    m.load15 = Double(p[3]) ?? 0
                }
            case "DISK":
                // DISK mount usedKB totalKB: parse the last two numeric columns backward because mount paths may contain spaces.
                if p.count >= 4, let u = Int64(p[p.count - 2]), let t = Int64(p[p.count - 1]), t > 0 {
                    let mount = p[1..<(p.count - 2)].joined(separator: " ")
                    m.disks.append(DiskUsage(mount: mount, usedKB: u, totalKB: t))
                }
            case "GPU":
                // GPU i|name|util|memUsedMB|memTotalMB|temp: rejoin pipe fields to preserve spaced model names.
                let f = p.dropFirst().joined(separator: " ")
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if f.count >= 6, let idx = Int(f[0]) {
                    m.gpus.append(GPUInfo(
                        index: idx, name: f[1],
                        utilPercent: Double(f[2]) ?? 0,
                        memUsedMB: Int64(f[3]) ?? 0,
                        memTotalMB: Int64(f[4]) ?? 0,
                        tempC: Int(f[5]) ?? 0))
                }
            default:
                break
            }
        }

        guard recognized else { return }   // An all-error/non-data frame does not count as a successful sample.
        gotFrame = true
        failures = 0; scriptFailures = 0; lastError = nil

        m.memUsedKB = max(0, m.memTotalKB - memAvail)
        m.swapUsedKB = max(0, m.swapTotalKB - swapFree)
        m.perCore = cores.sorted { $0.idx < $1.idx }.map { $0.pct }
        m.gpus.sort { $0.index < $1.index }
        prevCpu = curCpu

        // Network bytes delta / elapsed time, preferring uptime delta to the configured sampling interval.
        let dt = (prevUptime.map { m.uptimeSecs - $0 }).flatMap { $0 > 0 ? $0 : nil } ?? Double(Self.interval)
        if let rx = curRx, let prx = prevRx, rx >= prx { m.netRxBytesPerSec = (rx - prx) / dt }
        if let tx = curTx, let ptx = prevTx, tx >= ptx { m.netTxBytesPerSec = (tx - ptx) / dt }
        prevRx = curRx; prevTx = curTx
        m.netRxTotal = curRx; m.netTxTotal = curTx
        // I/O wait, disk bytes/IOPS using 512-byte sectors, and per-interface rates.
        if let iow = curIowait, let tot = curCpuTotal, let piow = prevIowait, let ptot = prevCpuTotal, tot > ptot { m.iowaitPercent = max(0, min(100, (iow - piow) / (tot - ptot) * 100)) }
        prevIowait = curIowait; prevCpuTotal = curCpuTotal
        if let io = curIO, let pio = prevIO, io.rs >= pio.rs, io.ws >= pio.ws {
            m.diskReadBps = (io.rs - pio.rs) * 512 / dt; m.diskWriteBps = (io.ws - pio.ws) * 512 / dt
            m.diskReadIOPS = (io.rio - pio.rio) / dt; m.diskWriteIOPS = (io.wio - pio.wio) / dt
        }
        prevIO = curIO
        var newPrevIF: [String: (rx: Double, tx: Double)] = [:]
        for i in ifaces.indices {
            let n = ifaces[i]
            if let pv = prevIF[n.name], n.rxTotal >= pv.rx, n.txTotal >= pv.tx { ifaces[i].rxRate = (n.rxTotal - pv.rx) / dt; ifaces[i].txRate = (n.txTotal - pv.tx) / dt }
            newPrevIF[n.name] = (n.rxTotal, n.txTotal)
        }
        prevIF = newPrevIF
        m.interfaces = ifaces
        prevUptime = m.uptimeSecs

        if let rx = m.netRxBytesPerSec, let tx = m.netTxBytesPerSec {
            netHistory.append(NetSample(rx: rx, tx: tx))
            if netHistory.count > Self.netHistoryCap { netHistory.removeFirst(netHistory.count - Self.netHistoryCap) }
            netTick &+= 1
        }

        metrics = m
        phase = .live
        onSample?(m)
    }

}
