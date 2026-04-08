/*
 Spatial Stash - Remote Viewer Ornament View

 Control bar for the Remote API Viewer window.
 [ Grid | Prev | Next | Save | 🏠 | 🔄 | 🕐 | Adjustments | 🛑 ]
 */

import SwiftUI

struct RemoteViewerOrnamentView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: RemoteViewerModel
    @Binding var showHomeAssistant: Bool
    @Binding var showHistory: Bool

    var body: some View {
        HStack(spacing: 16) {
            // Grid - History
            Button {
                withAnimation { showHistory.toggle() }
                if showHomeAssistant { showHomeAssistant = false }
            } label: {
                Image(systemName: showHistory ? "square.grid.2x2.fill" : "square.grid.2x2")
                    .font(.title3)
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

            // Save
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

            // Cycle Tag List
            Button {
                model.cycleTagList()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(model.config.tagLists.count <= 1)
            .help("Cycle Tag List (\(model.currentTagListIndex + 1)/\(model.config.tagLists.count))")

            // Toggle Clock
            Button {
                model.toggleClock()
            } label: {
                Image(systemName: model.showClock ? "clock.fill" : "clock")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Toggle Clock")

            // Visual Adjustments
            adjustmentsButton

            // Block
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
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
