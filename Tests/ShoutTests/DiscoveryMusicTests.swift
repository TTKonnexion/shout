import XCTest

final class DiscoveryModelTests: XCTestCase {
    func testDuplicateRecognitionKeepsOldDecisionsAndOrder() throws {
        let song = DiscoverySong(title: "Nacht am Meer", artist: "Testband", shazamID: "example-id")
        var list = DiscoveryList(name: "Test")
        XCTAssertTrue(list.append(song))
        let candidate = ServiceTrackCandidate(id: "11", title: song.title, artist: song.artist)
        list.entries[0].setResults([candidate], message: nil, for: .apple)
        try list.entries[0].confirm(candidate, for: .apple)
        let before = list
        XCTAssertFalse(list.append(DiscoverySong(title: " NACHT  AM MEER ", artist: "TESTBAND")))
        XCTAssertEqual(before, list)
    }
    func testSearchRefreshCannotReplaceConfirmedVersion() throws {
        var entry = DiscoveryEntry(song: DiscoverySong(title: "Licht", artist: "Test"))
        let one = ServiceTrackCandidate(id: "1", title: "Licht", artist: "Test")
        entry.setResults([one], message: nil, for: .apple)
        try entry.confirm(one, for: .apple)
        entry.setResults([], message: "Kein Treffer", for: .apple)
        XCTAssertEqual(entry.selected["apple"], one)
        XCTAssertThrowsError(try entry.confirm(one, for: .spotify))
        XCTAssertNil(entry.selected["spotify"])
    }
    func testArchiveRoundTripPreservesProviderSelectionsAndReceipts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = DiscoveryArchive(directory: folder)
        var list = DiscoveryList(name: "Reihenfolge")
        _ = list.append(DiscoverySong(title: "Licht", artist: "Test"))
        let candidate = ServiceTrackCandidate(id: "1", title: "Licht", artist: "Test")
        list.entries[0].setResults([candidate], message: nil, for: .apple)
        try list.entries[0].confirm(candidate, for: .apple)
        list.receipts.append(DiscoveryReceipt(provider: .apple, fingerprint: list.fingerprint(for: .apple)))
        try archive.save(list)
        XCTAssertEqual(try archive.load().lists, [list])
        XCTAssertTrue(try archive.load().lists[0].blocksExport(for: .apple))
    }
    func testCorruptDocumentIsNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let list = DiscoveryList(name: "Bleibt erhalten")
        let file = folder.appendingPathComponent(list.id.uuidString + ".json")
        let original = Data("unlesbare-testdatei".utf8); try original.write(to: file)
        let archive = DiscoveryArchive(directory: folder)
        XCTAssertEqual(try archive.load().unreadable, 1)
        XCTAssertThrowsError(try archive.save(list))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testProviderIdentityAndExplicitSkipAreRequiredForExport() {
        var list = DiscoveryList(name: "Test")
        _ = list.append(DiscoverySong(title: "Licht", artist: "Test"))
        list.entries[0].selected["spotify"] = ServiceTrackCandidate(id: "spotify:track:abc", title: "Licht", artist: "Test")
        XCTAssertEqual(list.confirmed(for: .apple).count, 0)
        XCTAssertEqual(list.pending(for: .apple), 1)
        let before = list.fingerprint(for: .apple)
        list.entries[0].skipped.insert("apple")
        XCTAssertEqual(list.pending(for: .apple), 0)
        XCTAssertNotEqual(before, list.fingerprint(for: .apple))
    }
    func testIncompleteRecognitionIsRejected() {
        XCTAssertNil(DiscoverySong.recognized(title: "  ", artist: "Band", shazamID: "id"))
        XCTAssertNil(DiscoverySong.recognized(title: "Licht", artist: nil, shazamID: "id"))
    }
    func testCandidateFilterDoesNotOfferUnrelatedSongOrLiveRecording() {
        let song = DiscoverySong(title: "Nacht am Meer", artist: "Testband")
        let correct = ServiceTrackCandidate(id: "1", title: song.title, artist: song.artist)
        let bad = ServiceTrackCandidate(id: "2", title: "Anderer Song", artist: song.artist)
        let live = ServiceTrackCandidate(id: "3", title: song.title + " (Live)", artist: song.artist)
        XCTAssertEqual(ServiceTrackCandidate.relevant(for: song, in: [bad, live, correct]), [correct])
    }
    func testOAuthCallbackRejectsWrongStateAndFragment() {
        XCTAssertThrowsError(try SpotifyCallback.code(from: URL(string: "shout-music://spotify?state=wrong&code=test")!,
                                                     redirectURI: "shout-music://spotify", state: "expected"))
        XCTAssertThrowsError(try SpotifyCallback.code(from: URL(string: "shout-music://spotify?state=expected&code=test#extra")!,
                                                     redirectURI: "shout-music://spotify", state: "expected"))
    }
}

