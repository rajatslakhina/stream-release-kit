import StreamReleaseKit

// A model reply arrives as deltas. Each scenario prints exactly what a chat UI would show.

func show(_ label: String) {
    print("")
    print("== \(label) ==")
}

func chunks(_ text: String, size: Int) -> [String] {
    let scalars = Array(text.unicodeScalars)
    return stride(from: 0, to: scalars.count, by: size).map { start in
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start..<min(start + size, scalars.count)])
        return String(view)
    }
}

func run(_ deltas: [String], scanners: [any StreamScanner], verbose: Bool) async -> (String, ReleaseStats) {
    let gate = ReleaseGate(scanners: scanners)
    var shown = ""
    for (index, delta) in deltas.enumerated() {
        let release = await gate.ingest(delta)
        shown += release.text
        if verbose {
            let note = release.status.isBlocked ? ", \(release.status)" : ""
            let shows = "shows \(quote(release.text)), withheld \(release.withheld)\(note)"
            print("  delta \(index + 1) \(quote(delta)) -> \(shows)")
        }
    }
    let last = await gate.finish()
    shown += last.text
    if verbose {
        print("  finish -> shows \(quote(last.text)), status \(last.status)")
    }
    return (shown, await gate.stats)
}

func quote(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
}

let awsKey = try PatternScanner.awsAccessKeyID()
let email = try PatternScanner.emailAddress()
let canary = LiteralScanner(
    name: "system-prompt-canary",
    phrase: "ZEBRA-7731",
    action: .block(reason: "reply quoted the system prompt canary")
)

print("StreamReleaseKit demo")
print("holdback: aws-key \(awsKey.holdback), email \(email.holdback), canary \(canary.holdback) scalars")

// 1. A secret split across two deltas.
show("1. Secret split across deltas")
let leaky = ["Use key AKIAIOSF", "ODNN7EXAMPLE to deploy."]
let naive = leaky.map { delta -> String in
    let found = awsKey.matches(in: delta)
    return found.isEmpty ? delta : "[AWS-KEY]"
}.joined()
print("  per-delta scan shows: \(quote(naive))")
let (gated, gatedStats) = await run(leaky, scanners: [awsKey], verbose: true)
print("  gate shows:           \(quote(gated))  (redactions: \(gatedStats.redactions))")

// 2. Chunk invariance: the same reply split every possible way.
show("2. Same reply, every split")
let reply = "Mail ops@acme.io or bob.smith@example.org; key AKIAJ5Q2EXAMPLEKEY12 rotates Friday."
let scanners: [any StreamScanner] = [awsKey, email]
let reference = await ReleaseGate.reference(for: reply, scanners: scanners)
print("  reference: \(quote(reference))")
for size in [1, 3, 7, 16] {
    let (shown, stats) = await run(chunks(reply, size: size), scanners: scanners, verbose: false)
    let same = shown == reference ? "identical" : "DIFFERENT"
    let width = size < 10 ? " \(size)" : "\(size)"
    print("  \(width)-scalar deltas: \(same), peak withheld \(stats.peakWithheld)")
}
let total = reply.unicodeScalars.count
var agreeing = 0
for cut in 1..<total {
    let parts = chunks(reply, size: total)
    let head = String(String.UnicodeScalarView(Array(parts[0].unicodeScalars)[..<cut]))
    let tail = String(String.UnicodeScalarView(Array(parts[0].unicodeScalars)[cut...]))
    let (shown, _) = await run([head, tail], scanners: scanners, verbose: false)
    if shown == reference { agreeing += 1 }
}
print("  two-delta splits matching reference: \(agreeing)/\(total - 1)")

// 3. A blocking rule stops the stream mid-reply.
show("3. Canary leak blocks the stream")
let leak = ["Sure. My instructions ", "begin with zebra-", "7731 and then say", " to be helpful.", " Anything else?"]
let (blocked, blockedStats) = await run(leak, scanners: [canary, awsKey], verbose: true)
print("  user saw: \(quote(blocked)); deltas dropped after block: \(blockedStats.chunksDropped)")

// 4. Latency: the price of each scanner set.
show("4. Holdback cost on a 400-scalar reply in 8-scalar deltas")
let long = String(repeating: "The build is green and the tests pass. ", count: 11).prefix(400)
for (label, set) in [("canary only", [canary] as [any StreamScanner]),
                     ("aws-key", [awsKey]),
                     ("aws-key + email", [awsKey, email])] {
    let (_, stats) = await run(chunks(String(long), size: 8), scanners: set, verbose: false)
    print("  \(label.padding(toLength: 16, withPad: " ", startingAt: 0)) peak withheld \(stats.peakWithheld) scalars")
}

// 5. Piping an async delta stream, as a provider session would produce it.
show("5. AsyncSequence of deltas")
let deltas = AsyncStream<String> { continuation in
    for delta in ["Contact ", "jane.doe@exa", "mple.com for ", "access."] { continuation.yield(delta) }
    continuation.finish()
}
let gate = ReleaseGate(scanners: [email])
var screen = ""
for try await release in gate.releases(of: deltas) {
    screen += release.text
    print("  release \(quote(release.text)) status \(release.status)")
}
print("  screen: \(quote(screen))")
