/*
 Hypnos - Atmos Object Spike immersive space

 Mixed immersive space holding one entity per Atmos element. Objects carry a
 `SpatialAudioComponent` and move along their DAMF position track; the LFE
 bed has no position, so it plays head-locked through a
 `ChannelAudioComponent`. Each entity's audio is an `AudioGeneratorController`
 whose render callback reads `AtmosSpikeAudio` — see `AtmosSpike.swift` for
 why every generator reads from one shared sample-time anchor.

 An immersive space is needed rather than a window because the sources sit
 all around and above the listener (a ~4×5 m virtual room by default), well
 outside any window's bounds. Transport and tuning stay in Settings, which
 remains usable beside a mixed space.
 */

#if os(visionOS)
import AVFoundation
import os
import RealityKit
import SwiftUI

struct AtmosSpikeImmersiveView: View {
    private let model = AtmosSpikeModel.shared

    @State private var root = Entity()
    @State private var entities: [Int: Entity] = [:]
    @State private var spheres: [Int: ModelEntity] = [:]
    @State private var controllers: [AudioGeneratorController] = []
    @State private var appliedReverb: Float?
    @State private var tickTask: Task<Void, Never>?

    var body: some View {
        RealityView { content in
            content.add(root)
            buildSources()
        }
        .onAppear {
            model.isSpaceOpen = true
            tickTask = Task { @MainActor in
                while !Task.isCancelled {
                    tick()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }
        .onDisappear {
            tickTask?.cancel()
            model.pause()
            for controller in controllers { controller.stop() }
            controllers.removeAll()
            root.children.removeAll()
            model.isSpaceOpen = false
        }
    }

    private func buildSources() {
        guard let audio = model.audio else { return }
        let palette: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal,
                                  .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown,
                                  .white, .systemCyan, .systemMint]
        for element in model.elements {
            let entity = Entity()
            entity.name = "atmos-\(element.id)"
            if element.isBed {
                entity.components.set(ChannelAudioComponent())
            } else {
                entity.components.set(SpatialAudioComponent(
                    gain: 0,
                    directLevel: 0,
                    reverbLevel: Audio.Decibel(model.reverbDB),
                    directivity: .beam(focus: 0),
                    distanceAttenuation: .rolloff(factor: 0)
                ))
                let color = palette[element.channel % palette.count]
                let sphere = ModelEntity(
                    mesh: .generateSphere(radius: 0.05),
                    materials: [UnlitMaterial(color: color)]
                )
                entity.addChild(sphere)
                spheres[element.channel] = sphere
                entity.position = model.worldPosition(of: element, frame: 0)
            }
            root.addChild(entity)
            entities[element.channel] = entity

            do {
                // The handler must not be a closure literal here — see
                // `AtmosSpikeAudio.renderHandler(channel:)`.
                let controller = try entity.prepareAudio(
                    configuration: AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono, mixGroupName: nil),
                    audio.renderHandler(channel: element.channel)
                )
                controllers.append(controller)
            } catch {
                AppLogger.atmosSpike.error("Generator for element \(element.id) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        appliedReverb = model.reverbDB
        // Start every generator in the same main-actor turn; they emit
        // silence until the model's transport says play.
        for controller in controllers { controller.play() }
        AppLogger.atmosSpike.info("Built \(controllers.count) generators for \(model.elements.count) elements")
    }

    private func tick() {
        model.tick()
        let frame = model.currentFrame
        for element in model.elements where !element.isBed {
            guard let entity = entities[element.channel] else { continue }
            entity.position = model.worldPosition(of: element, frame: frame)
            if let sphere = spheres[element.channel] {
                sphere.isEnabled = model.showSpheres
                let level = model.levels.indices.contains(element.channel) ? model.levels[element.channel] : 0
                sphere.scale = SIMD3(repeating: 0.6 + min(level * 6, 3))
            }
        }
        if appliedReverb != model.reverbDB {
            appliedReverb = model.reverbDB
            for element in model.elements where !element.isBed {
                guard let entity = entities[element.channel],
                      var spatial = entity.components[SpatialAudioComponent.self] else { continue }
                spatial.reverbLevel = Audio.Decibel(model.reverbDB)
                entity.components.set(spatial)
            }
        }
    }
}
#endif
