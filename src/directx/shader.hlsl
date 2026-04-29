struct TerminalCell
{
    uint glyph_index;
    uint foreground;
    uint background;
    uint cursor_kind;
    uint underline;
};

cbuffer ShaderParameters : register(b0)
{
    uint2 cell_size;
    uint2 term_size;
    uint cursor_foreground;
    uint cursor_background;
    uint underline_thickness_and_position;
};

StructuredBuffer<TerminalCell> Cells : register(t0);
Texture2D<float4> GlyphTexture : register(t1);
RWTexture2D<float4> Output : register(u0);

float3 UnpackColor(uint Packed)
{
    int R = Packed & 0xff;
    int G = (Packed >> 8) & 0xff;
    int B = (Packed >> 16) & 0xff;

    return float3(R, G, B) / 255.0;
}

uint2 UnpackGlyphXY(uint glyph_index)
{
    int x = (glyph_index & 0xffff);
    int y = (glyph_index >> 16);
    return uint2(x, y);
}

float4 ComputeOutputColor(uint2 ScreenPos)
{
    ScreenPos -= uint2(4, 4);
    uint2 CellIndex = ScreenPos / cell_size;
    uint2 CellPos = ScreenPos % cell_size;

    float out_of_bounds = float(!any(CellIndex >= term_size));
    CellIndex = min(CellIndex, term_size - 1);

    TerminalCell Cell = Cells[CellIndex.y * term_size.x + CellIndex.x];

    float3 foreground = UnpackColor(Cell.foreground);
    float3 background = UnpackColor(Cell.background);

    float3 result;
    switch (Cell.cursor_kind) {
    case 1: {
        float3 _cursor_foreground = UnpackColor(cursor_foreground);
        uint2 GlyphPos = UnpackGlyphXY(Cell.glyph_index) * cell_size;
        uint2 PixelPos = GlyphPos + CellPos;
        float4 GlyphTexel = GlyphTexture[PixelPos] * out_of_bounds;
        result = (1 - GlyphTexel.a) * _cursor_foreground + GlyphTexel.rgb * background;
    } break;
    case 2:
        if (CellPos.x < (cell_size.x / 4) * out_of_bounds) {
            float3 _cursor_foreground = UnpackColor(cursor_foreground);
            result = _cursor_foreground;
        } else {
            uint2 GlyphPos = UnpackGlyphXY(Cell.glyph_index) * cell_size;
            uint2 PixelPos = GlyphPos + CellPos;
            float4 GlyphTexel = GlyphTexture[PixelPos] * out_of_bounds;
            result = (1 - GlyphTexel.a) * background + GlyphTexel.rgb * foreground;
        }
        break;
    case 3:
        if (CellPos.y * out_of_bounds > cell_size.y - (cell_size.x / 4)) {
            float3 _cursor_foreground = UnpackColor(cursor_foreground);
            result = _cursor_foreground;
        } else {
            uint2 GlyphPos = UnpackGlyphXY(Cell.glyph_index) * cell_size;
            uint2 PixelPos = GlyphPos + CellPos;
            float4 GlyphTexel = GlyphTexture[PixelPos] * out_of_bounds;
            result = (1 - GlyphTexel.a) * background + GlyphTexel.rgb * foreground;
        }
        break;
    default: {
        uint2 GlyphPos = UnpackGlyphXY(Cell.glyph_index) * cell_size;
        uint2 PixelPos = GlyphPos + CellPos;
        float4 GlyphTexel = GlyphTexture[PixelPos] * out_of_bounds;
        result = (1 - GlyphTexel.a) * background + GlyphTexel.rgb * foreground;
    } break;
    }

    uint underline_position = underline_thickness_and_position & 0xFFFF;
    uint underline_size = underline_thickness_and_position >> 16;
    if ((Cell.underline >> 24) > 0 && CellPos.y >= underline_position && CellPos.y < underline_position + underline_size ) {
        result = UnpackColor(Cell.underline);
    }

    // if (CellPos.x < 1 || CellPos.y < 1 || CellPos.x > cell_size.x - 1 || CellPos.y > cell_size.y - 1) {
    //     return float4(0.1, 0.1, 0.1, 1);
    // } else {
    //     return float4(result, 1);
    // }
    return float4(result, 1);
}

[numthreads(8, 8, 1)]
void ComputeMain(uint3 Id: SV_DispatchThreadID)
{
    uint2 ScreenPos = Id.xy;
    // Output[ScreenPos] = float4(0, 1, 0, 1);
    // Output[ScreenPos] = GlyphTexture[ScreenPos];
    // Output[ScreenPos] = float4(
    //     float(ScreenPos.x / cell_size.x) / float(term_size.x),
    //     float(ScreenPos.y / cell_size.y) / float(term_size.y),
    //     0.0, 1.0
    // );
    Output[ScreenPos] = ComputeOutputColor(ScreenPos);
}