/*
 Hypnos - the film player's sound stage

 A `RealityView` with one entity per Atmos element. Objects carry a
 `SpatialAudioComponent` and move along their position track; the LFE bed
 has no position, so it plays head-locked through a `ChannelAudioComponent`.
 Each entity's audio is an `AudioGeneratorController` reading
 `AtmosObjectAudio`. The view draws nothing; it only decides where the
 listener is.

 - visionOS: the view fills the player window, whose origin is the
   window's centre with +z toward the viewer, and the listener is the
   wearer's head. The room is centred `listenerDistance` in front of the
   window, so it moves with the window and the screen is its front wall.
 - iOS and macOS: a virtual camera. A `PerspectiveCamera` at the origin is
   the active camera and so the audio listener, with the room centred on
   it; `listenerOrientation` turns it (head tracking lives in the app). An
   explicit `audioListener` entity hung the main thread in RealityKit's
   listener-transform SVD on iOS, so it isn't used.

 Moved from the app's Atmos spike (AtmosSpikeStageView).
 */

import AudioToolbox
import os
import RealityKit
import SwiftUI

public struct FilmStageView: View {
    let player: FilmPlayer
    /// visionOS: metres from the window to the listener.
    var listenerDistance: Float
    /// iOS/macOS: the listener's head orientation, read every tick.
    var listenerOrientation: @MainActor () -> simd_quatf

    @State private var room = Entity()
    @State private var entities: [Int: Entity] = [:]
    @State private var controllers: [AudioGeneratorController] = []
    @State private var appliedReverb: Float?
    @State private var builtFor: ObjectIdentifier?
    @State private var tickTask: Task<Void, Never>?
    #if !os(visionOS)
    @State private var listener = PerspectiveCamera()
    #endif

    private let logger = Logger(subsystem: "com.illixion.hypnos", category: "FilmStage")

    public init(player: FilmPlayer, listenerDistance: Float = 1.5,
                listenerOrientation: @escaping @MainActor () -> simd_quatf = { simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }) {
        self.player = player
        self.listenerDistance = listenerDistance
        self.listenerOrientation = listenerOrientation
    }

    public var body: some View {
        RealityView { content in
            #if !os(visionOS)
            content.camera = .virtual
            listener.name = "film-listener"
            content.add(listener)
            #endif
            content.add(room)
        }
        .onAppear {
            tickTask = Task { @MainActor in
                while !Task.isCancelled {
                    tick()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }
        .onDisappear {
            tickTask?.cancel()
            teardown()
        }
    }

    private func teardown() {
        for controller in controllers { controller.stop() }
        controllers.removeAll()
        room.children.removeAll()
        entities.removeAll()
        builtFor = nil
    }

    /// (Re)builds the generators when the player's audio changes (a new film).
    private func buildIfNeeded() {
        let current = player.audio.map(ObjectIdentifier.init)
        guard current != builtFor else { return }
        teardown()
        builtFor = current
        guard let audio = player.audio else { return }
        for element in player.elements {
            let entity = Entity()
            entity.name = "atmos-\(element.id)"
            if element.isBed {
                entity.components.set(ChannelAudioComponent())
            } else {
                entity.components.set(SpatialAudioComponent(
                    gain: 0,
                    directLevel: 0,
                    reverbLevel: Audio.Decibel(player.reverbDB),
                    directivity: .beam(focus: 0),
                    distanceAttenuation: .rolloff(factor: 0)
                ))
                entity.position = player.listenerPosition(of: element, frame: player.currentFrame)
            }
            room.addChild(entity)
            entities[element.channel] = entity
            do {
                // The handler must not be a closure literal here — see
                // `AtmosObjectAudio.renderHandler(channel:)`.
                let controller = try entity.prepareAudio(
                    configuration: AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono, mixGroupName: nil),
                    audio.renderHandler(channel: element.channel)
                )
                controllers.append(controller)
            } catch {
                logger.error("Generator for element \(element.id) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        appliedReverb = player.reverbDB
        // Start every generator in the same turn; they emit silence until the transport plays.
        for controller in controllers { controller.play() }
        logger.info("Built \(controllers.count) generators for \(player.elements.count) elements")
    }

    private func tick() {
        buildIfNeeded()
        player.tick()
        #if os(visionOS)
        room.position = SIMD3(0, 0, listenerDistance)
        #else
        listener.orientation = listenerOrientation()
        #endif
        let frame = player.currentFrame
        for element in player.elements where !element.isBed {
            entities[element.channel]?.position = player.listenerPosition(of: element, frame: frame)
        }
        if appliedReverb != player.reverbDB {
            appliedReverb = player.reverbDB
            for element in player.elements where !element.isBed {
                guard let entity = entities[element.channel],
                      var spatial = entity.components[SpatialAudioComponent.self] else { continue }
                spatial.reverbLevel = Audio.Decibel(player.reverbDB)
                entity.components.set(spatial)
            }
        }
    }
}
