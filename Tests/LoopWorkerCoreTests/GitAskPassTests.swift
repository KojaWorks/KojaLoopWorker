import Foundation
import Testing
@testable import LoopWorkerCore

@Suite struct GitAskPassTests {
    @Test func scriptAnswersUsernameAndPasswordFromTheEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "askpass-\(UUID())")
        let env = try GitAskPass.environment(scriptDirectory: dir, username: "oauth2", password: "fake-token")
        func ask(_ prompt: String) throws -> String {
            let p = Process()
            p.executableURL = URL(filePath: env["GIT_ASKPASS"]!)
            p.arguments = [prompt]
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try ask("Username for 'https://gitlab.com': ") == "oauth2\n")
        #expect(try ask("Password for 'https://oauth2@gitlab.com': ") == "fake-token\n")
        #expect(!(try String(contentsOf: URL(filePath: env["GIT_ASKPASS"]!), encoding: .utf8)).contains("fake-token"))
    }
}
