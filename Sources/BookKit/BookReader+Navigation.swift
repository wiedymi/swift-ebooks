import Foundation

// MARK: - Navigation

public extension BookReader {
    /// Moves to the next page or audiobook track.
    func next() async throws {
        if let player {
            _ = try await player.nextTrack()
            try await renderer.go(to: player.currentPosition())
        } else {
            try await renderer.nextPage()
        }
        await refreshState()
    }

    /// Moves to the previous page or audiobook track.
    func previous() async throws {
        if let player {
            _ = try await player.previousTrack()
            try await renderer.go(to: player.currentPosition())
        } else {
            try await renderer.previousPage()
        }
        await refreshState()
    }

    /// Navigates to a publication position.
    func go(to position: Position) async throws {
        if let player {
            try await player.seek(to: position)
        }
        try await renderer.go(to: position)
        await refreshState()
    }

    /// Navigates to a portable locator.
    func go(to locator: Locator) async throws {
        try await renderer.go(to: locator)
        if let player {
            try await player.seek(to: locator.position)
        }
        await refreshState()
    }

    /// Navigates to an item from the table of contents, landmarks, or page list.
    func go(to navigationItem: TOCNode) async throws {
        guard let destination = book.locator(forNavigationHref: navigationItem.href) else {
            throw BookError.navigationFailed(
                "Unable to resolve navigation destination: \(navigationItem.href)"
            )
        }
        try await go(to: destination)
    }

    /// Moves backward through reader navigation history.
    ///
    /// - Returns: The destination, or `nil` when no backward entry exists.
    @discardableResult
    func goBack() async throws -> Locator? {
        guard let destination = try await renderer.goBack() else { return nil }
        if let player {
            try await player.seek(to: destination.position)
        }
        await refreshState()
        return destination
    }

    /// Moves forward through reader navigation history.
    ///
    /// - Returns: The destination, or `nil` when no forward entry exists.
    @discardableResult
    func goForward() async throws -> Locator? {
        guard let destination = try await renderer.goForward() else { return nil }
        if let player {
            try await player.seek(to: destination.position)
        }
        await refreshState()
        return destination
    }
}

// MARK: - Preferences and accessibility

public extension BookReader {
    /// Replaces all reading preferences and persists the result.
    func setPreferences(_ preferences: ReaderPreferences) async throws {
        try await renderer.setPreferences(preferences)
        await refreshState()
    }

    /// Changes between scrolling and paginated reading.
    func setReadingMode(_ mode: ReadingMode) async throws {
        try await renderer.setReadingMode(mode)
        await refreshState()
    }

    /// Changes the active reader theme.
    func setTheme(_ theme: Theme) async throws {
        try await renderer.setTheme(theme)
        await refreshState()
    }

    /// Changes reader typography.
    func setTypography(_ typography: Typography) async throws {
        try await renderer.setTypography(typography)
        await refreshState()
    }

    /// Replaces the active accessibility settings.
    func setAccessibility(_ accessibility: ReaderAccessibilitySettings) async throws {
        try await renderer.setAccessibility(accessibility)
        await refreshState()
    }
}

// MARK: - Bookmarks

public extension BookReader {
    /// Adds a bookmark at the current position.
    ///
    /// - Parameter note: Optional user-authored text stored with the bookmark.
    /// - Returns: The newly persisted bookmark.
    @discardableResult
    func addBookmark(note: String? = nil) async throws -> ReadingBookmark {
        let bookmark = try await renderer.addBookmark(note: note)
        await refreshState()
        return bookmark
    }

    /// Replaces the note attached to a bookmark.
    func updateBookmark(id: UUID, note: String?) async throws {
        try await renderer.updateBookmark(id: id, note: note)
        await refreshState()
    }

    /// Removes a bookmark.
    func removeBookmark(id: UUID) async throws {
        try await renderer.removeBookmark(id: id)
        await refreshState()
    }
}

// MARK: - Reflow extensions

public extension BookReader {
    /// Replaces a named group of rendered decorations.
    func setDecorations(
        _ decorations: [Decoration],
        in group: DecorationGroup
    ) async throws {
        guard decorations.isEmpty || capabilities.contains(.textDecorations) else {
            throw BookError.renderingFailed("This presentation does not support text decorations")
        }
        try await renderer.setDecorations(decorations, in: group)
        self.decorations = renderer.allDecorations()
    }

    /// Clears one decoration group, or every group when `group` is `nil`.
    func clearDecorations(in group: DecorationGroup? = nil) async throws {
        try await renderer.clearDecorations(in: group)
        decorations = renderer.allDecorations()
    }

    /// Calls a command provided by a trusted reflow script plug-in.
    ///
    /// - Returns: The plug-in's structured response.
    func callBridgeCommand(
        _ name: String,
        payload: BridgeValue = .null
    ) async throws -> BridgeValue {
        try await renderer.callBridgeCommand(name, payload: payload)
    }
}

public extension BookReader {
    func search(_ query: String, options: SearchOptions = .init()) async throws -> [SearchResult] {
        try await book.search(query, options: options)
    }

    func clearSelection() async throws {
        #if canImport(PDFKit) && !os(tvOS)
        pdfView?.clearSelection()
        #endif
        try await renderer.clearSelection()
        if selection != nil {
            selection = nil
            eventHub.yield(.selectionCleared)
        }
    }

    /// Returns the active marks so the app can edit or persist them.
    func decorations(in group: DecorationGroup) -> [Decoration] {
        renderer.decorations(in: group)
    }

    /// Adds marks for selected text. The app owns storage of the returned values.
    @discardableResult
    func highlightSelection(id: String = UUID().uuidString, style: DecorationStyle = .default(for: .highlight)) async throws -> [Decoration] {
        guard let selection, !selection.locators.isEmpty else { throw BookError.navigationFailed("No text is selected") }
        let added = selection.locators.enumerated().map { index, locator in
            Decoration(id: index == 0 ? id : "\(id)-\(index)", group: .highlight, locator: locator, style: style)
        }
        let ids = Set(added.map(\.id))
        var marks = decorations(in: .highlight).filter { !ids.contains($0.id) }
        marks += added
        try await setDecorations(marks, in: .highlight)
        return added
    }
}
