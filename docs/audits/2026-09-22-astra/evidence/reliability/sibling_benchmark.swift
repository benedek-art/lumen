import Foundation

@main struct SiblingBenchmark {
    static func main() throws {
        let raw: Set<String> = ["arw", "sr2", "srf", "arq", "cr2", "cr3", "crw", "nef", "nrw", "orf", "pef", "dng", "raf", "rw2", "rwl", "srw", "erf", "x3f", "3fr", "fff", "iiq", "cap", "mrw", "dcr", "kdc", "mef", "raw"]
        let selected = CommandLine.arguments.dropFirst().compactMap(Int.init)
        for count in (selected.isEmpty ? [100,500,1000,2000] : selected) {
            let names = (0..<count).map { String(format: "DSC_%05d.JPG", $0) }
            let files = names.map { URL(fileURLWithPath: "/tmp/synthetic-photographs/" + $0) }
            let start = Date()
            var calls = 0
            var found = 0
            for file in files {
                // registerAndLoad invokes this through merge twice, restoreStrokes once,
                // and persistRecovered once, even for rendered JPG files.
                for _ in 0..<4 {
                    found += SidecarNaming.rawSiblingExtensions(of: file, amongNames: names,
                        isRawName: { raw.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }).count
                    calls += 1
                }
            }
            let output: [String: Any] = ["files":count,"siblingLookups":calls,"found":found,"seconds":Date().timeIntervalSince(start),"optimization":"swiftc -O"]
            print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
            fflush(stdout)
        }
    }
}
