vec3 screenSpaceToWorldSpace(const vec2 uv, const float depth, mat4 curMatrixWorld) {
    vec4 ndc = vec4(
        (uv.x - 0.5) * 2.0,
        (uv.y - 0.5) * 2.0,
        (depth - 0.5) * 2.0,
        1.0);

    vec4 clip = projectionMatrixInverse * ndc;
    vec4 view = curMatrixWorld * (clip / clip.w);

    return view.xyz;
}

vec2 viewSpaceToScreenSpace(vec3 position) {
    vec4 projectedCoord = projectionMatrix * vec4(position, 1.0);
    projectedCoord.xy /= projectedCoord.w;
    // [-1, 1] --> [0, 1] (NDC to screen position)
    projectedCoord.xy = projectedCoord.xy * 0.5 + 0.5;

    return projectedCoord.xy;
}

// idea from: https://www.elopezr.com/temporal-aa-and-the-quest-for-the-holy-trail/
vec3 transformColor(vec3 color) {
#ifdef logTransform
    return log(max(color, vec3(EPSILON)));
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

void getNeighborhoodAABB(sampler2D tex, vec2 uv, inout vec3 minNeighborColor, inout vec3 maxNeighborColor) {
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            if (x != 0 || y != 0) {
                vec2 offset = vec2(x, y) * invTexSize;
                vec2 neighborUv = uv + offset;

                vec4 neighborTexel = textureLod(tex, neighborUv, 0.0);

                vec3 col = neighborTexel.rgb;

#ifdef logTransform
                col = transformColor(col);
#endif

                minNeighborColor = min(col, minNeighborColor);
                maxNeighborColor = max(col, maxNeighborColor);
            }
        }
    }
}

bool planeDistanceDisocclusionCheck(vec3 worldPos, vec3 lastWorldPos, vec3 worldNormal) {
    vec3 toCurrent = worldPos - lastWorldPos;
    float distToPlane = abs(dot(toCurrent, worldNormal));

    float worldDistFactor = clamp(distance(worldPos, cameraPos) / 100., 0.1, 1.);

    return distToPlane > depthDistance * worldDistFactor;
}

bool normalsDisocclusionCheck(vec3 currentNormal, vec3 lastNormal, vec3 worldPos) {
    float worldDistFactor = clamp(distance(worldPos, cameraPos) / 100., 0.1, 1.);

    return pow(abs(dot(currentNormal, lastNormal)), 2.0) > normalDistance * worldDistFactor;
}

bool worldDistanceDisocclusionCheck(vec3 worldPos, vec3 lastWorldPos, float depth) {
    float worldDistFactor = clamp(distance(worldPos, cameraPos) / 100., 0.1, 1.);

    return distance(worldPos, lastWorldPos) > worldDistance * worldDistFactor;
}

bool validateReprojectedUV(vec2 reprojectedUv, float depth, vec3 worldPos, vec3 worldNormal) {
    if (any(lessThan(reprojectedUv, vec2(0.))) || any(greaterThan(reprojectedUv, vec2(1.)))) return false;

#ifdef neighborhoodClamping
    return true;
#endif

    vec4 lastNormalTexel = textureLod(lastNormalTexture, reprojectedUv, 0.);
    vec3 lastNormal = unpackRGBToNormal(lastNormalTexel.xyz);
    vec3 lastWorldNormal = normalize((vec4(lastNormal, 1.) * viewMatrix).xyz);

    if (normalsDisocclusionCheck(worldNormal, lastWorldNormal, worldPos)) return false;

    // the reprojected UV coordinates are inside the view
    float lastDepth = unpackRGBAToDepth(textureLod(lastDepthTexture, reprojectedUv, 0.));
    vec3 lastWorldPos = screenSpaceToWorldSpace(reprojectedUv, lastDepth, prevCameraMatrixWorld);

    if (planeDistanceDisocclusionCheck(worldPos, lastWorldPos, worldNormal)) return false;

    if (worldDistanceDisocclusionCheck(worldPos, lastWorldPos, depth)) return false;

    return true;
}

vec2 reprojectVelocity(vec2 sampleUv) {
    vec4 velocity = textureLod(velocityTexture, sampleUv, 0.0);
    velocity.xy = unpackRGBATo2Half(velocity);

    return sampleUv - velocity.xy;
}

vec2 reprojectHitPoint(vec3 rayOrig, float rayLength, vec2 uv, float depth) {
    vec3 cameraRay = normalize(rayOrig - cameraPos);
    float cameraRayLength = distance(rayOrig, cameraPos);

    vec3 parallaxHitPoint = cameraPos + cameraRay * (cameraRayLength + rayLength);

    vec4 reprojectedParallaxHitPoint = prevViewMatrix * vec4(parallaxHitPoint, 1.0);
    vec2 hitPointUv = viewSpaceToScreenSpace(reprojectedParallaxHitPoint.xyz);

    return hitPointUv;
}

