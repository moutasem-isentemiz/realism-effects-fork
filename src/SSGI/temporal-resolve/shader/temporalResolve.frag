﻿// a basic shader to implement temporal resolving

uniform sampler2D inputTexture;
uniform sampler2D accumulatedTexture;

uniform sampler2D velocityTexture;

uniform sampler2D depthTexture;
uniform sampler2D lastDepthTexture;

uniform float blend;
uniform float correction;
uniform float samples;
uniform vec2 invTexSize;

varying vec2 vUv;

#define FLOAT_EPSILON           0.00001
#define FLOAT_ONE_MINUS_EPSILON 0.9999
#define ALPHA_STEP              0.001

#include <packing>

// idea from: https://www.elopezr.com/temporal-aa-and-the-quest-for-the-holy-trail/
vec3 transformColor(vec3 color) {
#ifdef logTransform
    return log(max(color, vec3(FLOAT_EPSILON)));
#else
    return color;
#endif
}

vec3 undoColorTransform(vec3 color) {
#ifdef logTransform
    return exp(color);
#else
    return color;
#endif
}

void main() {
    vec4 inputTexel = textureLod(inputTexture, vUv, 0.0);

    float depth = unpackRGBAToDepth(textureLod(depthTexture, vUv, 0.));

    bool isBackground = depth > FLOAT_ONE_MINUS_EPSILON;

    vec3 inputColor = transformColor(inputTexel.rgb);
    float alpha = inputTexel.a;

    vec4 accumulatedTexel;
    vec3 accumulatedColor;

    vec4 velocity = textureLod(velocityTexture, vUv, 0.0);
    velocity.xy = unpackRGBATo2Half(velocity) * 2. - 1.;

    vec2 reprojectedUv = vUv - velocity.xy;

    vec3 minNeighborColor = inputColor;
    vec3 maxNeighborColor = inputColor;

    vec4 neighborTexel;
    vec3 col;
    vec2 neighborUv;
    vec2 offset;

    float maxDepth = 0.;
    float lastMaxDepth = 0.;

    float neighborDepth;
    float lastNeighborDepth;
    float colorCount = 1.0;

#if defined(dilation) || defined(neighborhoodClamping)
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            if (x != 0 || y != 0) {
                offset = vec2(x, y) * invTexSize;
                neighborUv = vUv + offset;

                if (all(greaterThanEqual(neighborUv, vec2(0.))) && all(lessThanEqual(neighborUv, vec2(1.)))) {
                    //                 vec4 neigborDepthTexel = textureLod(velocityTexture, vUv + offset, 0.0);
                    //                 neighborDepth = 1. - neigborDepthTexel.b;

                    //                 int absX = abs(x);
                    //                 int absY = abs(y);

                    //                 if (absX <= 1 && absY <= 1) {
                    // #ifdef dilation

                    //                     // prevents the flickering at the edges of geometries due to treating background pixels differently
                    //                     if (neighborDepth > 0.) isBackground = false;

                    //                     if (neighborDepth > maxDepth) maxDepth = neighborDepth;

                    //                     vec2 reprojectedNeighborUv = reprojectedUv + vec2(x, y) * invTexSize;

                    //                     vec4 lastNeigborDepthTexel = textureLod(lastVelocityTexture, reprojectedNeighborUv, 0.0);
                    //                     lastNeighborDepth = 1. - lastNeigborDepthTexel.b;

                    //                     if (lastNeighborDepth > lastMaxDepth) lastMaxDepth = lastNeighborDepth;
                    // #endif
                    //                 }

    #ifdef neighborhoodClamping
                    // the neighbor pixel is invalid if it's too far away from this pixel

                    if (abs(depth - neighborDepth) < maxNeighborDepthDifference) {
                        neighborTexel = textureLod(inputTexture, neighborUv, 0.0);

                        col = neighborTexel.rgb;
                        col = transformColor(col);

                        minNeighborColor = min(col, minNeighborColor);
                        maxNeighborColor = max(col, maxNeighborColor);
                    }

    #endif
                }
            }
        }
    }

#endif

    // velocity
    reprojectedUv = vUv - velocity.xy;

    // depth
    // #ifdef dilation
    //     depth = maxDepth;
    //     lastDepth = lastMaxDepth;
    // #endif

    float depthDiff = 1.0;

    // the reprojected UV coordinates are inside the view
    if (all(greaterThanEqual(reprojectedUv, vec2(0.))) && all(lessThanEqual(reprojectedUv, vec2(1.)))) {
        float lastDepth = unpackRGBAToDepth(textureLod(lastDepthTexture, reprojectedUv, 0.));

        depthDiff = abs(depth - lastDepth);

        // reproject the last frame if there was no disocclusion
        if (depthDiff < maxNeighborDepthDifference) {
            accumulatedTexel = textureLod(accumulatedTexture, reprojectedUv, 0.0);

            alpha = min(alpha, accumulatedTexel.a);
            alpha = min(alpha, blend);
            accumulatedColor = transformColor(accumulatedTexel.rgb);

            alpha += ALPHA_STEP;

#ifdef neighborhoodClamping
            vec3 clampedColor = clamp(accumulatedColor, minNeighborColor, maxNeighborColor);

            accumulatedColor = mix(accumulatedColor, clampedColor, correction);
#endif
        } else {
            accumulatedColor = inputColor;
            alpha = 0.0;
        }
    } else {
        accumulatedColor = inputColor;
        alpha = 0.0;
    }

    vec3 outputColor = inputColor;

    float pixelSample = alpha / ALPHA_STEP + 1.0;
    float temporalResolveMix = 1. - 1. / pixelSample;
    temporalResolveMix = min(temporalResolveMix, blend);

    float movement = length(velocity.xy) * 100.;
    if (movement > 1.) movement = 1.;
        // temporalResolveMix -= 0.375 * movement;

// the user's shader to compose a final outputColor from the inputTexel and accumulatedTexel
#ifdef useCustomComposeShader
    customComposeShader
#else
    outputColor = mix(inputColor, accumulatedColor, temporalResolveMix);
#endif

        gl_FragColor = vec4(undoColorTransform(outputColor), alpha);

    // gl_FragColor = vec4(movement);

    // if (depthDiff > maxNeighborDepthDifference) gl_FragColor = vec4(0., 1., 0., 1.);
}