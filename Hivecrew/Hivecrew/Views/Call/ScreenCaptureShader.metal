//
//  ScreenCaptureShader.metal
//  Hivecrew
//
//  Vertex-warped mesh shader that continuously distorts a screenshot toward
//  a sink point, producing a cloth-sucked-into-a-slot effect — the image
//  stretches, funnels, and pinches laterally as it's pulled in.
//

#include <metal_stdlib>
using namespace metal;

// Must match SuckUniforms in Swift
struct Uniforms {
    float2 sinkPoint;     // normalized [0,1], origin bottom-left
    float  progress;      // 0 → 1
    float  aspectRatio;   // screen width / height
    float  flashIntensity;
    float  _pad;
};

struct VertexIn {
    float2 position [[attribute(0)]];  // [0,1] grid, bottom-left origin
    float2 texcoord [[attribute(1)]];  // [0,1], top-left origin
};

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
    float  opacity;
};

// MARK: - Vertex Shader

vertex VertexOut suckVertexShader(
    VertexIn in [[stage_in]],
    constant Uniforms &u [[buffer(1)]]
) {
    float2 pos  = in.position;
    float2 sink = u.sinkPoint;
    float  t    = u.progress;

    // Aspect-corrected distance to sink
    float2 diff = pos - sink;
    diff.x *= u.aspectRatio;
    float dist    = length(diff);
    float maxDist = length(float2(u.aspectRatio, 1.0));
    float ndist   = saturate(dist / maxDist);

    // Staggered pull: vertices near the sink start moving first,
    // far vertices begin later — creates a propagating wave front.
    float startTime = ndist * 0.45;
    float vertexT   = saturate((t - startTime) / max(1.0 - startTime, 0.001));
    float pull      = pow(vertexT, 1.6);

    // Move toward sink
    float2 newPos = mix(pos, sink, pull);

    // Lateral pinch: compress the axis perpendicular to the pull
    // direction so the fabric funnels into a narrow stream.
    float2 toSink    = sink - pos;
    float  toSinkLen = length(toSink);
    if (toSinkLen > 0.001) {
        float2 pullDir = normalize(toSink);
        float2 perpDir = float2(-pullDir.y, pullDir.x);

        // Project offset from sink onto the perpendicular axis
        float2 fromSink  = newPos - sink;
        float  perpComp  = dot(fromSink, perpDir);
        float  pullComp  = dot(fromSink, pullDir);

        // Squeeze the perpendicular component as pull increases
        float pinch = mix(1.0, 0.02, pow(pull, 1.2));
        fromSink = pullDir * pullComp + perpDir * perpComp * pinch;
        newPos = sink + fromSink;
    }

    // Compress along pull direction (accelerating collapse)
    float scale = mix(1.0, 0.005, pull * pull);
    newPos = sink + (newPos - sink) * scale;

    // Fabric ripple perpendicular to pull direction (subtle waves)
    if (toSinkLen > 0.001) {
        float2 perpDir = normalize(float2(-toSink.y, toSink.x));
        float ripple = sin(ndist * 22.0 - t * 18.0) * 0.005 * pull * (1.0 - pull);
        newPos += perpDir * ripple;
    }

    // Convert to Metal NDC  ([-1,1], y-up)
    float2 ndc = newPos * 2.0 - 1.0;

    // Opacity: fade as pulled in, plus global fade at end
    float opacity = 1.0 - smoothstep(0.5, 0.93, pull);
    opacity *= 1.0 - smoothstep(0.88, 1.0, t);

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texcoord = in.texcoord;
    out.opacity  = opacity;
    return out;
}

// MARK: - Fragment Shader

fragment float4 suckFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]],
    constant Uniforms &u [[buffer(1)]]
) {
    float4 color = tex.sample(smp, in.texcoord);
    color.a *= in.opacity;

    // Camera-flash overlay (white mix, decays quickly)
    color.rgb = mix(color.rgb, float3(1.0), u.flashIntensity * color.a);

    return color;
}
