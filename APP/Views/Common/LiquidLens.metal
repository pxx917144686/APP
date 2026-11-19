#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Core of the Good Machines Lab liquid-glass lens, reduced to a single
// full-screen backdrop pass: a rounded lens SDF, a refracting normal, subtle
// chromatic dispersion, a moving caustic wave and a specular rim.
static float sdRoundedBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

[[ stitchable ]] half4 liquidLens(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float time,
    float intensity,
    float radius
) {
    float2 center = size * 0.5;
    float2 halfSize = size * float2(0.40, 0.31);
    float lensRadius = radius * min(size.x, size.y);
    float2 p = position - center;

    // A slowly moving caustic warp so the surface reads as liquid, not a
    // static bubble. It is deliberately weak over the whole screen.
    float2 caustic = float2(
        sin(position.y * 0.028 + time * 0.75) + 0.45 * sin(position.y * 0.061 - time * 0.42),
        cos(position.x * 0.025 - time * 0.68) + 0.45 * cos(position.x * 0.054 + time * 0.39)
    ) * (2.0 * intensity);

    // Rounded lens distance and gradient.
    float d = sdRoundedBox(p, halfSize, lensRadius);
    float aa = 1.25;
    float inside = 1.0 - smoothstep(-aa, aa, d);
    float2 e = float2(1.0, 0.0);
    float2 g = float2(
        d - sdRoundedBox(p - e, halfSize, lensRadius),
        d - sdRoundedBox(p - float2(0.0, 1.0), halfSize, lensRadius)
    );
    g = normalize(g + float2(0.0001));

    // Edge-only refraction: strongest at the rim, flat in the centre.
    float t = clamp(max(-d, 0.0) / max(lensRadius * 0.34, 1.0), 0.0, 1.0);
    float bend = pow(1.0 - t, 1.7) * intensity * 18.0;
    float2 refractOffset = -g * bend;

    // Tiny spectral split at the rim, as in the reference shader.
    float dispersion = inside * pow(1.0 - t, 2.0) * intensity * 1.8;
    float2 base = position + caustic + refractOffset;

    half4 redSample = layer.sample(base + g * dispersion);
    half4 greenSample = layer.sample(base);
    half4 blueSample = layer.sample(base - g * dispersion);
    half4 color = half4(redSample.r, greenSample.g, blueSample.b, max(greenSample.a, half(0.85)));

    // Specular rim: a thin bright line along the boundary.
    float rim = exp(-abs(d) / 1.8) * intensity * 0.22;
    color.rgb += half3(rim);

    // Preserve the untouched background outside the lens, blending only the
    // small caustic warp there.
    half4 original = layer.sample(position + caustic * 0.35);
    return mix(original, color, inside);
}
