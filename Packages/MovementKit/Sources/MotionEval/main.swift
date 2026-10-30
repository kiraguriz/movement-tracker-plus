import Foundation

// motion-eval: runs recorded pose fixtures (.jsonl) and videos (.mov/.mp4) through MotionCore and prints a
// Markdown accuracy table. See `motion-eval --help`.
exit(await MotionEvalCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
