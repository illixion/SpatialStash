/*
 Spatial Stash - Remote Viewer Ornament View

 Control bar for the Remote API Viewer window.
 [ Grid | History | Prev | Next | Save | Home | Tag List | Mod Tags | Sync | Adjustments | Block ]
 */

import SwiftUI

struct RemoteViewerOrnamentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: RemoteViewerModel
    var tagListManager: TagListManager
    var modTagManager: ModTagManager
    @Binding var showHomeAssistant: Bool
    @Binding var showHistory: Bool

    /// Local UI state for the in-ornament "Add Preset…" popover. Lives here
    /// rather than on the model since it's view-only and tied to this
    /// window's ornament.
    @State private var showAddPresetPopover = false
    @State private var newPresetText = ""

    var body: some View {
        HStack(spacing: 16) {
            // Grid - Open main app window
            Button {
                appModel.showMainWindow(openWindow: openWindow)
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Open Gallery")

            // History
            Button {
                withAnimation { showHistory.toggle() }
                if showHomeAssistant { showHomeAssistant = false }
            } label: {
                Image(systemName: showHistory ? "clock.arrow.circlepath" : "clock.arrow.circlepath")
                    .font(.title3)
                    .padding(6)
                    .background(showHistory ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.borderless)
            .help("View History")

            Divider()
                .frame(height: 24)

            // Previous
            Button {
                model.previousImage()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(model.postHistory.count < 2)
            .help("Previous Image")

            // Next
            Button {
                model.goToNextImage()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Next Image")

            Divider()
                .frame(height: 24)

            if !model.isGalleryMode {
                // Save (API mode only)
                Button {
                    model.saveCurrentPost()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(model.saveablePost == nil)
                .help("Save Image")

                // Home Assistant
                Button {
                    withAnimation { showHomeAssistant.toggle() }
                    if showHistory { showHistory = false }
                } label: {
                    Image(systemName: showHomeAssistant ? "house.fill" : "house")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(model.config.homeAssistantURL.isEmpty)
                .help("Home Assistant")

                // Tag List Selector (spinner while loading, warning if empty)
                tagListMenu

                // Mod Tag Preset Selector
                modTagMenu

                // Display Sync Toggle
                Button {
                    model.enableDisplaySync.toggle()
                } label: {
                    Image(systemName: model.enableDisplaySync ? "arrow.triangle.swap" : "arrow.triangle.swap")
                        .font(.title3)
                        .padding(6)
                        .background(model.enableDisplaySync ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.borderless)
                .help(model.enableDisplaySync ? "Display Sync On" : "Display Sync Off")
            }

            // Visual Adjustments
            adjustmentsButton

            if !model.isGalleryMode {
                // Block (API mode only)
                Button {
                    model.blockCurrentPost()
                } label: {
                    Image(systemName: "hand.raised.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(model.currentPost == nil)
                .help("Block Post")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    private var tagListMenu: some View {
        Group {
            if model.isFetching && model.currentImage == nil {
                ProgressView()
                    .font(.title3)
            } else if model.fetchReturnedEmpty && model.currentImage == nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                    .help("No posts found")
            } else {
                Menu {
                    Group {
                        ForEach(tagListManager.tagLists.indices, id: \.self) { index in
                            Button {
                                tagListManager.switchToTagList(index)
                            } label: {
                                HStack {
                                    Text(tagListLabel(index))
                                    if tagListManager.activeIndex == index {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    .onAppear { updateOrnamentMenuCount(opened: true) }
                    .onDisappear { updateOrnamentMenuCount(opened: false) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title3)
                        Text("\(tagListManager.activeIndex + 1)/\(tagListManager.tagLists.count)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .disabled(tagListManager.tagLists.count <= 1)
                .help("Tag List")
            }
        }
    }

    private func tagListLabel(_ index: Int) -> String {
        let tags = tagListManager.tagLists[index]
        let firstTag = tags.first ?? ""
        return "List \(index + 1): \(firstTag)"
    }

    private var modTagMenu: some View {
        Menu {
            Group {
                // "None" sentinel for clearing any active preset.
                Button {
                    modTagManager.clearActive()
                } label: {
                    HStack {
                        Text("None")
                        if modTagManager.activeIndex == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                ForEach(modTagManager.modTagLists.indices, id: \.self) { index in
                    Button {
                        modTagManager.switchToPreset(index)
                    } label: {
                        HStack {
                            Text(modTagLabel(index))
                            if modTagManager.activeIndex == index {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    newPresetText = ""
                    showAddPresetPopover = true
                } label: {
                    Label("Add Preset…", systemImage: "plus")
                }
            }
            .onAppear { updateOrnamentMenuCount(opened: true) }
            .onDisappear { updateOrnamentMenuCount(opened: false) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.title3)
                Text(modTagBadge)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .help("Mod Tags")
        .popover(isPresented: $showAddPresetPopover) {
            addPresetPopover
        }
    }

    private var addPresetPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Mod Tag Preset")
                .font(.headline)
            Text("Space-separated tags. Negate with a leading `-`.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("rating:s -blood", text: $newPresetText)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minWidth: 320)
                .onSubmit { commitNewPreset() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showAddPresetPopover = false
                }
                Button("Add & Apply") { commitNewPreset() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedNewPresetTags.isEmpty)
            }
        }
        .padding(20)
        .onAppear { updateOrnamentMenuCount(opened: true) }
        .onDisappear { updateOrnamentMenuCount(opened: false) }
    }

    private var parsedNewPresetTags: [String] {
        newPresetText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private func commitNewPreset() {
        let tags = parsedNewPresetTags
        guard !tags.isEmpty else { return }
        var lists = modTagManager.modTagLists
        lists.append(tags)
        modTagManager.modTagLists = lists
        // Switch to the freshly added preset so it takes effect immediately —
        // matches the "tap the menu, see the slideshow react" expectation.
        modTagManager.switchToPreset(lists.count - 1)
        newPresetText = ""
        showAddPresetPopover = false
    }

    private func modTagLabel(_ index: Int) -> String {
        let tags = modTagManager.modTagLists[index]
        let firstTag = tags.first ?? ""
        return "Preset \(index + 1): \(firstTag)"
    }

    private var modTagBadge: String {
        guard let idx = modTagManager.activeIndex else { return "—" }
        return "\(idx + 1)/\(modTagManager.modTagLists.count)"
    }

    private var adjustmentsButton: some View {
        @Bindable var appModel = appModel

        return Button {
            model.showAdjustmentsPopover.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.title3)
                .padding(6)
                .background(
                    (model.currentAdjustments.isModified || appModel.globalVisualAdjustments.isModified)
                        ? .white.opacity(0.3) : .clear,
                    in: .rect(cornerRadius: 8)
                )
        }
        .buttonStyle(.borderless)
        .help("Visual Adjustments")
        .popover(isPresented: $model.showAdjustmentsPopover) {
            VisualAdjustmentsPopover(
                currentAdjustments: $model.currentAdjustments,
                globalAdjustments: $appModel.globalVisualAdjustments,
                showAutoEnhance: false,
                remoteViewerModel: model
            )
        }
    }

    /// Increment / decrement the model's open-menu counter. Clamped at zero
    /// so a missed event can't drive the count negative. Used by the window
    /// view to suppress the diorama foreground while a menu is shown.
    private func updateOrnamentMenuCount(opened: Bool) {
        if opened {
            model.openOrnamentMenuCount += 1
        } else {
            model.openOrnamentMenuCount = max(0, model.openOrnamentMenuCount - 1)
        }
    }
}
