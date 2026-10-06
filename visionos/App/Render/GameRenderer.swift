// SPDX-License-Identifier: GPL-2.0-or-later
//
// The headset's frame loop: what core/vr/openxr_host.cpp's RunSession does on a PC.
// Every refresh of the display it tells the emulator the display refreshed and where the head
// will be, reads the controller and the hands, and shows the newest frame the game finished,
// turned to where the head points by the time it is shown (Shaders.metal).
//
// Rendering is foveated: Compositor Services draws the region the eyes look at at the drawable's
// full resolution (up to the render quality the settings ask for) and the rest at less, through
// the drawable's rasterization rate map.

import ARKit
import CompositorServices
import Metal
import QuartzCore
import simd
import SwiftUI

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + nanoseconds / TimeInterval(NSEC_PER_SEC)
    }
}

extension LayerRenderer.Clock.Instant {
    /// On CACurrentMediaTime's clock, which ARKit's timestamps are on.
    var seconds: TimeInterval {
        LayerRenderer.Clock.Instant.epoch.duration(to: self).timeInterval
    }
}

/// How the immersive space is drawn.
struct GameLayerConfiguration: CompositorLayerConfiguration {
    let foveation: Bool
    let renderQuality: Float

    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        // The game's frames are sRGB; they are written back as sRGB.
        configuration.colorFormat = .bgra8Unorm_srgb

        // Foveated rendering, where the system supports it.
        let foveated = foveation && capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveated
        if foveated {
            configuration.maxRenderQuality = .init(renderQuality)
        }
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveated ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: options)
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
    }
}

final class GameRenderer: @unchecked Sendable {
    private let layerRenderer: LayerRenderer
    private let settings: AstroSettings
    private let tracking = HeadsetTracking()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let layered: Bool

    /// The frame being shown, the emulator's until it is handed back.
    private var frame: AstroFrame?
    private var frameTexture: MTLTexture?

    private var lastPresentation: TimeInterval = 0
    private var refreshPeriod: TimeInterval = 1.0 / 90.0
    private var lastIpd: Float = 0
    private var framesSinceOptics = 0
    private var fovSamples = 0

    /// Called once the space is gone (the Digital Crown, or the system closed it).
    private var onEnd: (@Sendable () -> Void)?

    static func start(layerRenderer: LayerRenderer, settings: AstroSettings,
                      onEnd: @escaping @Sendable () -> Void) {
        guard let renderer = GameRenderer(layerRenderer: layerRenderer, settings: settings) else {
            LogFiles.log("The headset renderer could not be set up (Metal pipeline)")
            onEnd()
            return
        }
        renderer.onEnd = onEnd
        let configuration = layerRenderer.configuration
        LogFiles.log("Immersive space: layout \(configuration.layout == .layered ? "layered" : "dedicated"), "
                     + "foveation \(configuration.isFoveationEnabled)")
        let thread = Thread {
            renderer.run()
        }
        thread.name = "AstroQuest headset"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private init?(layerRenderer: LayerRenderer, settings: AstroSettings) {
        self.layerRenderer = layerRenderer
        self.settings = settings
        device = layerRenderer.device
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        commandQueue = queue
        let configuration = layerRenderer.configuration
        layered = configuration.layout == .layered

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Reprojection"
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "reprojectFragment")
        descriptor.colorAttachments[0].pixelFormat = configuration.colorFormat
        descriptor.depthAttachmentPixelFormat = configuration.depthFormat
        descriptor.maxVertexAmplificationCount = layered ? 2 : 1
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        pipeline = state

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .always
        depth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            return nil
        }
        self.depthState = depthState

