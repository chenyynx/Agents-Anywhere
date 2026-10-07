import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import ClientCore

private func imageThumbnailFixture(width: Int, height: Int) -> Data? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

@Suite @MainActor struct ChatSessionPolishTests {
    private func chat(_ http: TestHTTPTransport) -> SessionChatModel {
        let repo = repository(transport: http)
        return SessionChatModel(session: repo.session(id: "session"), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
    }

    @Test func serverAttachmentIDsNeverFallThroughToDeviceFS() {
        let file = V2AttachmentContent(rawContent: .object(["fileId": .string("file_uploaded"), "path": .string("photo.png")]))
        #expect(!file.readsFromDevice)
        let device = V2AttachmentContent(rawContent: .object(["fileId": .string("device-image"), "path": .string("photo.png")]))
        #expect(device.readsFromDevice)
    }

    @Test func outgoingImageBubbleSizingClampsRatiosAndPreservesTheLongImageTop() throws {
        let tall = try #require(ChatImageThumbnail.bubbleSize(for: CGSize(width: 1179, height: 2556)))
        #expect(tall == CGSize(width: 192, height: 320))
        #expect(ChatImageThumbnail.shouldAlignTop(for: CGFloat(1179) / 2556))

        let portrait = try #require(ChatImageThumbnail.bubbleSize(for: CGSize(width: 3, height: 4)))
        #expect(portrait == CGSize(width: 240, height: 320))
        let landscape = try #require(ChatImageThumbnail.bubbleSize(forAspectRatio: 16.0 / 9.0))
        #expect(landscape.width == 240 && abs(landscape.height - 135) < 0.001)
        let extremeWide = try #require(ChatImageThumbnail.bubbleSize(forAspectRatio: 3))
        #expect(extremeWide.width == 240 && abs(extremeWide.height - 133.3333) < 0.001)
        #expect(!ChatImageThumbnail.shouldAlignTop(for: 0.6))
        #expect(ChatImageThumbnail.bubbleSize(for: .zero) == nil)
        #expect(ChatImageThumbnail.bubbleSize(forAspectRatio: .infinity) == nil)

        #expect(ChatImageThumbnail.gridCellSize() == 118)
        #expect(ChatImageThumbnail.maximumPixelSize(for: tall, displayScale: 3) == 960)
        #expect(ChatImageThumbnail.maximumPixelSize(for: CGSize(width: 118, height: 118), displayScale: 3) == 354)
    }

    @Test func imageThumbnailRespectsItsDisplayPixelLimit() throws {
        let source = try #require(imageThumbnailFixture(width: 1200, height: 800))
        let thumbnail = try #require(ChatImageThumbnail.make(data: source, maxPixelSize: 300))
        let size = try #require(ChatImageThumbnail.imageSize(data: thumbnail))
        #expect(size.width == 300 && size.height == 200)
    }

    @Test func outgoingPreviewDimensionsSurviveCacheEvictionAndArchiveRestore() throws {
        let preview = try #require(imageThumbnailFixture(width: 40, height: 80))
        let attachment = ChatAttachment(id: "image", name: "long.png", data: Data([1]),
            mediaType: "image/png", previewData: preview)
        let store = ChatAttachmentStore(byteLimit: 1)
        store.remember([attachment], clientID: "message")

        let resolved = try #require(store.resolve([attachment.content], clientID: "message").first)
        #expect(resolved.previewData == nil)
        #expect(resolved.previewPixelSize == CGSize(width: 40, height: 80))

        let restored = ChatAttachmentStore(byteLimit: 1)
        restored.restore(store.archived())
        let restoredImage = try #require(restored.resolve([attachment.content], clientID: "message").first)
        #expect(restoredImage.previewPixelSize == CGSize(width: 40, height: 80))
    }

    @Test func openingKeepsTheLatestWindowWithoutFetchingAnEarlierUserMessage() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("snapshot") {
                var snapshot = try fixtureObject("snapshot")
                var timeline = snapshot["timeline"] as! [String: Any]
                var tool = try itemObject(id: "tool", order: 100)
                tool["type"] = "tool"; tool["content"] = ["kind": "command", "command": "pwd"]
                timeline["items"] = [tool]; timeline["hasMore"] = true; snapshot["timeline"] = timeline
                return try JSONSerialization.data(withJSONObject: snapshot)
            }
            return try http.defaultResponse(call)
        }
        let model = chat(http)
        defer { model.repository.reset() }
        await model.prepareOpening()
        #expect(model.isOpeningReady && model.openingError == nil)
        #expect(model.timeline.rows.map(\.id) == ["tool"] && model.session.hasOlderItems)
        #expect(http.count("snapshot") == 1 && http.count("timeline") == 0)
    }

    @Test func openingNetworkFailureIsActionableWithoutAnEndlessLoadingPhase() async {
        let http = TestHTTPTransport()
        http.respond = { _ in throw URLError(.notConnectedToInternet) }
        let model = chat(http)
        defer { model.repository.reset() }
        await model.prepareOpening()
        #expect(model.isOpeningPrepared && model.openingError != nil && !model.isOpeningReady)
    }

    @Test func cachedLargeSessionWaitsForOpeningWithoutReloadingHistory() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            guard call.path.hasSuffix("snapshot") else { return try http.defaultResponse(call) }
            var snapshot = try fixtureObject("snapshot")
            var timeline = snapshot["timeline"] as! [String: Any]
            timeline["items"] = try (1...600).map { index in
                try itemObject(id: "reply-\(index)", order: index,
                    text: String(repeating: "Cached paragraph with `src/main.swift:42`.\n\n", count: 50))
            }
            snapshot["timeline"] = timeline
            return try JSONSerialization.data(withJSONObject: snapshot)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        let requests = http.calls.count
        let model = SessionChatModel(session: repo.session(id: "session"), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        // Selecting the page must not construct cached rows before the drawer
        // can begin closing. Preparation is explicitly started after navigation.
        #expect(!model.isOpeningPrepared && model.timeline.rows.isEmpty)
        #expect(http.calls.count == requests)
        await model.prepareOpening()
        #expect(model.isOpeningReady && model.timeline.rows.count == 100)
        #expect(model.timeline.rows.first?.id == "reply-501" && model.timeline.rows.last?.id == "reply-600")
        #expect(model.session.hasOlderItems)
        #expect(http.calls.count == requests)
    }

    @Test func openingPublishesStreamingAndOptimisticHandoffWithoutAScrollAcknowledgement() throws {
        let first: V2TimelineItem = try decode(itemObject(id: "reply", text: "Initial reply"))
        let updated: V2TimelineItem = try decode(itemObject(id: "reply", revision: 2, text: "Initial reply with more content"))
        let echo: V2TimelineItem = try decode(itemObject(id: "echo", order: 2, text: "Question", clientID: "local"))
        let pending = V2PendingMessage(id: "local", content: "Question", attachmentIDs: [])
        let timeline = SessionTimelinePresentation()
        timeline.presentOpening([first], pendingMessages: [pending])
        let row = try #require(timeline.rows.first)
        timeline.stage([updated, echo], animate: false)
        timeline.flush(now: 1)
        timeline.synchronizePending([])
        #expect(timeline.rows.first === row && row.text == "Initial reply with more content")
        #expect(timeline.rows.last?.id == "echo" && timeline.pendingMessages.isEmpty)
    }

    @Test func openingRealtimeReachesPresentationWhileTheViewIsStillScrolling() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let session = repo.session(id: "session")
        let model = SessionChatModel(session: session, repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        await model.prepareOpening()
        #expect(model.isOpeningReady)
        let updates = Task { await model.timeline.run(sessionID: session.id, repository: repo) }
        defer { updates.cancel() }
        try await eventually { session.runtime.isFresh }
        realtime.yield(try event("timeline.item_created", seq: 11, payload: ["item": itemObject(id: "next", order: 2, seq: 11)]))
        try await eventually { model.timeline.rows.contains { $0.id == "next" } }
    }

    @Test func optimisticAttachmentMetadataAndPreviewsSurviveReorderedOrSparseEchoes() throws {
        let store = ChatAttachmentStore()
        let first = ChatAttachment(id: "a", name: "first.png", data: Data([1]), mediaType: "image/png", previewData: Data([11]))
        let second = ChatAttachment(id: "b", name: "second.pdf", data: Data([2, 3]), mediaType: "application/pdf")
        store.remember([first, second], clientID: "message")
        let sparse = V2AttachmentContent(rawContent: .object(["fileId": .string("local:a"), "name": .null]))
        let files = store.resolve([second.content, sparse], clientID: "message")
        #expect(files[0].content.name == "second.pdf" && files[0].previewData == nil)
        #expect(files[1].content.name == "first.png" && files[1].previewData == Data([11]))
        #expect(store.resolve([], clientID: "message").count == 2)
        let unknown = V2AttachmentContent(rawContent: .object(["fileId": .string("another-file")]))
        #expect(store.resolve([unknown], clientID: "message")[0].previewData == nil)
    }

    @Test func previewCacheIsBoundedAndClearedWithTheSession() {
        let store = ChatAttachmentStore(byteLimit: 4)
        let first = V2AttachmentContent(rawContent: .object(["fileId": .string("first")]))
        let second = V2AttachmentContent(rawContent: .object(["fileId": .string("second")]))
        store.cache(Data([1, 2, 3]), for: first)
        store.cache(Data([4, 5, 6]), for: second)
        #expect(store.preview(for: first) == nil && store.preview(for: second) == Data([4, 5, 6]))
        store.clear()
        #expect(store.preview(for: second) == nil)
    }

    @Test func deviceImagesAndUploadedAttachmentsChooseDifferentReadRoutes() {
        let device = V2AttachmentContent(rawContent: .object(["fileId": .string("artifact"), "path": .string("out/chart.png"), "root": .string("/repo")]))
        let uploaded = V2AttachmentContent(rawContent: .object(["fileId": .string("file_upload"), "path": .string("out/chart.png"),
            "openUrl": .string("/api/v2/sessions/session/attachments/file_upload/open"), "mediaType": .string("image/png")]))
        #expect(device.isImage && device.readsFromDevice && device.root == "/repo")
        #expect(uploaded.isImage && !uploaded.readsFromDevice)
        #expect(ChatImageThumbnail.make(data: Data("not an image".utf8)) == nil)
    }

    @Test func deviceThumbnailUsesFSReadAndItsCachedPreviewWorksOffline() async throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        _ = try await repo.load(sessionId: "session")
        let session = repo.session(id: "session")
        let connector = try #require(session.metadata?.connectorId)
        let model = SessionChatModel(session: session, repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)),
            files: .init(connectorAPI: V2ConnectorAPI(transport: http), serverURL: URL(string: "https://example.test")!))
        http.respond = { call in
            #expect(call.path == "/connectors/\(connector)/fs/read" && call.method == .post)
            #expect(call.query.contains { $0.name == "root" && $0.value == "/custom-root" })
            #expect(call.body?["path"] == .string("chart.png"))
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": ["name": "chart.png", "size": bytes.length,
                "downloadUrl": "/api/v2/connectors/\(connector)/fs/transfers/image"]])
        }
        http.onDownload = { _ in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try (bytes as Data).write(to: url)
            return url
        }
        let file = V2AttachmentContent(rawContent: .object(["fileId": .string("device-image"),
            "path": .string("chart.png"), "root": .string("/custom-root")]))
        let preview = try #require(await model.thumbnail(for: file))
        #expect(!preview.isEmpty && http.count("fs/read") == 1)
        repo.updateConnectivity(.init(availability: .offline))
        #expect(try await model.thumbnail(for: file) == preview)
        #expect(http.count("fs/read") == 1)
    }

    @Test func attachmentSendIsVisibleBeforeUploadAndUploadFailureNeverSendsAMessage() async throws {
        let http = TestHTTPTransport(); let repo = repository(transport: http); let gate = TestGate()
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }; defer { connection.cancel() }
        try await eventually { model.canSend }
        let timeline = SessionTimelinePresentation()
        let presenting = Task { await timeline.run(sessionID: model.id, repository: repo) }
        defer { presenting.cancel() }
        model.draft = "Photo"; model.composer.attachments = [.init(name: "photo.png", data: Data([1]), mediaType: "image/png", previewData: Data([2]))]
        var uploading = false
        let send = Task { await model.sendDraft { _ in uploading = true; await gate.wait(); throw URLError(.timedOut) } }
        try await eventually { uploading && timeline.pendingMessages.count == 1 }
        #expect(model.draft.isEmpty && timeline.pendingMessages[0].attachments.first?.previewData == Data([2]))
        #expect(http.count("messages") == 0)
        gate.release(); let pending = try #require(await send.value)
        guard case .rejected = pending.delivery else { Issue.record("Upload failure must be a definite unsent message"); return }
        #expect(model.draft == "Photo" && model.composer.attachments.count == 1 && http.count("messages") == 0)
    }

    @Test func sendingClearsImmediatelyAndAFailedWriteRestoresTheAttachmentDraft() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI(), gate = TestGate()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let session = repo.session(id: "session"), connection = Task { await repo.session(id: "session").connect() }
        defer { connection.cancel() }
        try await eventually { session.canSend }
        http.respond = { call in
            if call.path.hasSuffix("messages") { await gate.wait(); throw URLError(.timedOut) }
            return try http.defaultResponse(call)
        }
        let file = ChatAttachment(name: "photo.png", data: Data([1]), mediaType: "image/png", previewData: Data([2]))
        session.draft = "Look"; session.composer.attachments = [file]; session.draftAttachmentIDs = ["file_uploaded"]
        let send = Task { await session.sendDraft() }
        try await eventually { http.count("messages") == 1 }
        #expect(session.draft.isEmpty && session.composer.attachments.isEmpty)
        #expect(session.pendingMessages.first?.attachments.first?.previewData == Data([2]))
        gate.release(); _ = await send.value
        #expect(session.draft == "Look" && session.composer.attachments == [file])
        #expect(http.count("messages") == 1)
    }

    @Test func echoCannotEraseANewDraftEvenWhenItsTextMatchesTheSentMessage() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI(), gate = TestGate()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let session = repo.session(id: "session"), connection = Task { await repo.session(id: "session").connect() }
        defer { connection.cancel() }
        try await eventually { session.canSend }
        http.respond = { call in if call.path.hasSuffix("messages") { await gate.wait() }; return try http.defaultResponse(call) }
        session.draft = "Same text"
        let send = Task { await session.sendDraft() }
        try await eventually { http.count("messages") == 1 }
        let pending = try #require(session.pendingMessages.first)
        session.draft = "Same text"
        realtime.yield(try event("timeline.item_created", seq: 11, payload: ["item": itemObject(id: "echo", order: 2, seq: 11, clientID: pending.id)]))
        try await eventually { pending.delivery == .confirmed }
        gate.release(); _ = await send.value
        #expect(session.draft == "Same text")
    }

    @Test func attachmentServerPixelSizeRequiresPositiveWholeNumbers() {
        let sized = V2AttachmentContent(rawContent: .object(["fileId": .string("file_uploaded"),
            "width": .number(1179), "height": .number(2556)]))
        #expect(sized.serverPixelSize == CGSize(width: 1179, height: 2556))
        let absent = V2AttachmentContent(rawContent: .object(["fileId": .string("file_uploaded")]))
        #expect(absent.serverPixelSize == nil)
        let invalid: [[String: JSONValue]] = [
            ["width": .number(0), "height": .number(10)],
            ["width": .number(-3), "height": .number(10)],
            ["width": .string("100"), "height": .number(10)],
            ["width": .number(100.5), "height": .number(10)],
            ["width": .number(100)],
            ["width": .bool(true), "height": .number(10)],
            ["width": .number(10), "height": .number(.infinity)],
        ]
        for raw in invalid {
            #expect(V2AttachmentContent(rawContent: .object(raw)).serverPixelSize == nil)
        }
    }

    @Test func optimisticAttachmentsCarryPixelDimensionsAndTheServerEchoWins() throws {
        let attachment = ChatAttachment(id: "a", name: "photo.png", data: Data([1]), mediaType: "image/png",
            pixelSize: CGSize(width: 40, height: 80))
        #expect(attachment.content.serverPixelSize == CGSize(width: 40, height: 80))
        let store = ChatAttachmentStore()
        store.remember([attachment], clientID: "message")
        let optimistic = try #require(store.resolve([], clientID: "message").first)
        #expect(optimistic.content.serverPixelSize == CGSize(width: 40, height: 80))
        let echo = V2AttachmentContent(rawContent: .object(["fileId": .string("local:a"),
            "width": .number(1179), "height": .number(2556)]))
        let merged = try #require(store.resolve([echo], clientID: "message").first)
        #expect(merged.content.serverPixelSize == CGSize(width: 1179, height: 2556))
        // An older server echo without dimensions keeps the locally decoded sizes.
        let legacy = V2AttachmentContent(rawContent: .object(["fileId": .string("local:a"), "name": .string("photo.png")]))
        #expect(store.resolve([legacy], clientID: "message").first?.content.serverPixelSize == CGSize(width: 40, height: 80))
    }

    @Test func attachmentUploadForwardsPickerPixelDimensions() async throws {
        let http = TestHTTPTransport()
        let service = V2AttachmentService(attachmentAPI: V2AttachmentAPI(transport: http))
        let attachment = ChatAttachment(id: "a", name: "photo.png", data: Data([1]), mediaType: "image/png",
            previewData: Data([2]), pixelSize: CGSize(width: 1179, height: 2556))
        _ = try await service.upload(sessionId: "session", attachments: [attachment.local])
        let upload = try #require(http.uploads.first)
        #expect(upload.path == "/sessions/session/attachments")
        #expect(upload.files.count == 1)
        #expect(upload.files.first?.pixelWidth == 1179 && upload.files.first?.pixelHeight == 2556)
        let document = ChatAttachment(name: "notes.pdf", data: Data([3]), mediaType: "application/pdf")
        #expect(document.local.pixelWidth == nil && document.local.pixelHeight == nil)
    }

    @Test func previewVersionAdvancesWithPreviewWritesAndResolveExposesIt() throws {
        let store = ChatAttachmentStore()
        let attachment = ChatAttachment(id: "a", name: "photo.png", data: Data([1]), mediaType: "image/png", previewData: Data([2]))
        store.remember([attachment], clientID: "message")
        let remembered = try #require(store.resolve([attachment.content], clientID: "message").first)
        #expect(remembered.previewVersion == 1 && remembered.previewData == Data([2]))
        store.cache(Data([3]), for: attachment.content)
        let cached = try #require(store.resolve([attachment.content], clientID: "message").first)
        #expect(cached.previewVersion == 2 && cached.previewData == Data([3]))
    }

    @Test func inlineAttachmentEncodingCarriesPixelDimensionsOnlyWhenPresent() throws {
        let sized = V2InlineAttachment(fileId: "file_1", name: "photo.png", mediaType: "image/png", size: 3,
            width: 1179, height: 2556, sha256: "sha", contentBase64: "AQID")
        let sizedJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(sized))
        #expect(sizedJSON["width"] == .number(1179) && sizedJSON["height"] == .number(2556))
        let plain = V2InlineAttachment(fileId: "file_2", name: "notes.pdf", mediaType: "application/pdf", size: 3,
            sha256: nil, contentBase64: "AQID")
        let plainJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(plain))
        #expect(plainJSON["width"] == nil && plainJSON["height"] == nil)
    }

    @Test func creationCarriesPickerPixelDimensionsIntoTheInlineAttachment() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            #expect(call.path == "/sessions/create-and-start")
            return try fixtureData("session")
        }
        let service = V2SessionCreationService(sessionAPI: V2SessionAPI(transport: http))
        let attachment = V2LocalAttachment(fileId: "file_1", name: "photo.png", mediaType: "image/png",
            data: Data([1, 2, 3]), sha256: nil, pixelWidth: 1179, pixelHeight: 2556)
        _ = try await service.createAndStart(connectorId: "device", projectId: "project", runtime: "claude",
            title: nil, cwd: nil, content: "看这个", selections: [:], attachments: [attachment], clientMessageId: "client")
        let body = try #require(http.calls.first?.body)
        guard case let .array(attachments)? = body["attachments"], let inline = attachments.first else {
            Issue.record("The creation request must carry the inline attachment")
            return
        }
        #expect(inline["fileId"] == .string("file_1"))
        #expect(inline["width"] == .number(1179) && inline["height"] == .number(2556))
    }
}
