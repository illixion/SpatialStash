/*
 Hypnos - Atmos Object Spike stage

 A `RealityView` holding one entity per Atmos element. Objects carry a
 `SpatialAudioComponent` and move along their DAMF position track; the LFE
 bed has no position, so it plays head-locked through a
 `ChannelAudioComponent`. Each entity's audio is an `AudioGeneratorController`
 whose render callback reads `AtmosSpikeAudio` — see `AtmosSpike.swift` for
 why every generator reads from one shared sample-time anchor.

 The view has no visible content; it only decides where the listener is.

 - visionOS: the view fills the player window. Its origin is the window's
   centre, with +z pointing out toward the viewer, and RealityKit's
   listener is the wearer's head. The virtual room is centred
   `listenerDistance` in front of the window at the window's height, so the
   room moves with the window and the screen is its front wall. Sources far
   outside a window's bounds are still placed correctly (measured with
   `SpatialAudioProbeSection`); only their visuals would be clipped.
 - iOS: a virtual camera. A `PerspectiveCamera` at the origin is the
   active camera, and so the audio listener (RealityKit's default when
   `audioListener` is nil), with the room centred on it.
   `AtmosSpikeHeadTracker` turns it with the wearer's AirPods. An explicit
   `audioListener` entity was tried first. With it, reopening the sheet
   hung the main thread in RealityKit's listener-transform SVD (the usual
   sign of NaNs), and PHASE once crashed reading a generator stream out of
   bounds after a loud crackle. Both point at a bad listener transform,
   which a RealityKit-managed camera should not produce.
 */

import AVFoundation
import os
import RealityKit
import SwiftUI

struct AtmosSpikeStageView: View {
    private let model = AtmosSpikeModel.shared

    /// The virtual room, centred on the listener's ears.
    @State private var room = Entity()
    @State private var entities: [Int: Entity] = [:]
    @State private var controllers: [AudioGeneratorController] = []
    @State private var appliedReverb: Float?
    @State private var tickTask: Task<Void, Never>?
    #if os(iOS)
    @State private var listener = PerspectiveCamera()
    #endif

    var body: some View {
        RealityView { content in
            #if os(iOS)
            content.camera = .virtual
            listener.name = "atmos-listener"
            content.add(listener)
            #endif
            content.add(room)
            buildSources()
        }
        .onAppear {
            model.isStageOpen = true
            #if os(iOS)
            AtmosSpikeHeadTracker.shared.start()
            #endif
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
            room.children.removeAll()
            entities.removeAll()
            #if os(iOS)
            AtmosSpikeHeadTracker.shared.stop()
            #endif
            model.isStageOpen = false
        }
    }

    private func buildSources() {
        guard let audio = model.audio else { return }
        placeRoom()
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
                entity.position = model.listenerPosition(of: element, frame: 0)
            }
            room.addChild(entity)
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

    /// Puts the room's centre where the listener is assumed to be.
    private func placeRoom() {
        #if os(visionOS)
        room.position = SIMD3(0, 0, model.listenerDistance)
        #else
        room.position = .zero
        #endif
    }

    private func tick() {
        model.tick()
        placeRoom()
        #if os(iOS)
        listener.orientation = AtmosSpikeHeadTracker.shared.orientation
        #endif
        let frame = model.currentFrame
        for element in model.elements where !element.isBed {
            entities[element.channel]?.position = model.listenerPosition(of: element, frame: frame)
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
