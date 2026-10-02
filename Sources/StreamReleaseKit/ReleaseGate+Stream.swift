extension ReleaseGate {
    /// Pipes a stream of text deltas through the gate.
    ///
    /// Yields one `Release` per delta, then a final one from `finish()`. A block ends the
    /// stream early. An error from `chunks` is rethrown after nothing more is released, so
    /// held-back text from a failed stream never reaches the caller.
    public nonisolated func releases<Chunks>(of chunks: Chunks) -> AsyncThrowingStream<Release, Error>
    where Chunks: AsyncSequence & Sendable, Chunks.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in chunks {
                        let release = await self.ingest(chunk)
                        continuation.yield(release)
                        if release.status.isBlocked {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.yield(await self.finish())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