        if configuration.isFoveationEnabled {
            layerRenderer.renderQuality = .init(settings.renderQuality)
        }
    }

    private func run() {
        // Tracking starts on its own time (asking for permission can take as long as the player
        // takes to answer); until it runs, the head and hands are simply not known yet.
        Task.detached { [tracking, settings] in
            await tracking.start(trackHands: settings.hands)
        }

        layerRenderer.waitUntilRunning()
        astro_core_set_session_running(true)
        while true {
            switch layerRenderer.state {
            case .paused:
                // The space is hidden (the headset came off, or something else is in front).
                astro_core_set_showing(false)
                layerRenderer.waitUntilRunning()
            case .running:
                autoreleasepool {
                    renderFrame()
                }
            case .invalidated:
                finish()
                return
            @unknown default:
                finish()
                return
            }
        }
    }

    private func finish() {
        astro_core_set_showing(false)
        astro_core_set_session_running(false)
        tracking.stop()
        if let frame {
            astro_core_release_frame(frame.slot)
        }
        frame = nil
        frameTexture = nil
        onEnd?()
        onEnd = nil
    }

    private func renderFrame() {
        guard let layerFrame = layerRenderer.queryNextFrame() else { return }

        layerFrame.startUpdate()
        PlayStationController.shared.poll()
        layerFrame.endUpdate()

        guard let timing = layerFrame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        // The display refreshed: the emulated headset refreshes in step with it.
        let presentation = timing.presentationTime.seconds
        if lastPresentation > 0 {
            let period = presentation - lastPresentation
            if period > 0.004 && period < 0.04 {
                refreshPeriod += (period - refreshPeriod) * 0.1
            }
        }
        lastPresentation = presentation
        astro_core_display_refresh(Float(1.0 / refreshPeriod))
        astro_core_set_showing(true)

        // Where the head will be when the frame the game draws next is shown.
        let predicted = presentation + Double(min(max(settings.predictMs, 0), 80)) / 1000.0
        if let anchor = tracking.deviceAnchor(at: predicted), anchor.isTracked {
            var pose = Self.pose(anchor.originFromAnchorTransform)
            astro_core_update_head(&pose, true)
        }
        tracking.updatePad(at: presentation)

        layerFrame.startSubmission()
        // A frame whose submission was started has to be ended, whatever happens.
        defer { layerFrame.endSubmission() }
        let drawables = layerFrame.queryDrawables()
        guard !drawables.isEmpty, let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // The newest frame of the game's; the one shown before goes back once the GPU is done
        // with what was drawn from it.
        var newFrame = AstroFrame()
        var retired: AstroFrame?
        if astro_core_take_frame(&newFrame), let pointer = newFrame.texture {
            retired = frame
            frame = newFrame
            frameTexture = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? MTLTexture
        }

        for drawable in drawables {
            let anchor = tracking.deviceAnchor(at: drawable.frameTiming.presentationTime.seconds)
            drawable.deviceAnchor = anchor
            noteOptics(drawable)
            encode(drawable: drawable, anchor: anchor, commandBuffer: commandBuffer)
            drawable.encodePresent(commandBuffer: commandBuffer)
        }

        if let retired {
            let slot = retired.slot
            commandBuffer.addCompletedHandler { _ in
                astro_core_release_frame(slot)
            }
        }
        commandBuffer.commit()
    }

    /// The distance between the eyes, and what the headset shows, for the emulator (which tells
    /// the game the headset's field of view when fov_of=headset, as on the PC).
    private func noteOptics(_ drawable: LayerRenderer.Drawable) {
        guard drawable.views.count == 2 else { return }
        let a = drawable.views[0].transform.columns.3
        let b = drawable.views[1].transform.columns.3
        let ipd = simd_length(SIMD3<Float>(a.x - b.x, a.y - b.y, a.z - b.z))
        framesSinceOptics += 1
        if ipd > 0.04 && ipd < 0.09 && (abs(ipd - lastIpd) > 0.0002 || framesSinceOptics > 600) {
            lastIpd = ipd
            framesSinceOptics = 0
            astro_core_update_ipd(ipd)
        }
        fovSamples += 1
        if fovSamples % 600 == 1 {
            // Both eyes together: the left eye's left and the right eye's right are the temples.
            let left = Self.tangents(drawable.computeProjection(viewIndex: 0))
            let right = Self.tangents(drawable.computeProjection(viewIndex: 1))
            astro_core_note_headset_fov(max(left.x, right.y), max(left.y, right.x),
                                        max(left.z, right.z), max(left.w, right.w))
        }
    }

    /// Left, right, up and down tangents of a view's projection.
    private static func tangents(_ projection: simd_float4x4) -> SIMD4<Float> {
        let p00 = projection.columns.0.x
        let p11 = projection.columns.1.y
        let p20 = projection.columns.2.x
        let p21 = projection.columns.2.y
        return SIMD4<Float>((1 - p20) / p00, (1 + p20) / p00, (1 + p21) / p11, (1 - p21) / p11)
    }

    private static func pose(_ transform: simd_float4x4) -> AstroPose {
        var pose = AstroPose()
        let q = simd_quatf(transform)
        pose.position = (transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        pose.orientation = (q.imag.x, q.imag.y, q.imag.z, q.real)
        return pose
    }

    /// What the shaders need for view `index` of the drawable to show the game's eye `index`.
    private func uniforms(drawable: LayerRenderer.Drawable, index: Int, anchor: DeviceAnchor?) -> AstroEyeUniforms {
        var eye = AstroEyeUniforms()
        guard let frame, frameTexture != nil else {
            eye.has_frame = 0
            return eye
        }
        let projection = drawable.computeProjection(viewIndex: index)
        let p00 = projection.columns.0.x
        let p11 = projection.columns.1.y
        let p20 = projection.columns.2.x
        let p21 = projection.columns.2.y
        // From normalized device coordinates to a direction in the view's space, on the plane at
        // distance one: x = (ndc.x + p20) / p00, y = (ndc.y + p21) / p11, z = -1.
        let unproject = simd_float3x3(columns: (
            SIMD3<Float>(1 / p00, 0, 0),
            SIMD3<Float>(0, 1 / p11, 0),
            SIMD3<Float>(p20 / p00, p21 / p11, -1)))
        // The view's orientation in the world...
        let world = (anchor?.originFromAnchorTransform ?? matrix_identity_float4x4) * drawable.views[index].transform
        let viewToWorld = simd_float3x3(columns: (
            SIMD3<Float>(world.columns.0.x, world.columns.0.y, world.columns.0.z),
            SIMD3<Float>(world.columns.1.x, world.columns.1.y, world.columns.1.z),
            SIMD3<Float>(world.columns.2.x, world.columns.2.y, world.columns.2.z)))
        // ...and back from the orientation the game drew the frame for.
        let drawn = simd_quatf(ix: frame.orientation.0, iy: frame.orientation.1, iz: frame.orientation.2,
                               r: frame.orientation.3)
        let worldToGame = simd_float3x3(drawn.inverse)
        let ray = worldToGame * viewToWorld * unproject
        let rows = ray.transpose
        eye.ray_x = SIMD4<Float>(rows.columns.0, 0)
        eye.ray_y = SIMD4<Float>(rows.columns.1, 0)
        eye.ray_z = SIMD4<Float>(rows.columns.2, 0)
        // "Out" is towards the temple: left for the left eye, right for the right one.
        eye.tangents = index == 0
            ? SIMD4<Float>(frame.tan_out, frame.tan_in, frame.tan_up, frame.tan_down)
            : SIMD4<Float>(frame.tan_in, frame.tan_out, frame.tan_up, frame.tan_down)
        // This eye's half of the frame, and the half texel at its edges.
        let halfTexel = 0.5 / Float(max(frame.width, 1))
        let left: Float = index == 0 ? 0.0 : 0.5
        eye.frame_x = SIMD4<Float>(left, 0.5, left + halfTexel, left + 0.5 - halfTexel)
        eye.has_frame = 1
        return eye
    }

    private func encode(drawable: LayerRenderer.Drawable, anchor: DeviceAnchor?, commandBuffer: MTLCommandBuffer) {
        let views = drawable.views
        var all = AstroFrameUniforms()
        all.eyes.0 = uniforms(drawable: drawable, index: 0, anchor: anchor)
        if views.count > 1 {
            all.eyes.1 = uniforms(drawable: drawable, index: 1, anchor: anchor)
        }

        if layered {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.colorTextures[0]
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.depthAttachment.texture = drawable.depthTextures[0]
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            // Not zero: the compositor leaves out what has no depth at all. Far away, though.
            pass.depthAttachment.clearDepth = 0.000000001
            pass.rasterizationRateMap = drawable.rasterizationRateMaps.first
            pass.renderTargetArrayLength = views.count
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.label = "Game frame"
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)
            encoder.setViewports(views.map { $0.textureMap.viewport })
            if views.count > 1 {
                var mappings = (0..<views.count).map {
                    MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                      renderTargetArrayIndexOffset: UInt32($0))
                }
                encoder.setVertexAmplificationCount(views.count, viewMappings: &mappings)
            }
            var base: UInt32 = 0
            encoder.setVertexBytes(&all, length: MemoryLayout<AstroFrameUniforms>.stride, index: 0)
            encoder.setVertexBytes(&base, length: MemoryLayout<UInt32>.stride, index: 1)
            encoder.setFragmentBytes(&all, length: MemoryLayout<AstroFrameUniforms>.stride, index: 0)
            encoder.setFragmentTexture(frameTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        } else {
            // A texture of its own for each eye.
            for (index, view) in views.enumerated() {
                let map = view.textureMap
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.colorTextures[map.textureIndex]
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                pass.depthAttachment.texture = drawable.depthTextures[map.textureIndex]
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = 0.000000001
                if drawable.rasterizationRateMaps.count == views.count {
                    pass.rasterizationRateMap = drawable.rasterizationRateMaps[index]
                }
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
                encoder.label = "Game frame, eye \(index)"
                encoder.setRenderPipelineState(pipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setCullMode(.none)
                encoder.setViewport(map.viewport)
                var base = UInt32(min(index, 1))
                encoder.setVertexBytes(&all, length: MemoryLayout<AstroFrameUniforms>.stride, index: 0)
                encoder.setVertexBytes(&base, length: MemoryLayout<UInt32>.stride, index: 1)
                encoder.setFragmentBytes(&all, length: MemoryLayout<AstroFrameUniforms>.stride, index: 0)
                encoder.setFragmentTexture(frameTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }
    }
}
