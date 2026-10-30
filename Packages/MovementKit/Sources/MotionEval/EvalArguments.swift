import Foundation

enum EvalArgumentError: Error, Equatable, LocalizedError {
    case unknownOption(String)
    case missingValue(String)
    case badValue(option: String, value: String)
    case noInputs

    var errorDescription: String? {
        switch self {
        case let .unknownOption(option): "unknown option '\(option)'"
        case let .missingValue(option): "option '\(option)' needs a value"
        case let .badValue(option, value): "'\(value)' is not a valid value for '\(option)'"
        case .noInputs: "no input: pass fixture (.jsonl) or video (.mov, .mp4) files, or --synthetic"
        }
    }
}

struct EvalArguments: Equatable {
    var paths: [String] = []
    /// Also run the built-in synthetic benchmark set.
    var synthetic = false
    /// An exercise spec id (`squat.bodyweight`, `pushup`) or the path of a spec `.json`; overrides what the
    /// inputs say.
    var specOverride: String?
    /// Frame-rate cap for videos; nil processes every frame.
    var maxFrameRate: Double? = 30
    var help = false

    static let usage = """
    Usage: motion-eval [options] [file-or-directory ...]

    Runs pose fixtures (.jsonl) and videos (.mov, .mp4, .m4v) through the motion engine and prints a
    Markdown table of expected and counted reps, with a summary.

    Expected counts come from the fixture's labels, or from the file name:
      squat.bodyweight_10.mov     10 reps of the squat spec
      pushup_8_2.mp4              8 reps and 2 partial reps of the push-up spec
      squat.bodyweight_0.jsonl    an idle clip: any counted rep is a false rep

    Options:
      --synthetic        also run the built-in synthetic benchmark set (needs no recordings)
      --spec <id|path>   use this exercise spec (bundled id or a spec .json) for every input
      --fps <n|all>      frame-rate cap for videos (default 30; 'all' processes every frame)
      -h, --help         show this help

    Exit status: 0 on success, 1 if any input could not be read, 2 for a usage error.
    """

    static func parse(_ arguments: [String]) throws -> EvalArguments {
        var result = EvalArguments()
        var index = 0
        func value(for option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw EvalArgumentError.missingValue(option) }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                result.help = true
            case "--synthetic":
                result.synthetic = true
            case "--spec":
                result.specOverride = try value(for: argument)
            case "--fps":
                let raw = try value(for: argument)
                if raw.lowercased() == "all" {
                    result.maxFrameRate = nil
                } else if let fps = Double(raw), fps > 0, fps.isFinite {
                    result.maxFrameRate = fps
                } else {
                    throw EvalArgumentError.badValue(option: argument, value: raw)
                }
            case _ where argument.hasPrefix("--spec="):
                result.specOverride = String(argument.dropFirst("--spec=".count))
            case _ where argument.hasPrefix("--fps="):
                let raw = String(argument.dropFirst("--fps=".count))
                if raw.lowercased() == "all" {
                    result.maxFrameRate = nil
                } else if let fps = Double(raw), fps > 0, fps.isFinite {
                    result.maxFrameRate = fps
                } else {
                    throw EvalArgumentError.badValue(option: "--fps", value: raw)
                }
            case _ where argument.hasPrefix("-") && argument != "-":
                throw EvalArgumentError.unknownOption(argument)
            default:
                result.paths.append(argument)
            }
            index += 1
        }
        if !result.help, result.paths.isEmpty, !result.synthetic { throw EvalArgumentError.noInputs }
        return result
    }
}
