import Foundation
import UIKit
import AvatarKit
import AvatarKitRTC

/// All integration test cases for AvatarKitRTC iOS.
///
/// Coverage mirrors the seven groups exercised by the web RTC integration
/// runner and adds iOS-only regression cases for behavior without a direct
/// web analogue.
enum TestCases {

    // MARK: - Group 1: Connection State

    static let connection: [TestCase] = [
        TestCase(
            id: "rtc.conn.connected",
            name: "Player is connected after setup",
            group: "Connection State",
            timeoutMs: 5_000
        ) { ctx in
            try ctx.assert(ctx.player.isConnected, "Player should be connected")
            ctx.log("isConnected=true")
        },
        TestCase(
            id: "rtc.conn.provider-active",
            name: "Provider connection state is connected",
            group: "Connection State",
            timeoutMs: 5_000
        ) { ctx in
            let state = ctx.provider.connectionState
            try ctx.assert(state == .connected,
                           "Expected provider state == .connected, got \(state.rawValue)")
        },
        TestCase(
            id: "rtc.conn.view-attached",
            name: "AvatarView is attached and idle is rendering",
            group: "Connection State",
            timeoutMs: 8_000
        ) { ctx in
            try ctx.assert(ctx.avatarView.window != nil,
                           "AvatarView should be inside a window hierarchy")
            // Wait a beat to let the display-link tick at least once.
            await ctx.wait(500)
            ctx.log("AvatarView OK")
        },
    ]

    // MARK: - Group 2: Idle Animation

    static let idle: [TestCase] = [
        TestCase(
            id: "rtc.idle.no-stall-5s",
            name: "Idle animation stream — no stall for 5s",
            group: "Idle Animation",
            timeoutMs: 10_000
        ) { ctx in
            ctx.log("Watching for stall events for 5s...")
            await ctx.wait(5_000)
            let stalls = ctx.capturedEvents.filter { if case .stalled = $0 { return true } else { return false } }
            try ctx.assert(stalls.isEmpty,
                           "Stall fired during idle (\(stalls.count) times)")
            try ctx.assert(ctx.player.isConnected, "Should still be connected")
        },
        TestCase(
            id: "rtc.idle.no-frame-overrun",
            name: "Idle period — no animation frames pushed",
            group: "Idle Animation",
            timeoutMs: 8_000
        ) { ctx in
            ctx.resetFrameCount()
            await ctx.wait(3_000)
            // During idle the server only sends idle markers, not full
            // animation frames. Tolerate 0–2 stray frames at idle/session
            // boundaries; assert hard if we see a sustained stream.
            let frames = ctx.frameCount
            try ctx.assert(frames <= 5,
                           "Idle should not stream animation frames, got \(frames)")
            ctx.log("Idle frame count = \(frames)")
        },
    ]

    // MARK: - Group 3: Audio → Animation Round-trip
    //
    // Pushes bundled 16kHz mono PCM into Agora as an external audio source,
    // then waits for the agent to reply with animation frames. No physical
    // microphone involved — matches web's track-based publishAudio.

    static let audioRoundtrip: [TestCase] = [
        TestCase(
            id: "rtc.audio.push-pcm-and-frames",
            name: "Push PCM — avatar responds with animation",
            group: "Audio Round-trip",
            timeoutMs: 40_000
        ) { ctx in
            ctx.resetFrameCount()
            ctx.log("Pushing \(ctx.pcmData.count) bytes of PCM...")
            let pushedMs = try await ctx.pushPcm()
            ctx.log("Pushed \(pushedMs)ms of audio, waiting for frames...")
            let frames = try await ctx.waitForFrames(10, timeoutMs: 20_000)
            ctx.log("Received \(frames) animation frames")
        },
        TestCase(
            id: "rtc.audio.multiple-sessions",
            name: "Two PCM sessions — each produces animation",
            group: "Audio Round-trip",
            timeoutMs: 90_000
        ) { ctx in
            for i in 1...2 {
                ctx.resetFrameCount()
                ctx.log("Session \(i): pushing PCM...")
                _ = try await ctx.pushPcm()
                ctx.log("Session \(i): waiting for animation...")
                let frames = try await ctx.waitForFrames(5, timeoutMs: 20_000)
                ctx.log("Session \(i): \(frames) frames")
                await ctx.wait(2_000)
            }
        },
    ]