vec2 getReprojectedUV(vec2 uv, float depth, vec3 worldPos, vec3 worldNormal, float rayLength) {
    if (rayLength != 0.0) {
        vec2 reprojectedUv = reprojectHitPoint(worldPos, rayLength, uv, depth);

        if (validateReprojectedUV(reprojectedUv, depth, worldPos, worldNormal)) {
            return reprojectedUv;
        }
    }

    vec2 reprojectedUv = reprojectVelocity(uv);

    if (validateReprojectedUV(reprojectedUv, depth, worldPos, worldNormal)) {
        return reprojectedUv;
    }

    return vec2(-1.);
}

#ifdef dilation
vec2 getDilatedDepthUV(out float currentDepth, out vec4 closestDepthTexel) {
    float closestDepth = 0.0;
    vec2 uv;

    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 offset = vec2(x, y) * invTexSize;
            vec2 neighborUv = vUv + offset;

            vec4 neighborDepthTexel = textureLod(depthTexture, neighborUv, 0.0);
            float depth = unpackRGBAToDepth(neighborDepthTexel);

            if (depth > closestDepth) {
                closestDepth = depth;
                closestDepthTexel = neighborDepthTexel;
                uv = neighborUv;
            }

            if (x == 0 && y == 0) {
                currentDepth = depth;
            }
        }
    }

    return uv;
}
#endif

#ifdef catmullRomSampling
vec4 SampleTextureCatmullRom(sampler2D tex, in vec2 uv, in vec2 texSize) {
    // We're going to sample a a 4x4 grid of texels surrounding the target UV coordinate. We'll do this by rounding
    // down the sample location to get the exact center of our "starting" texel. The starting texel will be at
    // location [1, 1] in the grid, where [0, 0] is the top left corner.
    vec2 samplePos = uv * texSize;
    vec2 texPos1 = floor(samplePos - 0.5f) + 0.5f;

    // Compute the fractional offset from our starting texel to our original sample location, which we'll
    // feed into the Catmull-Rom spline function to get our filter weights.
    vec2 f = samplePos - texPos1;

    // Compute the Catmull-Rom weights using the fractional offset that we calculated earlier.
    // These equations are pre-expanded based on our knowledge of where the texels will be located,
    // which lets us avoid having to evaluate a piece-wise function.
    vec2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
    vec2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
    vec2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
    vec2 w3 = f * f * (-0.5f + 0.5f * f);

    // Work out weighting factors and sampling offsets that will let us use bilinear filtering to
    // simultaneously evaluate the middle 2 samples from the 4x4 grid.
    vec2 w12 = w1 + w2;
    vec2 offset12 = w2 / (w1 + w2);

    // Compute the final UV coordinates we'll use for sampling the texture
    vec2 texPos0 = texPos1 - 1.;
    vec2 texPos3 = texPos1 + 2.;
    vec2 texPos12 = texPos1 + offset12;

    texPos0 /= texSize;
    texPos3 /= texSize;
    texPos12 /= texSize;

    vec4 result = vec4(0.0);
    result += textureLod(tex, vec2(texPos0.x, texPos0.y), 0.0f) * w0.x * w0.y;
    result += textureLod(tex, vec2(texPos12.x, texPos0.y), 0.0f) * w12.x * w0.y;
    result += textureLod(tex, vec2(texPos3.x, texPos0.y), 0.0f) * w3.x * w0.y;
    result += textureLod(tex, vec2(texPos0.x, texPos12.y), 0.0f) * w0.x * w12.y;
    result += textureLod(tex, vec2(texPos12.x, texPos12.y), 0.0f) * w12.x * w12.y;
    result += textureLod(tex, vec2(texPos3.x, texPos12.y), 0.0f) * w3.x * w12.y;
    result += textureLod(tex, vec2(texPos0.x, texPos3.y), 0.0f) * w0.x * w3.y;
    result += textureLod(tex, vec2(texPos12.x, texPos3.y), 0.0f) * w12.x * w3.y;
    result += textureLod(tex, vec2(texPos3.x, texPos3.y), 0.0f) * w3.x * w3.y;

    result = max(result, vec4(0.));

    return result;
}
#endif

vec4 sampleReprojectedTexture(sampler2D tex, vec2 reprojectedUv) {
#ifdef catmullRomSampling
    return SampleTextureCatmullRom(tex, reprojectedUv, 1.0 / invTexSize);
#else
    return textureLod(tex, reprojectedUv, 0.0);
#endif
}

void getDepthAndUv(out float depth, out vec2 uv, out vec4 depthTexel) {
#ifdef dilation
    uv = getDilatedDepthUV(depth, depthTexel);
#else
    depthTexel = textureLod(depthTexture, vUv, 0.);
    depth = unpackRGBAToDepth(depthTexel);
    uv = vUv;
#endif
}