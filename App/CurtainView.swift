import AppKit
import MetalKit
import os.log

/// Field order and types must match `Uniforms` in the shader source below.
private struct CurtainUniforms {
    var size: SIMD2<Float>
    var lineWidth: Float
    var elapsed: Float
    var coverElapsed: Float
    var revealElapsed: Float
    var coverDuration: Float
    var revealDuration: Float
    var softness: Float
    var glowStrength: Float
    var glowWidth: Float
    var style: Int32
}

/// The fabric is procedural, one fragment-shader pass per frame: a few thousand stroked
/// segments a frame would cost Core Graphics tens of milliseconds at 5K.
final class CurtainView: MTKView, MTKViewDelegate {
    private static let shared: (device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState)? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            os_log("curtain: no Metal device")
            return nil
        }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "curtainVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "curtainFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return (device, queue, try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            os_log("curtain: shader failed: %{public}@", String(describing: error))
            return nil
        }
    }()

    static var isAvailable: Bool { shared != nil }

    var source: (() -> (CurtainFrame, CurtainStyle)?)?

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isHidden = !isActive
            isPaused = !isActive
        }
    }

    init(frame: NSRect) {
        super.init(frame: frame, device: Self.shared?.device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        isPaused = true
        isHidden = true
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.isOpaque = false
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private static func uniforms(_ frame: CurtainFrame, _ style: CurtainStyle,
                                 drawable: CGSize) -> CurtainUniforms {
        let width = Float(drawable.width)
        let height = Float(drawable.height)
        let reveal: Float = frame.revealElapsed.map { Float($0) } ?? -1
        return CurtainUniforms(size: SIMD2<Float>(width, height),
                               lineWidth: max(1, width / 1100),
                               elapsed: Float(frame.elapsed),
                               coverElapsed: Float(frame.elapsed),
                               revealElapsed: reveal,
                               coverDuration: Float(style.coverDuration),
                               revealDuration: Float(style.revealDuration),
                               softness: style.softness,
                               glowStrength: style.glowStrength,
                               glowWidth: style.glowWidth,
                               style: style.shaderIndex)
    }

    func draw(in view: MTKView) {
        guard let shared = Self.shared,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = shared.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let current = source?() {
            var uniforms = Self.uniforms(current.0, current.1, drawable: drawableSize)
            encoder.setRenderPipelineState(shared.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CurtainUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Compiled at launch because the app is built with plain swiftc, which has no Metal
/// toolchain step. The math mirrors the canvas prototypes in the design artifact.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;
    float lineWidth;
    float elapsed;
    float coverElapsed;
    float revealElapsed;
    float coverDuration;
    float revealDuration;
    float softness;
    float glowStrength;
    float glowWidth;
    int style;
};

struct VOut { float4 position [[position]]; };

vertex VOut curtainVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

constant float ANGLE = -0.62;

static float ease(float x) { return smoothstep(0.0, 1.0, x); }
static float gauss(float x, float w) { return exp(-(x * x) / (2.0 * w * w)); }
static float wrap(float x, float p) { return x - p * floor(x / p); }

static float lineCount(int style) {
    switch (style) {
        case 0: return 90.0;
        case 1: return 46.0;
        case 2: return 80.0;
        default: return 120.0;
    }
}

static float widthScale(int style) {
    switch (style) {
        case 1: return 1.4;
        case 3: return 0.8;
        default: return 1.0;
    }
}

static float fold(int style, float nu, float nv, float a) {
    switch (style) {
        case 0: return 0.025 * sin(nv * 7.0 + a * 0.8 + nu * 4.0) + 0.012 * sin(nv * 16.0 - a * 1.1 + nu * 7.0);
        case 1: return 0.006 * sin(nv * 20.0 + a * 2.0 + nu * 10.0);
        case 2: return 0.04 * sin(nv * 5.0 - a * 1.6 + nu * 2.5) + 0.015 * sin(nv * 11.0 - a * 2.3 - nu * 6.0);
        default: return 0.0;
    }
}

static float light(int style, float nu, float nv, float slope, float i, float a) {
    switch (style) {
        case 0: {
            float sheen = wrap(a * 0.22, 1.8) - 0.9;
            return (0.05 + 0.35 * max(0.0, slope * 2.5 + 0.25)) * (0.25 + 1.4 * gauss(nv - nu * 0.6 - sheen, 0.12));
        }
        case 1: {
            float h = wrap(a - i * 0.07, 3.2) / 3.2;
            float behind = (h * 1.6 - 0.8) - nv;
            if (behind < 0.0) return 0.0;
            return (0.9 * exp(-behind * 7.0) + 0.08) * (1.0 - ease((h - 0.85) / 0.15));
        }
        case 2:
            return 0.04 + 0.55 * max(0.0, slope * 2.0 + 0.15);
        default: {
            float sweep = sin(a * 0.7) * 0.7;
            return 0.04 + 0.6 * gauss(nv - sweep, 0.22);
        }
    }
}

fragment float4 curtainFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    if (u.style < 0) return float4(0.0);
    float2 d = in.position.xy - u.size * 0.5;
    float diag = length(u.size);
    float ca = cos(ANGLE), sa = sin(ANGLE);
    float along = d.x * ca + d.y * sa;
    float across = -d.x * sa + d.y * ca;
    float nv = along / diag;
    float s = nv + 0.5;
    float a = u.elapsed;

    float count = lineCount(u.style);
    float gap = diag / count;
    float shifted = across - diag * fold(u.style, across / diag, nv, a);
    float index = round((shifted + diag * 0.5) / gap);
    float lineAt = -diag * 0.5 + index * gap;
    float nu = lineAt / diag;
    float e = 0.002;
    float slope = (fold(u.style, nu, nv + e, a) - fold(u.style, nu, nv - e, a)) / (2.0 * e);
    float halfWidth = u.lineWidth * widthScale(u.style) * 0.5;
    float stroke = clamp(halfWidth + 0.5 - abs(shifted - lineAt), 0.0, 1.0);
    bool revealing = u.revealElapsed >= 0.0;
    float fade = revealing ? 1.0 - ease((u.revealElapsed - 0.3) / 1.0) : 1.0;
    float fabric = min(1.0, stroke * light(u.style, nu, nv, slope, index, a) * fade);

    float coverage = 1.0;
    float glow = 0.0;
    if (u.style == 1) {
        float stripe = round((across + diag * 0.5) / gap);
        float fromCenter = abs(across - (-diag * 0.5 + stripe * gap));
        float delay = (stripe / count) * 0.6;
        float open = 0.0;
        if (revealing) {
            open = ease((u.revealElapsed - delay) / 0.5);
        } else if (u.coverElapsed < u.coverDuration) {
            open = 1.0 - ease((u.coverElapsed - delay) / 0.5);
        }
        if (open <= 0.0) coverage = 1.0;
        else if (open >= 1.0) coverage = 0.0;
        else coverage = clamp(fromCenter - gap * 0.5 * open + 0.5, 0.0, 1.0);
    } else {
        float soft = max(u.softness, 0.001);
        float t = revealing ? u.revealElapsed : u.coverElapsed;
        float duration = revealing ? u.revealDuration : u.coverDuration;
        if (revealing || t < duration) {
            float front = -soft + ease(t / duration) * (1.0 + 2.0 * soft);
            float ahead = clamp((s - (front - soft)) / soft, 0.0, 1.0);
            coverage = revealing ? ahead : 1.0 - ahead;
            float strength = revealing
                ? u.glowStrength * (1.0 - ease((t - (duration - 0.3)) / 0.4))
                : u.glowStrength * (1.0 - ease((t - duration + 0.3) / 0.3));
            if (u.glowWidth > 0.0) {
                glow = 0.85 * strength * max(0.0, 1.0 - abs(s - front) / (u.glowWidth * 0.5));
            }
        }
    }

    float3 rgb = float3(coverage * fabric);
    float alpha = coverage;
    rgb = glow + (1.0 - glow) * rgb;
    alpha = glow + (1.0 - glow) * alpha;
    return float4(rgb, alpha);
}
"""