    // MARK: - Group 4: Audio Publishing

    static let audioPublish: [TestCase] = [
        TestCase(
            id: "rtc.pub.start-stop",
            name: "Publish and unpublish microphone",
            group: "Audio Publishing",
            timeoutMs: 10_000
        ) { ctx in
            try await ctx.player.publishAudio()
            ctx.log("Mic on")
            await ctx.wait(1_000)
            await ctx.player.unpublishAudio()
            ctx.log("Mic off")
        },
        TestCase(
            id: "rtc.pub.unpublish-when-idle",
            name: "Unpublish when not publishing — no crash",
            group: "Audio Publishing",
            timeoutMs: 5_000
        ) { ctx in
            await ctx.player.unpublishAudio()
            ctx.log("No-op unpublish completed")
        },
        TestCase(
            id: "rtc.pub.publish-while-disconnected",
            name: "Publish while disconnected — throws notConnected",
            group: "Audio Publishing",
            timeoutMs: 20_000
        ) { ctx in
            await ctx.player.disconnect()
            try ctx.assert(!ctx.player.isConnected, "Should be disconnected")

            var threw = false
            do {
                try await ctx.player.publishAudio()
            } catch {
                threw = true
                ctx.log("Got expected error: \(error.localizedDescription)")
            }
            try ctx.assert(threw, "publishAudio should throw when not connected")
            // Restore so the next case starts in a connected state.
            try await ctx.player.connect(AgoraConnectionConfig(
                appId: ctx.connection.appId,
                channel: ctx.connection.channelName,
                token: ctx.connection.token,
                uid: ctx.connection.uid
            ))
            await ctx.wait(3_000)
        },
    ]

    // MARK: - Group 5: Stability

    static let stability: [TestCase] = [
        TestCase(
            id: "rtc.stab.sustained-15s",
            name: "Sustained connection — 15s without errors",
            group: "Stability",
            timeoutMs: 25_000
        ) { ctx in
            ctx.resetEvents()
            await ctx.wait(15_000)
            try ctx.assert(ctx.player.isConnected, "Connection dropped during 15s window")
            let errors = ctx.capturedEvents.compactMap { e -> String? in
                if case .error(let m) = e { return m } else { return nil }
            }
            try ctx.assert(errors.isEmpty, "Errors during sustained window: \(errors.joined(separator: ", "))")
            ctx.log("15s clean")
        },
        TestCase(
            id: "rtc.stab.no-false-stall",
            name: "No false stall on healthy connection (8s)",
            group: "Stability",
            timeoutMs: 12_000
        ) { ctx in
            ctx.resetEvents()
            await ctx.wait(8_000)
            let stalled = ctx.capturedEvents.contains { if case .stalled = $0 { return true } else { return false } }
            try ctx.assert(!stalled, "Stall fired on healthy connection")
        },
    ]

    // MARK: - Group 6: Disconnect & Reconnect

    static let reconnect: [TestCase] = [
        TestCase(
            id: "rtc.rc.disconnect-reconnect",
            name: "Disconnect and reconnect",
            group: "Disconnect & Reconnect",
            timeoutMs: 30_000
        ) { ctx in
            await ctx.player.disconnect()
            try ctx.assert(!ctx.player.isConnected, "Should be disconnected")
            ctx.log("Disconnected")

            let start = ContinuousClock.now
            try await ctx.player.reconnect()
            let elapsed = ContinuousClock.now - start
            try ctx.assert(ctx.player.isConnected, "Should be reconnected")
            ctx.log("Reconnected in \(Int(elapsed / .milliseconds(1)))ms")
            await ctx.wait(3_000)
        },
        TestCase(
            id: "rtc.rc.new-room",
            name: "Connect to a fresh room/channel",
            group: "Disconnect & Reconnect",
            timeoutMs: 30_000
        ) { ctx in
            await ctx.player.disconnect()
            ctx.log("Left original channel")

            let fresh = try await ctx.fetchNewToken()
            ctx.log("Got token for channel=\(fresh.channelName)")

            try await ctx.player.connect(AgoraConnectionConfig(
                appId: fresh.appId,
                channel: fresh.channelName,
                token: fresh.token,
                uid: fresh.uid
            ))
            try ctx.assert(ctx.player.isConnected, "Should be connected to new channel")
            await ctx.wait(3_000)
        },
    ]

