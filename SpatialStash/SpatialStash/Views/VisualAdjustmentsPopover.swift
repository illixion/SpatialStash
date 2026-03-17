/*
 Spatial Stash - Visual Adjustments Popover

 Two-tab popover for adjusting brightness, contrast, and saturation.
 "Current" tab stores per-image/video settings, "Global" tab sets
 defaults applied when no per-item settings exist. Both tabs include
 a Reset button. Photos also get an auto-enhance toggle.
 */

import SwiftUI

struct VisualAdjustmentsPopover: View {
    enum Tab: String, CaseIterable {
        case current = "Current"
        case global = "Global"
    }

    @State private var selectedTab: Tab = .current

    /// Current per-item adjustments (photo or video)
    @Binding var currentAdjustments: VisualAdjustments

    /// Global default adjustments
    @Binding var globalAdjustments: VisualAdjustments

    /// Whether auto-enhance is available (true for photos, false for videos/GIFs)
    let showAutoEnhance: Bool

    /// Whether auto-enhance is currently processing
    var isProcessingAutoEnhance: Bool = false

    /// Callback for auto-enhance toggle
    var onToggleAutoEnhance: (() -> Void)? = nil

    /// Callback when current adjustments change (for persistence)
    var onCurrentAdjustmentsChanged: ((VisualAdjustments) -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .current:
                currentTabContent
            case .global:
                globalTabContent
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    // MARK: - Current Tab

    @ViewBuilder
    private var currentTabContent: some View {
        VStack(spacing: 14) {
            // Auto-enhance toggle (photos only)
            if showAutoEnhance {
                Button {
                    onToggleAutoEnhance?()
                } label: {
                    HStack(spacing: 8) {
                        if isProcessingAutoEnhance {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text("Auto Enhance")
                        Spacer()
                        if currentAdjustments.isAutoEnhanced {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        currentAdjustments.isAutoEnhanced
                            ? Color.accentColor.opacity(0.15)
                            : Color.secondary.opacity(0.1),
                        in: .rect(cornerRadius: 8)
                    )
                }
                .buttonStyle(.borderless)
                .disabled(isProcessingAutoEnhance)

                Divider()
            }

            adjustmentSlider(
                label: "Brightness",
                value: $currentAdjustments.brightness,
                range: -0.5...0.5,
                defaultValue: 0.0
            )

            adjustmentSlider(
                label: "Contrast",
                value: $currentAdjustments.contrast,
                range: 0.3...3.0,
                defaultValue: 1.0
            )

            adjustmentSlider(
                label: "Saturation",
                value: $currentAdjustments.saturation,
                range: 0.0...3.0,
                defaultValue: 1.0
            )

            Button("Reset") {
                currentAdjustments.brightness = 0.0
                currentAdjustments.contrast = 1.0
                currentAdjustments.saturation = 1.0
                // Note: auto-enhance is toggled separately, not reset here
                onCurrentAdjustmentsChanged?(currentAdjustments)
            }
            .buttonStyle(.bordered)
            .disabled(
                currentAdjustments.brightness == 0.0
                && currentAdjustments.contrast == 1.0
                && currentAdjustments.saturation == 1.0
            )
        }
        .onChange(of: currentAdjustments) { _, newValue in
            onCurrentAdjustmentsChanged?(newValue)
        }
    }

    // MARK: - Global Tab

    @ViewBuilder
    private var globalTabContent: some View {
        VStack(spacing: 14) {
            Text("Default adjustments applied when no per-image settings are set.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            adjustmentSlider(
                label: "Brightness",
                value: $globalAdjustments.brightness,
                range: -0.5...0.5,
                defaultValue: 0.0
            )

            adjustmentSlider(
                label: "Contrast",
                value: $globalAdjustments.contrast,
                range: 0.3...3.0,
                defaultValue: 1.0
            )

            adjustmentSlider(
                label: "Saturation",
                value: $globalAdjustments.saturation,
                range: 0.0...3.0,
                defaultValue: 1.0
            )

            Button("Reset") {
                globalAdjustments.reset()
            }
            .buttonStyle(.bordered)
            .disabled(!globalAdjustments.isModified)
        }
    }

    // MARK: - Slider Component

    @ViewBuilder
    private func adjustmentSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(formatValue(value.wrappedValue, defaultValue: defaultValue))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(value.wrappedValue != defaultValue ? .accentColor : .secondary)
            }
            Slider(value: value, in: range)
        }
    }

    /// Format a slider value for display, showing "+/-" prefix for brightness-style values
    private func formatValue(_ value: Double, defaultValue: Double) -> String {
        if defaultValue == 0.0 {
            // Brightness-style: show +/- prefix
            if value >= 0 {
                return String(format: "+%.2f", value)
            } else {
                return String(format: "%.2f", value)
            }
        } else {
            // Contrast/saturation-style: show as multiplier
            return String(format: "%.2f", value)
        }
    }
}
