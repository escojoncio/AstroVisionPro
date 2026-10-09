// SPDX-License-Identifier: GPL-2.0-or-later
//
// Antialiasing of the game's picture: SMAA 1x (Jimenez et al., Render/SMAA/), once per frame of
// the game's, into a texture of the same size and layout (both eyes side by side), which the
// headset then shows instead of the game's own. It finds the edges by their contrast, works out
// from the shape of each edge (along lines, diagonals and corners) how much of a pixel each side
// covers, and blends only there: it needs no motion vectors and leaves textures as sharp as they
// were, unlike FXAA, which blurs everything that has contrast.
//
// Three passes: edges (RG8, cleared to none), blending weights (RGBA8, with SMAA's area and search
// tables), and the picture blended with its neighbours by those weights.

import Foundation
import Metal

final class EdgeSmoother {
    private let device: MTLDevice
    private let edgePipeline: MTLRenderPipelineState
    private let weightPipeline: MTLRenderPipelineState
    private let blendPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let areaTexture: MTLTexture
    private let searchTexture: MTLTexture
    private var edges: MTLTexture?
    private var weights: MTLTexture?
    private(set) var output: MTLTexture?
    let pixelFormat: MTLPixelFormat

    init?(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) {
        func pipeline(_ name: String, _ vertex: String, _ fragment: String,
                      _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = name
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
                LogFiles.log("SMAA: no \(vertex)/\(fragment) in the app's shaders")
                return nil
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                LogFiles.log("SMAA: \(name) not made: \(error.localizedDescription)")
                return nil
            }
        }
        guard let edge = pipeline("SMAA edges", "smaaEdgeVertex", "smaaEdgeFragment", .rg8Unorm),
              let weight = pipeline("SMAA weights", "smaaWeightVertex", "smaaWeightFragment", .rgba8Unorm),
              let blend = pipeline("SMAA blending", "smaaBlendVertex", "smaaBlendFragment", pixelFormat)
        else {
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              let area = Self.table(device: device, name: "AreaTex", width: 160, height: 560,
                                    format: .rg8Unorm, bytesPerPixel: 2),
              let search = Self.table(device: device, name: "SearchTex", width: 64, height: 16,
                                      format: .r8Unorm, bytesPerPixel: 1)
        else {
            return nil
        }
        self.device = device
        self.pixelFormat = pixelFormat
        edgePipeline = edge
        weightPipeline = weight
        blendPipeline = blend
        self.sampler = sampler
        areaTexture = area
        searchTexture = search
    }

    /// One of SMAA's precomputed tables, from the app's resources.
    private static func table(device: MTLDevice, name: String, width: Int, height: Int,
                              format: MTLPixelFormat, bytesPerPixel: Int) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "bin"),
              let data = try? Data(contentsOf: url), data.count == width * height * bytesPerPixel
        else {
            LogFiles.log("SMAA: \(name).bin missing or not \(width)x\(height)")
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        data.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * bytesPerPixel)
        }
        texture.label = "SMAA \(name)"
        return texture
    }

    private func target(_ texture: MTLTexture?, _ format: MTLPixelFormat, _ width: Int,
                        _ height: Int, _ label: String) -> MTLTexture? {
        if let texture, texture.width == width, texture.height == height {
            return texture
        }
        let description = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        description.usage = [.renderTarget, .shaderRead]
        description.storageMode = .private
        let made = device.makeTexture(descriptor: description)
        made?.label = label
        return made
    }

    private func pass(_ commandBuffer: MTLCommandBuffer, into texture: MTLTexture, clear: Bool,
                      _ label: String, _ body: (MTLRenderCommandEncoder) -> Void) -> Bool {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.label = label
        body(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// Antialiases `frame` into `output`; false when it could not.
    func encode(frame: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        guard frame.pixelFormat == pixelFormat else { return false }
        let width = frame.width
        let height = frame.height
        edges = target(edges, .rg8Unorm, width, height, "SMAA edges")
        weights = target(weights, .rgba8Unorm, width, height, "SMAA weights")
        output = target(output, pixelFormat, width, height, "Game picture, antialiased")
        guard let edges, let weights, let output else { return false }

        // SMAA_RT_METRICS: (1/width, 1/height, width, height).
        var metrics = SIMD4<Float>(1.0 / Float(width), 1.0 / Float(height), Float(width), Float(height))
        let size = MemoryLayout<SIMD4<Float>>.stride
        let common: (MTLRenderCommandEncoder) -> Void = { encoder in
            encoder.setVertexBytes(&metrics, length: size, index: 0)
            encoder.setFragmentBytes(&metrics, length: size, index: 0)
        }
        guard pass(commandBuffer, into: edges, clear: true, "SMAA edges", { encoder in
            encoder.setRenderPipelineState(self.edgePipeline)
            common(encoder)
            encoder.setFragmentTexture(frame, index: 1)
            encoder.setFragmentSamplerState(self.sampler, index: 1)
        }) else { return false }
        guard pass(commandBuffer, into: weights, clear: true, "SMAA weights", { encoder in
            encoder.setRenderPipelineState(self.weightPipeline)
            common(encoder)
            encoder.setFragmentTexture(edges, index: 1)
            encoder.setFragmentTexture(self.areaTexture, index: 2)
            encoder.setFragmentTexture(self.searchTexture, index: 3)
            for index in 1...3 {
                encoder.setFragmentSamplerState(self.sampler, index: index)
            }
        }) else { return false }
        return pass(commandBuffer, into: output, clear: false, "SMAA blending") { encoder in
            encoder.setRenderPipelineState(self.blendPipeline)
            common(encoder)
            encoder.setFragmentTexture(frame, index: 1)
            encoder.setFragmentTexture(weights, index: 2)
            encoder.setFragmentSamplerState(self.sampler, index: 1)
            encoder.setFragmentSamplerState(self.sampler, index: 2)
        }
    }
}