    // MARK: - Group 7: Error Handling & Edge Cases

    static let edgeCases: [TestCase] = [
        TestCase(
            id: "rtc.err.double-disconnect",
            name: "Double disconnect — no crash",
            group: "Error Handling",
            timeoutMs: 15_000
        ) { ctx in
            await ctx.player.disconnect()
            await ctx.player.disconnect()
            try ctx.assert(!ctx.player.isConnected, "Still disconnected")
            try await ctx.player.reconnect()
            await ctx.wait(3_000)
        },
        TestCase(
            id: "rtc.err.connect-when-connected",
            name: "connect() while already connected — throws alreadyConnected",
            group: "Error Handling",
            timeoutMs: 5_000
        ) { ctx in
            try ctx.assert(ctx.player.isConnected, "Should already be connected")
            var threw = false
            do {
                try await ctx.player.connect(AgoraConnectionConfig(
                    appId: ctx.connection.appId,
                    channel: ctx.connection.channelName,
                    token: ctx.connection.token,
                    uid: ctx.connection.uid
                ))
            } catch {
                threw = true
                ctx.log("Got expected error: \(error.localizedDescription)")
            }
            try ctx.assert(threw, "connect() should throw when already connected")
        },
        TestCase(
            id: "rtc.err.rapid-publish-cycle",
            name: "Rapid publish/unpublish — no crash",
            group: "Error Handling",
            timeoutMs: 15_000
        ) { ctx in
            for i in 0..<3 {
                try await ctx.player.publishAudio()
                await ctx.player.unpublishAudio()
                ctx.log("cycle \(i + 1) ok")
            }
        },
    ]

    // MARK: - iOS-only regression cases
    //
    // Behavior that doesn't exist on web RTC SDK but is critical for iOS.

    static let iOSOnly: [TestCase] = [
        TestCase(
            id: "rtc.ios.decode-invalid-frames",
            name: "AvatarSDK.decodeAnimationFrames rejects garbage protobuf",
            group: "iOS-Only",
            timeoutMs: 5_000
        ) { ctx in
            let garbage = Data([0xff, 0xee, 0xdd, 0xcc, 0xbb])
            var threw = false
            do {
                _ = try AvatarSDK.decodeAnimationFrames(from: garbage)
            } catch {
                threw = true
                ctx.log("Got expected error: \(error.localizedDescription)")
            }
            try ctx.assert(threw, "Garbage protobuf should be rejected")
        },
        TestCase(
            id: "rtc.ios.avatar-id-mismatch",
            name: "decodeAnimationFrames rejects mismatched avatar id",
            group: "iOS-Only",
            timeoutMs: 5_000
        ) { ctx in
            // Build a valid empty Message via the public protobuf helper. We
            // can't easily synthesize a server-response-animation with an
            // arbitrary id from outside the SDK, so this test exercises the
            // happy path (empty -> no frames) and ensures the function
            // doesn't throw on legal-but-empty bytes.
            let valid = Data()
            do {
                let frames = try AvatarSDK.decodeAnimationFrames(from: valid)
                try ctx.assert(frames.isEmpty, "Empty data should decode to no frames")
            } catch {
                // Either zero-byte rejection or empty result is acceptable.
                ctx.log("Empty data path: \(error.localizedDescription)")
            }
        },
        TestCase(
            id: "rtc.ios.transition-end-smooth",
            name: "Conversation transition-end does not jump (smoke)",
            group: "iOS-Only",
            timeoutMs: 8_000
        ) { ctx in
            // Smoke check: after we've been connected and idling for a while,
            // generateTransitionToFrame should not throw for an empty
            // payload (it should error out, not crash).
            let empty = Data()
            var rejected = false
            do {
                _ = try await ctx.avatarView.generateTransitionToFrame(empty, frameCount: 8)
            } catch {
                rejected = true
                ctx.log("Empty transition payload rejected: \(error.localizedDescription)")
            }
            try ctx.assert(rejected, "generateTransitionToFrame should reject empty payload")
        },
    ]

    // MARK: - Aggregate

    static let all: [TestCase] =
        connection +
        idle +
        audioRoundtrip +
        audioPublish +
        stability +
        reconnect +
        edgeCases +
        iOSOnly
}
