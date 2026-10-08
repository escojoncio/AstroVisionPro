// SPDX-License-Identifier: GPL-2.0-or-later
//
// Smooths the edges of the game's picture (FXAA, Shaders.metal edgeFragment) once per frame of
// the game's, into a texture of the same size and layout (both eyes side by side), which the
// headset then shows instead of the game's own.

import Metal

final class EdgeSmoother {
    private let pipeline: MTLRenderPipelineState
    private let device: MTLDevice
    private(set) var output: MTLTexture?

    init?(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Edge smoothing"
        descriptor.vertexFunction = library.makeFunction(name: "edgeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "edgeFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil,
              let state = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        pipeline = state
        self.device = device
        self.pixelFormat = pixelFormat
    }

    let pixelFormat: MTLPixelFormat

    /// Smooths `frame` into `output`; false when it could not.
    func encode(frame: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        guard frame.pixelFormat == pixelFormat else { return false }
        if output?.width != frame.width || output?.height != frame.height {
            let description = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: frame.width, height: frame.height, mipmapped: false)
            description.usage = [.renderTarget, .shaderRead]
            description.storageMode = .private
            output = device.makeTexture(descriptor: description)
            output?.label = "Game picture, edges smoothed"
        }
        guard let output else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "Edge smoothing"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame, index: 0)
        var texel = SIMD2<Float>(1.0 / Float(frame.width), 1.0 / Float(frame.height))
        encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
}