@MainActor
private final class FakeDiscoveryMusic: DiscoveryMusicServing {
    var calls: [DiscoveryProvider] = []
    var responses: [DiscoveryProvider: [ServiceTrackCandidate]] = [:]
    var failure: Set<DiscoveryProvider> = []
    var pauses: [DiscoveryProvider: Duration] = [:]
    var writes = 0
    var failWrite = false
    var onWrite: (() -> Void)?
    func search(_ song: DiscoverySong, provider: DiscoveryProvider) async throws -> [ServiceTrackCandidate] {
        calls.append(provider)
        if let pause = pauses[provider] { try await Task.sleep(for: pause) }
        if failure.contains(provider) { throw DiscoveryError.notConnected(provider.title) }
        return responses[provider] ?? []
    }
    func prepareExport(_ provider: DiscoveryProvider) async throws {}
    func create(name: String, provider: DiscoveryProvider, tracks: [ServiceTrackCandidate]) async throws -> URL? {
        writes += 1; onWrite?()
        if failWrite { throw URLError(.timedOut) }
        return URL(string: "https://music.apple.com/playlist/example")
    }
}

@MainActor
final class DiscoveryWorkflowTests: XCTestCase {
    private var folder: URL!
    private var store: DiscoveryStore!
    private var service: FakeDiscoveryMusic!
    private var flow: DiscoveryWorkflow!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = DiscoveryStore(directory: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.create()
        _ = store.update(store.active!.id) { _ = $0.append(DiscoverySong(title: "Nacht am Meer", artist: "Testband")) }
        service = FakeDiscoveryMusic(); flow = DiscoveryWorkflow(store: store, services: service)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }
    private var candidate: ServiceTrackCandidate { ServiceTrackCandidate(id: "1", title: "Nacht am Meer", artist: "Testband") }
    func testAppleResultStopsFurtherSearchButDoesNotConfirmOrExport() async {
        service.responses[.apple] = [candidate]
        await flow.search(listID: store.active!.id, entries: [store.active!.entries[0].id])
        XCTAssertEqual(service.calls, [.apple])
        XCTAssertTrue(store.active!.entries[0].selected.isEmpty)
        XCTAssertEqual(service.writes, 0)
    }
    func testMissingAppleResultFallsBackAndStopsAtSpotify() async {
        service.responses[.spotify] = [candidate]
        await flow.search(listID: store.active!.id, entries: [store.active!.entries[0].id])
        XCTAssertEqual(service.calls, [.apple, .spotify])
        XCTAssertTrue(store.active!.entries[0].selected.isEmpty)
    }
    func testDisconnectedServiceDoesNotBlockTidal() async {
        service.failure = [.apple, .spotify]; service.responses[.tidal] = [candidate]
        await flow.search(listID: store.active!.id, entries: [store.active!.entries[0].id])
        XCTAssertEqual(service.calls, [.apple, .spotify, .tidal])
        XCTAssertNotNil(store.active!.entries[0].messages["apple"])
    }
    func testCancelledSearchDoesNotSaveLateResultsOrContinueFallback() async {
        service.pauses[.apple] = .seconds(5)
        let task = Task { await flow.search(listID: store.active!.id, entries: [store.active!.entries[0].id]) }
        while service.calls.isEmpty { await Task.yield() }
        task.cancel(); await task.value
        XCTAssertEqual(service.calls, [.apple])
        XCTAssertTrue(store.active!.entries[0].candidates.isEmpty)
        XCTAssertFalse(flow.searching)
    }
    func testSearchTimeoutContinuesToNextService() async {
        service.pauses[.apple] = .seconds(5); service.responses[.spotify] = [candidate]
        let bounded = DiscoveryWorkflow(store: store, services: service, searchTimeout: .milliseconds(10))
        await bounded.search(listID: store.active!.id, entries: [store.active!.entries[0].id])
        XCTAssertEqual(service.calls, [.apple, .spotify])
        XCTAssertNotNil(store.active!.entries[0].messages["apple"])
    }
    func testTargetSpecificExportLookupDoesNotUseOtherProvider() async {
        service.responses[.spotify] = [candidate]
        await flow.search(listID: store.active!.id, entries: [store.active!.entries[0].id], startingAt: .apple, only: true)
        XCTAssertEqual(service.calls, [.apple])
    }
    func testUnreviewedListCannotBeExported() async {
        await flow.export(listID: store.active!.id, provider: .apple)
        XCTAssertEqual(service.writes, 0)
        XCTAssertTrue(store.active!.receipts.isEmpty)
    }
    func testReceiptIsDurableBeforeWriteAndRepeatedExportIsBlocked() async throws {
        let id = store.active!.id, entry = store.active!.entries[0].id, candidate = self.candidate
        store.updateEntry(id, entryID: entry) { $0.setResults([candidate], message: nil, for: .apple); try $0.confirm(candidate, for: .apple) }
        service.onWrite = { [folder] in
            let saved = try! DiscoveryArchive(directory: folder!).load().lists[0]
            XCTAssertEqual(saved.receipts.last?.state, .started)
        }
        await flow.export(listID: id, provider: .apple)
        await flow.export(listID: id, provider: .apple)
        XCTAssertEqual(service.writes, 1)
        XCTAssertEqual(store.active!.receipts.last?.state, .complete)
    }
    func testAmbiguousWriteSurvivesReloadAndBlocksRetry() async throws {
        let id = store.active!.id, entry = store.active!.entries[0].id, candidate = self.candidate
        store.updateEntry(id, entryID: entry) { $0.setResults([candidate], message: nil, for: .apple); try $0.confirm(candidate, for: .apple) }
        service.failWrite = true
        await flow.export(listID: id, provider: .apple)
        let saved = try DiscoveryArchive(directory: folder).load().lists[0]
        XCTAssertEqual(saved.receipts.last?.state, .uncertain)
        XCTAssertTrue(saved.blocksExport(for: .apple))
        await flow.export(listID: id, provider: .apple)
        XCTAssertEqual(service.writes, 1)
    }
}

