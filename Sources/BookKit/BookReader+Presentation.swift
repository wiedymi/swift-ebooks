import Foundation

extension BookReader {
    func updateViewport(size: CGSize) {
        guard presentationEngine.requiresReflowBridge,
              size.width > 1,
              size.height > 1,
              !book.readingOrder.isEmpty
        else {
            return
        }

        let viewport = Viewport(width: size.width, height: size.height)
        if let lastViewport,
           abs(lastViewport.width - viewport.width) < 1,
           abs(lastViewport.height - viewport.height) < 1
        {
            return
        }

        lastViewport = viewport
        viewportTask?.cancel()
        viewportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            do {
                let position = await renderer.currentPosition()
                let preferences = await renderer.preferences()
                try await renderer.renderChapter(
                    at: position.spineIndex,
                    viewport: viewport,
                    theme: preferences.theme,
                    typography: preferences.typography
                )
                try await renderer.go(to: position)
                await refreshState()
            } catch {
                report(error)
            }
        }
    }

    func updateFixedPageVisibility(_ visibility: FixedPageVisibility) async {
        visiblePageIndices = visibility.pageIndices
        do {
            try await renderer.go(to: visibility.locator.position)
            await refreshState()
        } catch {
            report(error)
        }
    }

    func activateFixedPageLink(_ activation: FixedPageLinkActivation) async {
        do {
            _ = try await renderer.handlePageLink(
                activation.link,
                onPageAt: activation.pageIndex
            )
            await refreshState()
        } catch {
            report(error)
        }
    }

    #if canImport(PDFKit) && !os(tvOS)
    func updatePDFSelection(_ parts: [PDFTextSelection]) {
        guard let first = parts.first else {
            guard selection != nil else { return }
            selection = nil
            eventHub.yield(.selectionCleared)
            return
        }
        let locations = parts.map { part in
            book.locator(for: Position(spineIndex: part.pageIndex, progression: 0, textRange: part.range))
        }
        let bounds = parts.reduce(CGRect.null) { $0.union($1.bounds) }
        let selection = ReaderSelection(range: SelectionRange(start: first.range.start, end: first.range.end, bounds: bounds),
            text: parts.map { $0.range.quote }.joined(separator: "\n"), locators: locations)
        guard self.selection != selection else { return }
        self.selection = selection
        eventHub.yield(.selectionChanged(selection))
    }
    #endif

    func updatePDFPage(_ index: Int) async {
        guard index != position.spineIndex else { return }
        do {
            try await renderer.go(to: Position(spineIndex: index, progression: 0))
            await refreshState()
        } catch {
            report(error)
        }
    }

    func activatePDFLink(_ url: URL) async {
        let index = min(max(position.spineIndex, 0), max(book.readingOrder.count - 1, 0))
        let href = book.readingOrder.indices.contains(index) ? book.readingOrder[index].href : ""
        do {
            _ = try await renderer.handleLink(
                url,
                context: LinkContext(currentChapterHref: href)
            )
            await refreshState()
        } catch {
            report(error)
        }
    }

    func perform(_ operation: @escaping @MainActor (BookReader) async throws -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await operation(self)
            } catch {
                report(error)
            }
        }
    }

    func startEventSubscriptions() {
        let navigatorEvents = renderer.events
        navigatorEventTask = Task { @MainActor [weak self] in
            for await event in navigatorEvents {
                guard let self else { return }
                handle(event)
            }
        }

        guard let player else { return }
        let playbackEvents = player.events
        playbackEventTask = Task { @MainActor [weak self] in
            for await event in playbackEvents {
                guard let self else { return }
                handle(event)
            }
        }
    }

    func handle(_ event: NavigatorEvent) {
        switch event {
        case .ready:
            break
        case let .locatorChanged(locator):
            self.locator = locator
            position = locator.position
            eventHub.yield(.locatorChanged(locator))
        case let .paginationChanged(pageMap):
            self.pageMap = pageMap
            pageCount = pageMap.pageCount
            eventHub.yield(.paginationChanged(pageMap))
        case .selectionCleared:
            guard selection != nil else { return }
            selection = nil
            eventHub.yield(.selectionCleared)
        case let .selectionChanged(selection):
            guard self.selection != selection else { return }
            self.selection = selection
            eventHub.yield(.selectionChanged(selection))
        case let .contentHeightChanged(height):
            contentHeight = height
            eventHub.yield(.contentHeightChanged(height))
        case let .historyChanged(canGoBack, canGoForward):
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            eventHub.yield(.historyChanged(canGoBack: canGoBack, canGoForward: canGoForward))
        case .readingModeChanged:
            break
        case let .preferencesChanged(preferences):
            self.preferences = preferences
            eventHub.yield(.preferencesChanged(preferences))
        case let .accessibilityChanged(accessibility):
            self.accessibility = accessibility
            eventHub.yield(.accessibilityChanged(accessibility))
        case let .linkActivated(url, kind, action):
            eventHub.yield(.linkActivated(url: url, kind: kind, action: action))
        case let .decorationTapped(event):
            eventHub.yield(.decorationTapped(event))
        case let .bridgeMessage(name, payload):
            eventHub.yield(.bridgeMessage(name: name, payload: payload))
        case let .error(error):
            report(error)
        }
    }

    func handle(_ event: AudiobookPlaybackEvent) {
        switch event {
        case let .ready(snapshot),
             let .stateChanged(snapshot),
             let .positionChanged(snapshot):
            applyPlayback(snapshot)
        case let .trackChanged(index, title):
            eventHub.yield(.playbackTrackChanged(index: index, title: title))
        case .ended:
            eventHub.yield(.playbackEnded)
        case let .error(error):
            report(error)
        }
    }

    func applyPlayback(_ snapshot: AudiobookPlaybackSnapshot) {
        let playback = BookReaderPlaybackState(snapshot)
        self.playback = playback
        position = snapshot.position
        locator = book.locator(for: snapshot.position)
        eventHub.yield(.playbackChanged(playback))
        eventHub.yield(.locatorChanged(locator))
    }

    func refreshState() async {
        let position = await renderer.currentPosition()
        self.position = position
        locator = book.locator(for: position)
        preferences = await renderer.preferences()
        bookmarks = await renderer.bookmarks()
        accessibility = renderer.accessibility()
        canGoBack = renderer.canGoBack()
        canGoForward = renderer.canGoForward()
        pageCount = renderer.pageCount()
        pageMap = renderer.pageMap()
        if let player {
            applyPlayback(player.currentSnapshot())
        }
    }

    func requirePlayer() throws -> AudiobookPlayer {
        guard let player else {
            throw BookError.renderingFailed("Playback is only available for audiobooks")
        }
        return player
    }

    func report(_ error: Error) {
        let bookError = BookError.from(error)
        lastError = bookError
        eventHub.yield(.error(bookError))
    }
}
