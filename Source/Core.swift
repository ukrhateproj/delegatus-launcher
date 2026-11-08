import Foundation
import Darwin

struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count >= 3, let major = Int(parts[0]), let minor = Int(parts[1]),
              let patch = Int(parts[2].prefix(while: { $0.isNumber })), major >= 0, minor >= 0 else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
    var description: String { "\(major).\(minor).\(patch)" }
}

struct LauncherPaths {
    let userDirectory: URL
    let base: URL
    init(userDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, applicationSupport: URL? = nil) {
        self.userDirectory = userDirectory
        let support = applicationSupport ?? userDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        base = support.appendingPathComponent("Delegatus Launcher", isDirectory: true)
    }
    var logs: URL { base.appendingPathComponent("Logs", isDirectory: true) }
    var runtime: URL { base.appendingPathComponent("Runtime", isDirectory: true) }
    var managedBun: URL { runtime.appendingPathComponent("bun/bin/bun") }
    var managedCLI: URL { runtime.appendingPathComponent("packages/node_modules/delegatus-cli/bin/cli.mjs") }
    var settings: URL { base.appendingPathComponent("settings.json") }
}
struct LauncherSettings: Codable {
    var bunPath: String?
    var cliPath: String?
    static func load(from url: URL) -> Self {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
struct RuntimeInstallation {
    let bun: URL
    let cli: URL
    let bunVersion: String
    let delegatusVersion: String
}
struct RuntimeDiscovery {
    let installation: RuntimeInstallation?
    let usableBun: URL?
    let issue: String
}

struct RuntimeLocator {
    let paths: LauncherPaths
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var includeSystem = true
    var probeVersion: (URL) -> String? = { executable in
        let p = Process()
        p.executableURL = executable
        p.arguments = ["--version"]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut {
            if p.isRunning { p.terminate() }
            if done.wait(timeout: .now() + 1) == .timedOut && p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard data.count < 4096 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var searchDirectories: [URL] {
        var values = [paths.managedBun.deletingLastPathComponent(), paths.userDirectory.appendingPathComponent(".bun/bin"), paths.userDirectory.appendingPathComponent(".local/bin"), paths.userDirectory.appendingPathComponent(".npm-global/bin"), paths.userDirectory.appendingPathComponent("go/bin")]
        if let custom = environment["BUN_INSTALL"], custom.hasPrefix("/") { values.insert(URL(fileURLWithPath: custom).appendingPathComponent("bin"), at: 1) }
        values += (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
        if includeSystem { values += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].map { URL(fileURLWithPath: $0) } }
        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
    func processEnvironment(bun: URL?) -> [String: String] {
        var result = environment.filter { !$0.key.hasPrefix("LLV_") && !$0.key.hasPrefix("DELEGATUS_") && $0.key != "BUN_INSTALL_GLOBAL_DIR" && $0.key != "BUN_INSTALL_BIN" }
        var dirs = searchDirectories
        if let bun = bun { dirs.insert(bun.deletingLastPathComponent(), at: 0) }
        var seen = Set<String>()
        result["PATH"] = dirs.map(\.path).filter { seen.insert($0).inserted }.joined(separator: ":")
        result["HOME"] = paths.userDirectory.path
        result["LLV_LANG"] = "uk"
        result["NO_COLOR"] = "1"
        return result
    }
    func canonicalFile(_ url: URL, executable: Bool) -> URL? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory), !directory.boolValue else { return nil }
        if executable && !FileManager.default.isExecutableFile(atPath: resolved.path) { return nil }
        return resolved
    }
    func packageMetadata(at file: URL) -> (URL, String, SemanticVersion)? {
        guard let canonical = canonicalFile(file, executable: false), canonical.lastPathComponent == "cli.mjs" else { return nil }
        let package = canonical.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: package),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any], meta["name"] as? String == "delegatus-cli",
              let version = meta["version"] as? String else { return nil }
        let requirement = ((meta["engines"] as? [String: String])?["bun"] ?? ">=1.4.0").trimmingCharacters(in: .whitespaces)
        guard requirement.hasPrefix(">="),
              let minimum = SemanticVersion(String(requirement.dropFirst(2)).trimmingCharacters(in: .whitespaces)),
              requirement.range(of: #"^>=\s*[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              SemanticVersion(version) != nil else { return nil }
        return (canonical, version, minimum)
    }
    func discover(settings: LauncherSettings = LauncherSettings()) -> RuntimeDiscovery {
        var cliCandidates = [URL]()
        if let path = settings.cliPath, path.hasPrefix("/") { cliCandidates.append(URL(fileURLWithPath: path)) }
        cliCandidates += [paths.managedCLI, paths.userDirectory.appendingPathComponent(".bun/install/global/node_modules/delegatus-cli/bin/cli.mjs"), paths.userDirectory.appendingPathComponent(".npm-global/lib/node_modules/delegatus-cli/bin/cli.mjs")]
        if let path = environment["BUN_INSTALL_GLOBAL_DIR"], path.hasPrefix("/") { cliCandidates.append(URL(fileURLWithPath: path).appendingPathComponent("node_modules/delegatus-cli/bin/cli.mjs")) }
        for directory in searchDirectories {
            cliCandidates.append(directory.appendingPathComponent("delegatus"))
            cliCandidates.append(directory.deletingLastPathComponent().appendingPathComponent("lib/node_modules/delegatus-cli/bin/cli.mjs"))
        }
        let metadata = cliCandidates.lazy.compactMap { packageMetadata(at: $0) }.first
        let required = max(SemanticVersion("1.4.0")!, metadata?.2 ?? SemanticVersion("1.4.0")!)
        var bunCandidates = [URL]()
        if let path = settings.bunPath, path.hasPrefix("/") { bunCandidates.append(URL(fileURLWithPath: path)) }
        bunCandidates += searchDirectories.map { $0.appendingPathComponent("bun") }
        var seen = Set<String>()
        var selected: (URL, String)?
        for file in bunCandidates {
            guard let executable = canonicalFile(file, executable: true), seen.insert(executable.path).inserted,
                  let output = probeVersion(executable), let version = SemanticVersion(output), version >= required else { continue }
            selected = (executable, output); break
        }
        guard let (bun, version) = selected else {
            return RuntimeDiscovery(installation: nil, usableBun: nil, issue: "Потрібен Bun \(required) або новіший. Натисніть «Налаштувати», щоб установити залежності або вибрати їх вручну.")
        }
        guard let (cli, delegatusVersion, _) = metadata else {
            return RuntimeDiscovery(installation: nil, usableBun: bun, issue: "Bun знайдено. Потрібно встановити Delegatus або вибрати його наявний файл запуску.")
        }
        return RuntimeDiscovery(installation: RuntimeInstallation(bun: bun, cli: cli, bunVersion: version, delegatusVersion: delegatusVersion), usableBun: bun, issue: "")
    }
}
