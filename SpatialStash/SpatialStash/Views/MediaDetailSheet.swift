/*
 Spatial Stash - Media Detail Sheet

 Two-tab sheet for viewing and editing image/video metadata.
 Tab 1 (Info): read-only file metadata, associations, stats.
 Tab 2 (Edit): editable fields with save/cancel, plus delete.
 Fetches full detail on-demand when the sheet opens.
 */

import SwiftUI

// MARK: - Media Type Abstraction

/// Identifies whether this sheet is for an image or a scene/video.
enum MediaDetailType {
    case image(stashId: String)
    case scene(stashId: String)

    var stashId: String {
        switch self {
        case .image(let id): return id
        case .scene(let id): return id
        }
    }
}

// MARK: - Sheet View

struct MediaDetailSheet: View {
    let mediaType: MediaDetailType
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var isLoading = true
    @State private var loadError: String?

    // Detail data (loaded on appear)
    @State private var imageDetail: ImageDetail?
    @State private var sceneDetail: SceneDetail?

    // Edit state
    @State private var editTitle: String = ""
    @State private var editCode: String = ""
    @State private var editDate: String = ""
    @State private var editDetails: String = ""
    @State private var editCreator: String = "" // photographer or director
    @State private var editRating100: Int? = nil
    @State private var editOrganized: Bool = false
    @State private var editUrls: [String] = []
    @State private var editStudio: MediaStudio? = nil
    @State private var editPerformers: [MediaPerformer] = []
    @State private var editTags: [MediaTag] = []
    @State private var editGalleries: [MediaGalleryRef] = []

    // Search state for pickers
    @State private var tagSearchText: String = ""
    @State private var tagSearchResults: [MediaTag] = []
    @State private var performerSearchText: String = ""
    @State private var performerSearchResults: [MediaPerformer] = []
    @State private var studioSearchText: String = ""
    @State private var studioSearchResults: [MediaStudio] = []

    // Save / delete state
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false

    // O counter state
    @State private var isUpdatingOCounter = false

