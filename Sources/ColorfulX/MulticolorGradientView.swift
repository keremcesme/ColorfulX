//
//  MulticolorGradientView.swift
//  ColorfulX
//
//  Created by QAQ on 2023/12/3.
//

import ColorVector
import MetalKit

open class MulticolorGradientView: MetalView {
    public var parameters: Parameters = .init() {
        didSet {
            if oldValue != parameters {
                needsRender = true
            }
        }
    }

    var needsRender: Bool = false {
        didSet {
            if needsRender { refreshDisplayLinkPause() }
        }
    }

    private var computePipelineState: MTLComputePipelineState?
    /// Lets one frame be in flight at a time. Taken on the main thread and
    /// returned from Metal's completion thread, which an NSLock does not allow.
    private let frameInFlight = DispatchSemaphore(value: 1)

    public var renderScale: Double {
        get { metalLink?.scaleFactor ?? 1 }
        set {
            guard let metalLink, metalLink.scaleFactor != newValue else { return }
            metalLink.scaleFactor = newValue
            needsRender = true
        }
    }

    override public init() {
        super.init()

        if let device = metalLink?.metalDevice,
           let library = try? device.createColorfulLibrary(),
           let computeProgram = library.makeFunction(name: "blend_colors"),
           let pipelineState = try? device.makeComputePipelineState(function: computeProgram)
        {
            computePipelineState = pipelineState
        } else {
            computePipelineState = nil
        }
    }

    override func vsync() {
        super.vsync()
        renderIfNeeded()
    }

    override func hasPendingWork() -> Bool {
        needsRender
    }

    override func viewNeedsFreshFrame() {
        needsRender = true
    }

    func renderIfNeeded() {
        guard needsRender else { return }
        // Without a Metal link or pipeline state no frame can ever be drawn, so drop the request.
        guard metalLink != nil, computePipelineState != nil else {
            needsRender = false
            return
        }
        // A frame that could not be encoded leaves the request set for the next tick.
        if render() { needsRender = false }
    }

    /// Draws the current parameters and presents the frame with the surrounding Core Animation
    /// transaction, so it appears in the same commit as any layer change made alongside this call.
    /// Waits for a frame still in flight; the display link keeps presenting asynchronously.
    @discardableResult
    public func renderNow() -> Bool {
        guard metalLink != nil, computePipelineState != nil else {
            needsRender = false
            return false
        }
        let didRender = render(presentsWithTransaction: true)
        if didRender { needsRender = false }
        return didRender
    }

    /// Encodes and commits one frame. Returns false when nothing was drawn.
    @discardableResult
    func render() -> Bool {
        render(presentsWithTransaction: false)
    }

    /// A synchronous frame blocks until the previous one finishes, then presents once it is
    /// scheduled; an asynchronous frame is skipped while another is in flight.
    func render(presentsWithTransaction: Bool) -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)

        let frameInFlight = frameInFlight
        if presentsWithTransaction {
            frameInFlight.wait()
        } else if frameInFlight.wait(timeout: .now()) != .success {
            CATransaction.commit()
            return false
        }

        guard let metalLink,
              let computePipelineState,
              metalLink.metalLayer.drawableSize.width >= 1,
              metalLink.metalLayer.drawableSize.height >= 1,
              let drawable = metalLink.metalLayer.nextDrawable(),
              let commandBuffer = metalLink.commandQueue.makeCommandBuffer(),
              let commandEncoder = commandBuffer.makeComputeCommandEncoder()
        else {
            frameInFlight.signal()
            CATransaction.commit()
            return false
        }
        commandBuffer.addCompletedHandler { _ in
            frameInFlight.signal()
        }

        var shaderPoints: [(simd_float2, simd_float4)] = Array(
            repeating: (
                simd_float2(0.0, 0.0),
                simd_float4(0.0, 0.0, 0.0, 0.0),
            ),
            count: Uniforms.COLOR_SLOT,
        )

        let parms = parameters

        for i in 0 ..< parms.points.count {
            let point = parms.points[i]
            let color = point.color.color(in: .lab)
            shaderPoints[i] = (
                simd_float2(Float(point.position.x), Float(point.position.y)),
                simd_float4(color.v),
            )
        }

        var uniforms = Uniforms(
            pointCount: simd_int1(parms.points.count),
            bias: simd_float1(parms.bias),
            power: simd_float1(parms.power),
            noise: simd_float1(parms.noise),

            point0: shaderPoints[0].0,
            point1: shaderPoints[1].0,
            point2: shaderPoints[2].0,
            point3: shaderPoints[3].0,
            point4: shaderPoints[4].0,
            point5: shaderPoints[5].0,
            point6: shaderPoints[6].0,
            point7: shaderPoints[7].0,

            color0: shaderPoints[0].1,
            color1: shaderPoints[1].1,
            color2: shaderPoints[2].1,
            color3: shaderPoints[3].1,
            color4: shaderPoints[4].1,
            color5: shaderPoints[5].1,
            color6: shaderPoints[6].1,
            color7: shaderPoints[7].1,
        )

        commandEncoder.setComputePipelineState(computePipelineState)
        commandEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        commandEncoder.setTexture(drawable.texture, index: 4)

        // Non-uniform threadgroups sized from the pipeline; no thread falls outside the texture.
        let threadWidth = computePipelineState.threadExecutionWidth
        let threadHeight = max(1, computePipelineState.maxTotalThreadsPerThreadgroup / threadWidth)
        let gridSize = MTLSizeMake(drawable.texture.width, drawable.texture.height, 1)

        commandEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: MTLSizeMake(threadWidth, threadHeight, 1))
        commandEncoder.endEncoding()

        if presentsWithTransaction {
            let layer = metalLink.metalLayer
            layer.presentsWithTransaction = true
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            drawable.present()
            // The flag stays set because nothing presents while idle; the next asynchronous frame clears it.
        } else {
            let layer = metalLink.metalLayer
            if layer.presentsWithTransaction { layer.presentsWithTransaction = false }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        CATransaction.commit()
        return true
    }
}
