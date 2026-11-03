// Runs a user-supplied command line for the `Action.runCommand` keybind.
//
// command execution is a security boundary here: the line is tokenized
// in-process and handed to `Process` as executable + argv. no shell is
// ever involved, so pipes, redirects, globs and `$VAR` are inert. none
// of the command text, its arguments, or its output reaches the logs.

import Foundation

/// tokenizes a command line and runs it directly, never via a shell
enum CommandLineParser {
    enum ParseError: Error, Equatable {
        case empty
        case unterminatedQuote
        case trailingBackslash
    }

    /// quote-aware split. whitespace separates tokens, `"..."` and
    /// `'...'` group, a backslash escapes the next character outside
    /// single quotes, and a leading `~` or `~/` expands to `home` —
    /// only at the start of a token, and only when unquoted.
    static func tokenize(_ line: String, home: String = NSHomeDirectory()) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false        // a token is open, even if still empty
        var quotedStart = false    // the token's first character came from a quote or escape
        var inDouble = false
        var inSingle = false
        var escaped = false

        func flush() {
            guard started else { return }
            tokens.append(quotedStart ? current : expandTilde(current, home: home))
            current = ""
            started = false
            quotedStart = false
        }

        for ch in line {
            if escaped {
                if !started { started = true; quotedStart = true }
                current.append(ch)
                escaped = false
                continue
            }
            if inSingle {
                if ch == "'" { inSingle = false } else { current.append(ch) }
                continue
            }
            if inDouble {
                if ch == "\\" { escaped = true } else if ch == "\"" { inDouble = false } else { current.append(ch) }
                continue
            }
            switch ch {
            case "\\":
                escaped = true
            case "\"":
                if !started { started = true; quotedStart = true }
                inDouble = true
            case "'":
                if !started { started = true; quotedStart = true }
                inSingle = true
            case " ", "\t", "\n", "\r", "\u{00A0}":
                flush()
            default:
                started = true
                current.append(ch)
            }
        }

        if escaped { throw ParseError.trailingBackslash }
        if inDouble || inSingle { throw ParseError.unterminatedQuote }
        flush()
        guard !tokens.isEmpty else { throw ParseError.empty }
        return tokens
    }

    /// `~` or `~/rest` at the head of an unquoted token becomes `home`.
    private static func expandTilde(_ token: String, home: String) -> String {
        guard token.hasPrefix("~") else { return token }
        if token == "~" { return home }
        if token.hasPrefix("~/") { return home + token.dropFirst(1) }
        return token
    }
}

/// resolves a program token to an executable file URL
enum ProgramResolver {
    /// fallback search dirs for a GUI-launched app whose PATH is minimal
    static let fallbackSearchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    enum ResolveError: Error, Equatable {
        case notFound
        case notExecutable
    }

    /// a token containing "/" is used as-is (the tokenizer already
    /// expanded any leading `~`); otherwise the search dirs are walked in
    /// order. inherited PATH entries come first so a user's own tools win
    /// over the fallbacks.
    static func resolve(_ program: String,
                        searchPaths: [String]? = nil,
                        home: String = NSHomeDirectory(),
                        fileManager: FileManager = .default) throws -> URL {
        guard !program.isEmpty else { throw ResolveError.notFound }
        if program.contains("/") {
            // a relative path means relative to the child's cwd, the home dir
            let path = program.hasPrefix("/")
                ? program
                : (home as NSString).appendingPathComponent(program)
            guard fileManager.fileExists(atPath: path) else { throw ResolveError.notFound }
            guard isExecutableFile(path, fileManager: fileManager) else {
                throw ResolveError.notExecutable
            }
            return URL(fileURLWithPath: path)
        }

        var sawNonExecutableMatch = false
        for dir in searchPaths ?? defaultSearchPaths() {
            let candidate = (dir as NSString).appendingPathComponent(program)
            guard fileManager.fileExists(atPath: candidate) else { continue }
            if isExecutableFile(candidate, fileManager: fileManager) {
                return URL(fileURLWithPath: candidate)
            }
            sawNonExecutableMatch = true
        }
        throw sawNonExecutableMatch ? ResolveError.notExecutable : ResolveError.notFound
    }

