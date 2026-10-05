import Darwin
import Foundation
import TreemapCore

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: treemap-bench <path> [workers]\n".utf8))
    exit(2)
}
let workers = args.count >= 3 ? Int(args[2]) ?? ProcessInfo.processInfo.activeProcessorCount
                              : ProcessInfo.processInfo.activeProcessorCount
let session = ScanSession(root: URL(fileURLWithPath: args[1]), workerCount: workers)
let elapsed = await ContinuousClock().measure {
    session.start()
    await session.waitUntilFinished()
}
let p = session.progress
let root = session.info(session.rootID)
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
print("path:        \(args[1])")
print("workers:     \(workers)")
print(String(format: "wall time:   %.3f s", elapsed / .seconds(1)))
print("files:       \(p.files)")
print("dirs:        \(p.directories)")
print("errors:      \(p.errors)")
let total = root?.size ?? 0
print("total bytes: \(total)  (\(total.formatted(.byteCount(style: .binary))))")
print("peak RSS:    \(usage.ru_maxrss / 1_048_576) MiB")
