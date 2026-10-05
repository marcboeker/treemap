// Types shared by Shaders.metal and the Swift renderer (through the bridging header, see
// SWIFT_OBJC_BRIDGING_HEADER in App/project.yml). simd types give both sides one layout.

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

#ifdef __METAL_VERSION__
#define SHADER_CONSTANT constant
#else
#define SHADER_CONSTANT static const
#endif

/// One cell quad.
typedef struct {
    simd_float4 rect;    // x, y, w, h in view points (origin top-left)
    simd_float4 fill;    // straight (non-premultiplied) rgba
    simd_float4 border;  // straight rgba
    simd_float4 params;  // x: border width (pt), y: mode (kCellMode*)
} CellInstance;

/// One label bitmap from the glyph atlas.
typedef struct {
    simd_float4 dst;     // x, y, w, h in view points
    simd_float4 uv;      // x, y, w, h in atlas pixels
    simd_float4 color;   // straight rgba
    simd_float4 clip;    // x0, y0, x1, y1 in view points
} LabelInstance;

typedef struct {
    simd_float2 viewSize;
    simd_float2 atlasSize;
    float scale;
} MapUniforms;

// Cell modes (CellInstance.params.y).
SHADER_CONSTANT float kCellModeNormal = 0;
SHADER_CONSTANT float kCellModeHatch = 1;     // unreadable
SHADER_CONSTANT float kCellModeAggregate = 2; // "N small items"
SHADER_CONSTANT float kCellModeOutline = 3;   // overlay outline (no special-casing in the shader)
SHADER_CONSTANT float kCellModeBadge = 5;     // tray marker: filled triangle in the top-right corner

#endif
