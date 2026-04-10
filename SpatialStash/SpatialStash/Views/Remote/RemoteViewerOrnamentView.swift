/*
 Spatial Stash - Remote Viewer Ornament View

 Control bar for the Remote API Viewer window.
 [ Grid | History | Prev | Next | Save | 🏠 | 🔄 | 🕐 | Adjustments | 🛑 ]
 */

import SwiftUI

struct RemoteViewerOrnamentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: RemoteViewerModel
    @Binding var showHomeAssistant: Bool
    @Binding var showHistory: Bool

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
                    ForEach(model.config.tagLists.indices, id: \.self) { index in
                        Button {
                            model.switchToTagList(index)
                        } label: {
                            HStack {
                                Text(tagListLabel(index))
                                if model.currentTagListIndex == index {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title3)
                        Text("\(model.currentTagListIndex + 1)/\(model.config.tagLists.count)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .disabled(model.config.tagLists.count <= 1)
                .help("Tag List")
            }
        }
    }

    private func tagListLabel(_ index: Int) -> String {
        let tags = model.config.tagLists[index]
        let firstTag = tags.first ?? ""
        return "List \(index + 1): \(firstTag)"
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
}
