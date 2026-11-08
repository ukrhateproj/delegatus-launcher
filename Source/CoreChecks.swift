import Foundation

@main
struct CoreChecks {
 static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var passed = 0
    func check(_ condition: @autoclosure () -> Bool, _ title: String) {
        guard condition() else { fatalError("FAIL: " + title) }
        passed += 1; print("PASS: " + title)
    }
    func executable(_ url: URL, output: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\nprintf '%s\\n' '" + output + "'\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func package(_ url: URL, minimum: String = ">=1.4.0") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// fixture; should never execute\n".write(to: url, atomically: true, encoding: .utf8)
        let data = try JSONSerialization.data(withJSONObject: ["name":"delegatus-cli","version":"1.11.0","engines":["bun":minimum]])
        try data.write(to: url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json"))
    }
    let user = root.appendingPathComponent("Олег O'Neil with spaces", isDirectory: true)
    let paths = LauncherPaths(userDirectory: user)
    var locator = RuntimeLocator(paths: paths, environment: ["PATH":"relative-path::/absolute-path"], includeSystem: false)
    check(locator.discover().installation == nil, "clean user has understandable missing dependencies")
    check(paths.base.path.hasPrefix(user.path), "logs/settings/runtime belong to injected user")
    check(!locator.searchDirectories.contains { !$0.path.hasPrefix("/") }, "relative PATH entries do not resolve from app folder")
    try executable(paths.managedBun, output: "1.4.3")
    check(locator.discover().usableBun != nil && locator.discover().installation == nil, "existing Bun without Delegatus prompts setup")
    try package(paths.managedCLI)
    let managed = locator.discover().installation
    check(managed?.bun.path == paths.managedBun.path, "private runtime works with Unicode spaces and apostrophes")
    check(managed?.delegatusVersion == "1.11.0", "Delegatus metadata read without executing its CLI")
    try executable(paths.managedBun, output: "1.3.99")
    check(locator.discover().installation == nil, "incompatible Bun is rejected numerically")
    let alt = root.appendingPathComponent("custom path/bin/bun")
    try executable(alt, output: "1.10.0")
    let settings = LauncherSettings(bunPath: alt.path, cliPath: paths.managedCLI.path)
    check(locator.discover(settings: settings).installation?.bun.path == alt.path, "explicit custom Bun supported and 1.10 is newer than 1.4")
    try settings.save(to: paths.settings)
    check(LauncherSettings.load(from: paths.settings).bunPath == alt.path, "user-specific settings round trip")
    let mode = (try FileManager.default.attributesOfItem(atPath: paths.settings.path)[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o600, "settings are private")
    let globalCLI = user.appendingPathComponent(".bun/install/global/node_modules/delegatus-cli/bin/cli.mjs")
    try package(globalCLI)
    let bin = user.appendingPathComponent(".bun/bin/bun")
    try executable(bin, output: "1.4.4")
    try FileManager.default.removeItem(at: paths.managedCLI.deletingLastPathComponent().deletingLastPathComponent())
    check(locator.discover().installation?.cli.path == globalCLI.path, "existing user installation is reused")
    let link = user.appendingPathComponent(".local/bin/delegatus")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: globalCLI)
    check(locator.packageMetadata(at: link)?.0.path == globalCLI.path, "delegatus command symlink resolves correctly")
    let wrongEntry = globalCLI.deletingLastPathComponent().appendingPathComponent("mcp-server.mjs")
    try "// not a viewer entry".write(to: wrongEntry, atomically: true, encoding: .utf8)
    check(locator.packageMetadata(at: wrongEntry) == nil, "MCP server cannot be selected as the viewer entrypoint")
    try package(globalCLI, minimum: "^2.0.0")
    check(locator.packageMetadata(at: globalCLI) == nil, "unknown Bun engine range is not treated as compatible")
    try package(globalCLI, minimum: ">=1.5.0")
    check(locator.discover().installation == nil, "package-specific newer Bun requirement respected")
    let environment = locator.processEnvironment(bun: alt)
    check(environment["HOME"] == user.path && environment["PATH"]!.hasPrefix(alt.deletingLastPathComponent().path), "child environment uses recipient paths")
    locator.environment["LLV_RUNTIME_HOST_SOCKET"] = "/unrelated/state.sock"
    check(locator.processEnvironment(bun: alt)["LLV_RUNTIME_HOST_SOCKET"] == nil, "unrelated runtime transport override is not inherited")
    check(SemanticVersion("garbage") == nil && SemanticVersion("1.4.3")! > SemanticVersion("1.4.0")!, "version parse handles invalid text")
    let hanging = root.appendingPathComponent("slow-bun")
    try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: hanging, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hanging.path)
    let start = Date()
    check(locator.probeVersion(hanging) == nil && Date().timeIntervalSince(start) < 6, "unresponsive version probe is bounded and cleaned up")
    print("\(passed) PASS / 0 FAIL")
 }
}