    /// Called after a successful delete so the parent can remove the item and navigate away.
    var onDelete: (() -> Void)?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .foregroundColor(.secondary)
                        Button("Retry") { Task { await loadDetail() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        Picker("Mode", selection: $selectedTab) {
                            Label("Info", systemImage: "info.circle").tag(0)
                            Label("Edit", systemImage: "pencil").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        if selectedTab == 0 {
                            infoTab
                        } else {
                            editTab
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 500, idealHeight: 650)
        .task { await loadDetail() }
        .confirmationDialog(
            "Delete Item",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove from Stash", role: .destructive) {
                Task { await performDelete(deleteFile: false) }
            }
            Button("Delete File from Disk", role: .destructive) {
                Task { await performDelete(deleteFile: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone. Removing from Stash keeps the file on disk. Deleting from disk permanently removes the file.")
        }
    }

    private var navigationTitle: String {
        switch mediaType {
        case .image: return "Image Details"
        case .scene: return "Video Details"
        }
    }

    // MARK: - Info Tab

    private var infoTab: some View {
        List {
            // File section
            Section("File") {
                if let path = filePath {
                    LabeledContent("Path", value: path)
                }
                if let w = fileWidth, let h = fileHeight {
                    LabeledContent("Dimensions", value: "\(w) x \(h)")
                }
                if let size = fileSize {
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let format = fileFormat {
                    LabeledContent("Format", value: format)
                }
                // Video-specific
                if let detail = sceneDetail {
                    if let codec = detail.videoCodec {
                        LabeledContent("Video Codec", value: codec)
                    }
                    if let codec = detail.audioCodec {
                        LabeledContent("Audio Codec", value: codec)
                    }
                    if let fps = detail.frameRate {
                        LabeledContent("Frame Rate", value: String(format: "%.2f fps", fps))
                    }
                    if let br = detail.bitrate {
                        LabeledContent("Bitrate", value: formatBitrate(br))
                    }
                    if let dur = detail.duration {
                        LabeledContent("Duration", value: formatDuration(dur))
                    }
                }
            }

            // Details section
            Section("Details") {
                if let title = currentTitle, !title.isEmpty {
                    LabeledContent("Title", value: title)
                }
                if let code = currentCode, !code.isEmpty {
                    LabeledContent("Code", value: code)
                }
                if let date = currentDate, !date.isEmpty {
                    LabeledContent("Date", value: date)
                }
                if let creator = currentCreator, !creator.isEmpty {
                    LabeledContent(creatorLabel, value: creator)
                }
                if let details = currentDetails, !details.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Details")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(details)
                    }
                }
            }

            // Associations section
            Section("Associations") {
                if let studio = currentStudio {
                    LabeledContent("Studio", value: studio.name)
                }
                if !currentPerformers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Performers")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(currentPerformers) { performer in
                                Text(performer.name)
                                    .font(.callout)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                    }
                }
                if !currentTags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(currentTags) { tag in
                                Text(tag.name)
                                    .font(.callout)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                    }
                }
                if !currentGalleries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Galleries")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        ForEach(currentGalleries) { gallery in
                            Text(gallery.title ?? "Gallery \(gallery.id)")
                                .font(.callout)
                        }
                    }
                }
                if let groups = currentGroups, !groups.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Groups")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        ForEach(groups) { group in
                            Text(group.name)
                                .font(.callout)
                        }
                    }
                }
            }

            // Stats section
            Section("Stats") {
                ratingDisplay
                oCounterDisplay
                if let detail = sceneDetail {
                    if let count = detail.playCount {
                        LabeledContent("Play Count", value: "\(count)")
                    }
                    if let dur = detail.playDuration, dur > 0 {
                        LabeledContent("Play Duration", value: formatDuration(dur))
                    }
                }
                LabeledContent("Organized", value: currentOrganized ? "Yes" : "No")
            }

            // URLs section
            if !currentUrls.isEmpty {
                Section("URLs") {
                    ForEach(currentUrls, id: \.self) { url in
                        Text(url)
                            .font(.callout)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Edit Tab

    private var editTab: some View {
        List {
            Section("Details") {
                TextField("Title", text: $editTitle)
                TextField("Code", text: $editCode)
                TextField("Date (YYYY-MM-DD)", text: $editDate)
                TextField(creatorLabel, text: $editCreator)

                VStack(alignment: .leading) {
                    Text("Details")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextEditor(text: $editDetails)
                        .frame(minHeight: 80)
                }
            }

            Section("Rating & O Counter") {
                ratingEditor
                oCounterEditor
                Toggle("Organized", isOn: $editOrganized)
            }

            Section("Studio") {
                if let studio = editStudio {
                    HStack {
                        Text(studio.name)
                        Spacer()
                        Button {
                            editStudio = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Search studios...", text: $studioSearchText)
                        .textInputAutocapitalization(.never)
                }
                .onChange(of: studioSearchText) { _, query in
                    Task { await searchStudios(query: query) }
                }
                ForEach(studioSearchResults) { studio in
                    Button {
                        editStudio = studio
                        studioSearchText = ""
                        studioSearchResults = []
                    } label: {
                        Text(studio.name)
                    }
                }
            }

            Section("Performers") {
                FlowLayout(spacing: 6) {
                    ForEach(editPerformers) { performer in
                        HStack(spacing: 4) {
                            Text(performer.name)
                            Button {
                                editPerformers.removeAll { $0.id == performer.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                HStack {
                    TextField("Search performers...", text: $performerSearchText)
                        .textInputAutocapitalization(.never)
                }
                .onChange(of: performerSearchText) { _, query in
                    Task { await searchPerformers(query: query) }
                }
                ForEach(performerSearchResults) { performer in
                    Button {
                        if !editPerformers.contains(where: { $0.id == performer.id }) {
                            editPerformers.append(performer)
                        }
                        performerSearchText = ""
                        performerSearchResults = []
                    } label: {
                        Text(performer.name)
                    }
                }
            }

            Section("Tags") {
                FlowLayout(spacing: 6) {
                    ForEach(editTags) { tag in
                        HStack(spacing: 4) {
                            Text(tag.name)
                            Button {
                                editTags.removeAll { $0.id == tag.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                HStack {
                    TextField("Search tags...", text: $tagSearchText)
                        .textInputAutocapitalization(.never)
                }
                .onChange(of: tagSearchText) { _, query in
                    Task { await searchTags(query: query) }
                }
                ForEach(tagSearchResults) { tag in
                    Button {
                        if !editTags.contains(where: { $0.id == tag.id }) {
                            editTags.append(tag)
                        }
                        tagSearchText = ""
                        tagSearchResults = []
                    } label: {
                        Text(tag.name)
                    }
                }
            }

            Section("URLs") {
                ForEach(editUrls.indices, id: \.self) { index in
                    HStack {
                        TextField("URL", text: $editUrls[index])
                            .textInputAutocapitalization(.never)
                        Button {
                            editUrls.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    editUrls.append("")
                } label: {
                    Label("Add URL", systemImage: "plus")
                }
            }

            // Save button
            Section {
                if let error = saveError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.callout)
                }
                Button {
                    Task { await saveChanges() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save Changes")
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving)
            }

            // Delete section
            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                        } else {
                            Label("Delete", systemImage: "trash")
                                .foregroundColor(.red)
                        }
                        Spacer()
                    }
                }
                .disabled(isDeleting)
            }
        }
    }

    // MARK: - Rating Display / Editor

    private var ratingDisplay: some View {
        HStack {
            Text("Rating")
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= currentStarRating ? "star.fill" : "star")
                        .foregroundColor(star <= currentStarRating ? .yellow : .gray)
                        .font(.callout)
                }
            }
        }
    }

    private var ratingEditor: some View {
        HStack {
            Text("Rating")
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        editRating100 = ImageFilterCriteria.ratingToAPI(star)
                    } label: {
                        Image(systemName: star <= editStarRating ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundColor(star <= editStarRating ? .yellow : .gray)
                    }
                    .buttonStyle(.borderless)
                }
                if editRating100 != nil {
                    Button {
                        editRating100 = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - O Counter Display / Editor

    private var oCounterDisplay: some View {
        LabeledContent("O Count", value: "\(currentOCounter)")
    }

    private var oCounterEditor: some View {
        HStack {
            Text("O Count")
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 12) {
                Button {
                    Task { await decrementOCounter() }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(currentOCounter <= 0 || isUpdatingOCounter)

                if isUpdatingOCounter {
                    ProgressView()
                        .frame(minWidth: 30)
                } else {
                    Text("\(currentOCounter)")
                        .font(.title3.monospacedDigit())
                        .frame(minWidth: 30)
                }

                Button {
                    Task { await incrementOCounter() }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(isUpdatingOCounter)
            }
        }
    }

    // MARK: - Computed Properties for current detail

    private var currentTitle: String? {
        switch mediaType {
        case .image: return imageDetail?.title
        case .scene: return sceneDetail?.title
        }
    }

    private var currentCode: String? {
        switch mediaType {
        case .image: return imageDetail?.code
        case .scene: return sceneDetail?.code
        }
    }

    private var currentDate: String? {
        switch mediaType {
        case .image: return imageDetail?.date
        case .scene: return sceneDetail?.date
        }
    }

    private var currentDetails: String? {
        switch mediaType {
        case .image: return imageDetail?.details
        case .scene: return sceneDetail?.details
        }
    }

    private var currentCreator: String? {
        switch mediaType {
        case .image: return imageDetail?.photographer
        case .scene: return sceneDetail?.director
        }
    }

    private var creatorLabel: String {
        switch mediaType {
        case .image: return "Photographer"
        case .scene: return "Director"
        }
    }

    private var currentStudio: MediaStudio? {
        switch mediaType {
        case .image: return imageDetail?.studio
        case .scene: return sceneDetail?.studio
        }
    }

    private var currentPerformers: [MediaPerformer] {
        switch mediaType {
        case .image: return imageDetail?.performers ?? []
        case .scene: return sceneDetail?.performers ?? []
        }
    }

    private var currentTags: [MediaTag] {
        switch mediaType {
        case .image: return imageDetail?.tags ?? []
        case .scene: return sceneDetail?.tags ?? []
        }
    }

    private var currentGalleries: [MediaGalleryRef] {
        switch mediaType {
        case .image: return imageDetail?.galleries ?? []
        case .scene: return sceneDetail?.galleries ?? []
        }
    }

    private var currentGroups: [MediaGroupRef]? {
        switch mediaType {
        case .image: return nil
        case .scene: return sceneDetail?.groups
        }
    }

    private var currentUrls: [String] {
        switch mediaType {
        case .image: return imageDetail?.urls ?? []
        case .scene: return sceneDetail?.urls ?? []
        }
    }

    private var currentOrganized: Bool {
        switch mediaType {
        case .image: return imageDetail?.organized ?? false
        case .scene: return sceneDetail?.organized ?? false
        }
    }

    private var currentStarRating: Int {
        let rating = (imageDetail?.rating100 ?? sceneDetail?.rating100) ?? 0
        return rating > 0 ? ImageFilterCriteria.ratingFromAPI(rating) : 0
    }

    private var editStarRating: Int {
        guard let r = editRating100 else { return 0 }
        return ImageFilterCriteria.ratingFromAPI(r)
    }

    private var currentOCounter: Int {
        switch mediaType {
        case .image: return imageDetail?.oCounter ?? 0
        case .scene: return sceneDetail?.oCounter ?? 0
        }
    }

    private var filePath: String? {
        switch mediaType {
        case .image: return imageDetail?.filePath
        case .scene: return sceneDetail?.filePath
        }
    }

    private var fileSize: Int64? {
        switch mediaType {
        case .image: return imageDetail?.fileSize
        case .scene: return sceneDetail?.fileSize
        }
    }

    private var fileFormat: String? {
        switch mediaType {
        case .image: return imageDetail?.format
        case .scene: return sceneDetail?.format
        }
    }

    private var fileWidth: Int? {
        switch mediaType {
        case .image: return imageDetail?.width
        case .scene: return sceneDetail?.width
        }
    }

    private var fileHeight: Int? {
        switch mediaType {
        case .image: return imageDetail?.height
        case .scene: return sceneDetail?.height
        }
    }

    // MARK: - Data Loading

    private func loadDetail() async {
        isLoading = true
        loadError = nil

        do {
            let client = appModel.apiClient
            switch mediaType {
            case .image(let id):
                imageDetail = try await client.fetchImageDetail(id: id)
                populateEditFields(from: imageDetail!)
            case .scene(let id):
                sceneDetail = try await client.fetchSceneDetail(id: id)
                populateEditFields(from: sceneDetail!)
            }
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    private func populateEditFields(from detail: ImageDetail) {
        editTitle = detail.title ?? ""
        editCode = detail.code ?? ""
        editDate = detail.date ?? ""
        editDetails = detail.details ?? ""
        editCreator = detail.photographer ?? ""
        editRating100 = detail.rating100
        editOrganized = detail.organized
        editUrls = detail.urls
        editStudio = detail.studio
        editPerformers = detail.performers
        editTags = detail.tags
        editGalleries = detail.galleries
    }

    private func populateEditFields(from detail: SceneDetail) {
        editTitle = detail.title ?? ""
        editCode = detail.code ?? ""
        editDate = detail.date ?? ""
        editDetails = detail.details ?? ""
        editCreator = detail.director ?? ""
        editRating100 = detail.rating100
        editOrganized = detail.organized
        editUrls = detail.urls
        editStudio = detail.studio
        editPerformers = detail.performers
        editTags = detail.tags
        editGalleries = detail.galleries
    }

    // MARK: - Search

    private func searchTags(query: String) async {
        guard !query.isEmpty else { tagSearchResults = []; return }
        do {
            let result = try await appModel.apiClient.findTags(query: query, perPage: 20)
            tagSearchResults = result.tags
                .map { MediaTag(id: $0.id, name: $0.name) }
                .filter { tag in !editTags.contains(where: { $0.id == tag.id }) }
        } catch {
            tagSearchResults = []
        }
    }

    private func searchPerformers(query: String) async {
        guard !query.isEmpty else { performerSearchResults = []; return }
        do {
            let result = try await appModel.apiClient.findPerformers(query: query, perPage: 20)
            performerSearchResults = result.performers
                .map { MediaPerformer(id: $0.id, name: $0.name) }
                .filter { p in !editPerformers.contains(where: { $0.id == p.id }) }
        } catch {
            performerSearchResults = []
        }
    }

    private func searchStudios(query: String) async {
        guard !query.isEmpty else { studioSearchResults = []; return }
        do {
            let result = try await appModel.apiClient.findStudios(query: query, perPage: 20)
            studioSearchResults = result.studios
                .map { MediaStudio(id: $0.id, name: $0.name) }
        } catch {
            studioSearchResults = []
        }
    }

    // MARK: - Save

    private func saveChanges() async {
        isSaving = true
        saveError = nil

        do {
            let client = appModel.apiClient
            let title = editTitle.isEmpty ? nil : editTitle
            let code = editCode.isEmpty ? nil : editCode
            let date = editDate.isEmpty ? nil : editDate
            let details = editDetails.isEmpty ? nil : editDetails
            let creator = editCreator.isEmpty ? nil : editCreator
            let studioId = editStudio?.id
            let performerIds = editPerformers.map(\.id)
            let tagIds = editTags.map(\.id)
            let galleryIds = editGalleries.map(\.id)
            let urls = editUrls.filter { !$0.isEmpty }

            switch mediaType {
            case .image(let id):
                try await client.updateImage(
                    id: id, title: title, code: code, date: date,
                    details: details, photographer: creator, rating100: editRating100,
                    studioId: studioId, performerIds: performerIds, tagIds: tagIds,
                    galleryIds: galleryIds, urls: urls, organized: editOrganized
                )
                // Update local gallery model rating/o-counter
                // Update local gallery state
                if let idx = appModel.galleryImages.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryImages[idx].rating100 = editRating100
                }

            case .scene(let id):
                try await client.updateScene(
                    id: id, title: title, code: code, date: date,
                    details: details, director: creator, rating100: editRating100,
                    studioId: studioId, performerIds: performerIds, tagIds: tagIds,
                    galleryIds: galleryIds, urls: urls, organized: editOrganized
                )
                if let idx = appModel.galleryVideos.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryVideos[idx].rating100 = editRating100
                }
            }

            // Reload detail to reflect saved state
            await loadDetail()
        } catch {
            saveError = error.localizedDescription
        }

        isSaving = false
    }

    // MARK: - O Counter

    private func incrementOCounter() async {
        isUpdatingOCounter = true
        do {
            let client = appModel.apiClient
            switch mediaType {
            case .image(let id):
                let newCount = try await client.incrementImageOCounter(imageId: id)
                imageDetail?.oCounter = newCount
                if let idx = appModel.galleryImages.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryImages[idx].oCounter = newCount
                }
            case .scene(let id):
                let newCount = try await client.incrementSceneOCounter(sceneId: id)
                sceneDetail?.oCounter = newCount
                if let idx = appModel.galleryVideos.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryVideos[idx].oCounter = newCount
                }
            }
        } catch {}
        isUpdatingOCounter = false
    }

    private func decrementOCounter() async {
        isUpdatingOCounter = true
        do {
            let client = appModel.apiClient
            switch mediaType {
            case .image(let id):
                let newCount = try await client.decrementImageOCounter(imageId: id)
                imageDetail?.oCounter = newCount
                if let idx = appModel.galleryImages.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryImages[idx].oCounter = newCount
                }
            case .scene(let id):
                let newCount = try await client.decrementSceneOCounter(sceneId: id)
                sceneDetail?.oCounter = newCount
                if let idx = appModel.galleryVideos.firstIndex(where: { $0.stashId == id }) {
                    appModel.galleryVideos[idx].oCounter = newCount
                }
            }
        } catch {}
        isUpdatingOCounter = false
    }

    // MARK: - Delete

    private func performDelete(deleteFile: Bool) async {
        isDeleting = true
        do {
            let client = appModel.apiClient
            switch mediaType {
            case .image(let id):
                try await client.destroyImage(id: id, deleteFile: deleteFile)
            case .scene(let id):
                try await client.destroyScene(id: id, deleteFile: deleteFile)
            }
            onDelete?()
            dismiss()
        } catch {
            saveError = "Delete failed: \(error.localizedDescription)"
        }
        isDeleting = false
    }

    // MARK: - Formatting Helpers

    private func formatBitrate(_ bitrate: Int) -> String {
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        } else if bitrate >= 1_000 {
            return String(format: "%.0f kbps", Double(bitrate) / 1_000)
        }
        return "\(bitrate) bps"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Flow Layout (for tag/performer chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), offsets)
    }
}
