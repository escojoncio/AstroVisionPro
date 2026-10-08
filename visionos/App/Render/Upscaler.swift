// SPDX-License-Identifier: GPL-2.0-or-later
//
// Enlarges each eye of the game's picture with MetalFX's spatial scaler before it is put in front
// of the eyes (GameRenderer.swift). The headset's display has several pixels for each of the
// game's; drawn straight from the game's picture they are interpolated between four of its
// pixels, which blurs edges. MetalFX rebuilds the edges at the larger size instead, once per frame
// of the game's (not once per refresh of the display).
//
// The game hands both eyes side by side in one texture; MetalFX reads its input from the top
// left corner, so each eye is first copied into a texture of its own.

import Metal
import MetalFX

final class Upscaler {
    let eyeWidth: Int
    let eyeHeight: Int
    let pixelFormat: MTLPixelFormat
    let outputWidth: Int
    let outputHeight: Int
    /// The enlarged picture of each eye, left then right.
    let outputs: [MTLTexture]
    private let inputs: [MTLTexture]
    private let scalers: [MTLFXSpatialScaler]

    /// nil when MetalFX cannot do it on this device, for this format or size.
    init?(device: MTLDevice, eyeWidth: Int, eyeHeight: Int, pixelFormat: MTLPixelFormat, scale: Float) {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device), eyeWidth > 0, eyeHeight > 0 else {
            return nil
        }
        self.eyeWidth = eyeWidth
        self.eyeHeight = eyeHeight
        self.pixelFormat = pixelFormat
        // Even sizes, and no larger than a texture can be.
        outputWidth = min(Int((Float(eyeWidth) * scale / 2).rounded()) * 2, 8192)
        outputHeight = min(Int((Float(eyeHeight) * scale / 2).rounded()) * 2, 8192)

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = eyeWidth
        descriptor.inputHeight = eyeHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = pixelFormat
        descriptor.outputTextureFormat = pixelFormat
        // The game's picture is 8-bit and gamma-encoded, as a display shows it.
        descriptor.colorProcessingMode = .perceptual

        var scalers: [MTLFXSpatialScaler] = []
        for _ in 0..<2 {
            guard let scaler = descriptor.makeSpatialScaler(device: device) else {
                return nil
            }
            scalers.append(scaler)
        }
        self.scalers = scalers

        func texture(width: Int, height: Int, usage: MTLTextureUsage, label: String) -> MTLTexture? {
            let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width,
                                                                       height: height, mipmapped: false)
            description.usage = usage
            description.storageMode = .private
            let texture = device.makeTexture(descriptor: description)
            texture?.label = label
            return texture
        }
        var inputs: [MTLTexture] = []
        var outputs: [MTLTexture] = []
        for eye in 0..<2 {
            guard let input = texture(width: eyeWidth, height: eyeHeight, usage: scalers[eye].colorTextureUsage,
                                      label: "Game eye \(eye)"),
                  let output = texture(width: outputWidth, height: outputHeight,
                                       usage: scalers[eye].outputTextureUsage.union(.shaderRead),
                                       label: "Game eye \(eye), enlarged") else {
                return nil
            }
            inputs.append(input)
            outputs.append(output)
        }
        self.inputs = inputs
        self.outputs = outputs
    }

    func fits(eyeWidth: Int, eyeHeight: Int, pixelFormat: MTLPixelFormat) -> Bool {
        self.eyeWidth == eyeWidth && self.eyeHeight == eyeHeight && self.pixelFormat == pixelFormat
    }

    /// Enlarges both eyes of `frame` (the eyes side by side) into `outputs`.
    func encode(frame: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "Game eyes apart"
        for eye in 0..<2 {
            blit.copy(from: frame, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: eye * eyeWidth, y: 0, z: 0),
                      sourceSize: MTLSize(width: eyeWidth, height: eyeHeight, depth: 1),
                      to: inputs[eye], destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        for eye in 0..<2 {
            let scaler = scalers[eye]
            scaler.colorTexture = inputs[eye]
            scaler.outputTexture = outputs[eye]
            scaler.inputContentWidth = eyeWidth
            scaler.inputContentHeight = eyeHeight
            scaler.encode(commandBuffer: commandBuffer)
        }
    }
}
