import Foundation
import Testing
@testable import MacDM

/// Remembering recent video lookups, so reopening the quality list doesn't wait for yt-dlp again.
@Suite("Video lookup cache")
struct MediaInfoStoreTests {
    /// Counts how many times the (slow) lookup actually ran.
    actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }

    private func info(_ title: String) -> MediaInfo {
        MediaInfo(title: title, thumbnail: nil, duration: nil, options: [])
    }

    /// A clock the test can move forward.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    @Test("the same page asked again within the time limit is answered from memory")
    func cachedWithinTTL() async throws {
        let counter = Counter(); let clock = Clock()
        let store = MediaInfoStore(ttl: 600, now: { clock.now })
        let load: @Sendable () async throws -> MediaInfo = { _ = await counter.next(); return self.info("A") }

        _ = try await store.info(for: "page1", load: load)
        clock.advance(300)
        let again = try await store.info(for: "page1", load: load)
        #expect(again.title == "A")
        #expect(await counter.value == 1)
    }

    @Test("after the time limit the page is looked up again")
    func expires() async throws {
        let counter = Counter(); let clock = Clock()
        let store = MediaInfoStore(ttl: 600, now: { clock.now })
        let load: @Sendable () async throws -> MediaInfo = { _ = await counter.next(); return self.info("A") }

        _ = try await store.info(for: "page1", load: load)
        clock.advance(601)
        _ = try await store.info(for: "page1", load: load)
        #expect(await counter.value == 2)
    }

    @Test("different pages are kept separately")
    func separateKeys() async throws {
        let counter = Counter()
        let store = MediaInfoStore()
        let a = try await store.info(for: "page1") { _ = await counter.next(); return self.info("A") }
        let b = try await store.info(for: "page2") { _ = await counter.next(); return self.info("B") }
        #expect(a.title == "A")
        #expect(b.title == "B")
        #expect(await counter.value == 2)
    }

    @Test("two requests at the same moment share one lookup")
    func sharesInFlight() async throws {
        let counter = Counter()
        let store = MediaInfoStore()
        let load: @Sendable () async throws -> MediaInfo = {
            _ = await counter.next()
            try await Task.sleep(nanoseconds: 300_000_000)   // a slow yt-dlp
            return self.info("A")
        }
        async let first = store.info(for: "page1", load: load)
        async let second = store.info(for: "page1", load: load)
        let results = try await [first, second]
        #expect(results.map(\.title) == ["A", "A"])
        #expect(await counter.value == 1)
    }

    struct LookupFailed: Error {}

    @Test("a failed lookup is not remembered, so the next try runs again")
    func failuresNotCached() async throws {
        let counter = Counter()
        let store = MediaInfoStore()
        await #expect(throws: LookupFailed.self) {
            _ = try await store.info(for: "page1") { _ = await counter.next(); throw LookupFailed() }
        }
        let ok = try await store.info(for: "page1") { _ = await counter.next(); return self.info("A") }
        #expect(ok.title == "A")
        #expect(await counter.value == 2)
    }

    @Test("clear forgets everything")
    func clearForgets() async throws {
        let counter = Counter()
        let store = MediaInfoStore()
        let load: @Sendable () async throws -> MediaInfo = { _ = await counter.next(); return self.info("A") }
        _ = try await store.info(for: "page1", load: load)
        await store.clear()
        _ = try await store.info(for: "page1", load: load)
        #expect(await counter.value == 2)
    }
}