    /// inherited PATH entries first, then the fallbacks, deduped.
    static func defaultSearchPaths() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let inherited = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        for dir in inherited + fallbackSearchPaths where seen.insert(dir).inserted {
            result.append(dir)
        }
        return result
    }

    /// a regular file the current user can exec — a directory is not one,
    /// even though it passes the POSIX x bit.
    private static func isExecutableFile(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }
}

/// validates a command line for the editor and runs it for the dispatcher
final class CommandRunner {
    /// the associated `String` is the program token — for the settings UI
    /// only, never for a log line.
    enum ValidationError: Error, Equatable {
        case empty
        case unterminatedQuote
        case trailingBackslash
        case programNotFound(String)
        case programNotExecutable(String)

        /// one line for the editor sheet. the program token is the user's
        /// own text and stays in the UI — it never reaches a log line.
        var message: String {
            switch self {
            case .empty:                      return "Enter a command."
            case .unterminatedQuote:          return "Unbalanced quote in command."
            case .trailingBackslash:          return "Command ends with a backslash."
            case .programNotFound(let p) where p.isEmpty: return "Enter a program to run."
            case .programNotFound(let p):     return "Program not found: \(p)"
            case .programNotExecutable(let p): return "Program is not executable: \(p)"
            }
        }
    }

    /// nil when `command` would run. the editor sheet shows the message.
    static func validate(_ command: String) -> ValidationError? {
        let tokens: [String]
        do {
            tokens = try CommandLineParser.tokenize(command)
        } catch CommandLineParser.ParseError.empty {
            return .empty
        } catch CommandLineParser.ParseError.unterminatedQuote {
            return .unterminatedQuote
        } catch CommandLineParser.ParseError.trailingBackslash {
            return .trailingBackslash
        } catch {
            return .empty
        }
        guard let program = tokens.first else { return .empty }
        do {
            _ = try ProgramResolver.resolve(program)
        } catch ProgramResolver.ResolveError.notFound {
            return .programNotFound(program)
        } catch ProgramResolver.ResolveError.notExecutable {
            return .programNotExecutable(program)
        } catch {
            return .programNotFound(program)
        }
        return nil
    }

    /// Launch the command. Returns nil on success, or the reason it never
    /// started. Asynchronous — the caller is the main thread on a hotkey
    /// press, so this never waits for the child.
    @discardableResult
    func run(command: String) -> ValidationError? {
        let launched = launch(command: command) { finished in
            // only the exit status number, never the command or its output
            if finished.terminationStatus != 0 {
                hyprLog(.notice, .lifecycle,
                        "runCommand exited with status \(finished.terminationStatus)")
            }
        }
        if case .failure(let error) = launched { return error }
        hyprLog(.debug, .lifecycle, "runCommand dispatched")
        return nil
    }

    /// The launch behind `run`, for callers that need the child: the status
    /// hook adds `environment` on top of the app's own, waits for `onExit`
    /// and kills a child that hangs. Same tokenizing and lookup, no shell.
    func launch(command: String, environment: [String: String] = [:],
                logName: String = "runCommand",
                onExit: @escaping (Process) -> Void) -> Result<Process, ValidationError> {
        let tokens: [String]
        do {
            tokens = try CommandLineParser.tokenize(command)
        } catch CommandLineParser.ParseError.unterminatedQuote {
            return .failure(.unterminatedQuote)
        } catch CommandLineParser.ParseError.trailingBackslash {
            return .failure(.trailingBackslash)
        } catch {
            return .failure(.empty)
        }
        guard let program = tokens.first else { return .failure(.empty) }

        let executable: URL
        do {
            executable = try ProgramResolver.resolve(program)
        } catch ProgramResolver.ResolveError.notExecutable {
            return .failure(.programNotExecutable(program))
        } catch {
            return .failure(.programNotFound(program))
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = Array(tokens.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        // output is the user's business, not ours — discarding it keeps it
        // out of the log file entirely.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = onExit

        do {
            try process.run()
        } catch {
            // the NSError code alone — the description carries the path
            hyprLog(.warning, .lifecycle,
                    "\(logName) launch failed (code \((error as NSError).code))")
            return .failure(.programNotFound(program))
        }
        return .success(process)
    }
}
