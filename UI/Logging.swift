import Foundation
func riftLog(_ s: String) {
    print(s); fflush(stdout)
    let line = s + "\n"
    for path in ["/tmp/rift.log", NSHomeDirectory() + "/Desktop/rift.log"] {
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(data); h.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