private actor DiscoveryHTTPStub: SpotifyHTTP {
    var responses: [(Int, Data)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, Data)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.timedOut) }
        let value = responses.removeFirst()
        return (value.1, HTTPURLResponse(url: request.url!, statusCode: value.0, httpVersion: nil, headerFields: nil)!)
    }
    var count: Int { requests.count }
}
private struct DiscoveryTokensStub: SpotifyTokenProviding {
    func accessToken(forceRefresh: Bool) async throws -> String { "example-test-value" }
}
final class DiscoveryExportClientTests: XCTestCase {
    func testSpotifyAmbiguousWriteIsNotRepeated() async {
        let http = DiscoveryHTTPStub([(201, Data(#"{"id":"example"}"#.utf8))])
        let client = SpotifyPlaylistExportClient(http: http, tokens: DiscoveryTokensStub())
        do { _ = try await client.create(name: "Test", uris: ["spotify:track:abc"]); XCTFail("Expected an ambiguous write") }
        catch {}
        let count = await http.count
        XCTAssertEqual(count, 2)
    }
    func testTidalUnconfirmedItemsAreNotCountedAsSuccess() async {
        let http = DiscoveryHTTPStub([(201, Data(#"{"data":{"id":"example"}}"#.utf8)), (200, Data(#"{"data":[]}"#.utf8))])
        let client = TidalPlaylistClient(http: http, tokens: DiscoveryTokensStub())
        do { _ = try await client.create(name: "Test", trackIDs: ["123"]); XCTFail("Expected partial result") }
        catch TidalAPIError.partial(let id, let confirmed) { XCTAssertEqual(id, "example"); XCTAssertEqual(confirmed, 0) }
        catch { XCTFail("Unexpected error") }
        let count = await http.count
        XCTAssertEqual(count, 2)
    }
}
