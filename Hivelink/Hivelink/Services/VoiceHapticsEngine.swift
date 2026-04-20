//
//  VoiceHapticsEngine.swift
//  Hivelink
//
//  CoreHaptics-driven haptic patterns for voice call state transitions
//  and real-time audio level feedback.
//

import CoreHaptics
import Foundation
import UIKit

@MainActor
final class VoiceHapticsEngine {

    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isEngineRunning = false

    @UserDefaultsBacked(key: "hivelink.haptics.enabled", defaultValue: true)
    private var isEnabled: Bool

    private var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: - Engine Lifecycle

    private func ensureEngine() {
        guard supportsHaptics, isEnabled, engine == nil else { return }

        do {
            let eng = try CHHapticEngine()
            eng.playsHapticsOnly = true
            eng.isAutoShutdownEnabled = true

            eng.stoppedHandler = { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.isEngineRunning = false
                }
            }
            eng.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.restartEngine()
                }
            }

            try eng.start()
            engine = eng
            isEngineRunning = true
        } catch {
            engine = nil
            isEngineRunning = false
        }
    }

    private func restartEngine() {
        guard let engine else { return }
        do {
            try engine.start()
            isEngineRunning = true
        } catch {
            isEngineRunning = false
        }
    }

    func stop() {
        try? continuousPlayer?.cancel()
        continuousPlayer = nil
        engine?.stop()
        engine = nil
        isEngineRunning = false
    }

    // MARK: - Call State Haptics

    func connectStarted() {
        playTransient(intensity: 0.6, sharpness: 0.8)
    }

    func connected() {
        playPattern([
            (.init(parameterID: .hapticIntensity, value: 0.5), .init(parameterID: .hapticSharpness, value: 0.6), 0),
            (.init(parameterID: .hapticIntensity, value: 0.8), .init(parameterID: .hapticSharpness, value: 0.7), 0.12),
        ])
    }

    func suspended() {
        playTransient(intensity: 0.4, sharpness: 0.3)
    }

    func ended() {
        playPattern([
            (.init(parameterID: .hapticIntensity, value: 0.6), .init(parameterID: .hapticSharpness, value: 0.5), 0),
            (.init(parameterID: .hapticIntensity, value: 0.3), .init(parameterID: .hapticSharpness, value: 0.2), 0.15),
        ])
    }

    func error() {
        playPattern([
            (.init(parameterID: .hapticIntensity, value: 0.9), .init(parameterID: .hapticSharpness, value: 1.0), 0),
            (.init(parameterID: .hapticIntensity, value: 0.7), .init(parameterID: .hapticSharpness, value: 0.9), 0.08),
            (.init(parameterID: .hapticIntensity, value: 0.5), .init(parameterID: .hapticSharpness, value: 0.8), 0.16),
        ])
    }

    // MARK: - Real-Time Level Haptics

    /// Subtle continuous pulse while the user is speaking (throttle at ~10 Hz).
    func listeningPulse(level: Float) {
        guard supportsHaptics, isEnabled else { return }
        let clamped = min(max(level, 0), 1)
        guard clamped > 0.05 else { return }
        playTransient(intensity: Float(clamped * 0.3), sharpness: Float(clamped * 0.2))
    }

    /// Light tap synchronized with model output peaks (throttle at ~10 Hz).
    func modelSpeakingTick(level: Float) {
        guard supportsHaptics, isEnabled else { return }
        let clamped = min(max(level, 0), 1)
        guard clamped > 0.1 else { return }
        playTransient(intensity: Float(clamped * 0.25), sharpness: 0.15)
    }

    // MARK: - Primitives

    private func playTransient(intensity: Float, sharpness: Float) {
        guard supportsHaptics, isEnabled else { return }
        ensureEngine()
        guard let engine, isEngineRunning else { return }

        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    private func playPattern(_ taps: [(CHHapticEventParameter, CHHapticEventParameter, TimeInterval)]) {
        guard supportsHaptics, isEnabled else { return }
        ensureEngine()
        guard let engine, isEngineRunning else { return }

        do {
            let events = taps.map { intensity, sharpness, time in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [intensity, sharpness],
                    relativeTime: time
                )
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }
}

// MARK: - UserDefaults Property Wrapper

@propertyWrapper
private struct UserDefaultsBacked<T> {
    let key: String
    let defaultValue: T

    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
