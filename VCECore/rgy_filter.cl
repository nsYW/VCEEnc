﻿// MEM_TYPE_SRC
// MEM_TYPE_DST
// in_bit_depth
// out_bit_depth

const sampler_t sampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;

#if in_bit_depth <= 8
#define TypeIn  uchar
#define TypeIn4 uchar4
#define convert_TypeIn4 convert_uchar4
#elif in_bit_depth <= 16
#define TypeIn  ushort
#define TypeIn4 ushort4
#define convert_TypeIn4 convert_ushort4
#endif

#if out_bit_depth <= 8
#define TypeOut  uchar
#define TypeOut4 uchar4
#define convert_TypeOut4 convert_uchar4
#elif out_bit_depth <= 16
#define TypeOut  ushort
#define TypeOut4 ushort4
#define convert_TypeOut4 convert_ushort4
#endif

// samplerでnormalizeした場合、0 -> 0.0f, 255 -> 1.0f

#define RGY_MEM_TYPE_CPU                    (0)
#define RGY_MEM_TYPE_GPU                    (1)
#define RGY_MEM_TYPE_GPU_IMAGE              (2)
#define RGY_MEM_TYPE_GPU_IMAGE_NORMALIZED   (3)

#ifndef __OPENCL_VERSION__
#define __kernel
#define __global
#define __local
#define __read_only
#define __write_only
#define image2d_t void*
#define uchar unsigned char
#endif

#define IntegerIsSigned(intType)    ((intType)(-1) < 0)

inline int conv_bit_depth_lsft(const int bit_depth_in, const int bit_depth_out, const int shift_offset) {
    const int lsft = bit_depth_out - (bit_depth_in + shift_offset);
    return lsft < 0 ? 0 : lsft;
}

inline int conv_bit_depth_rsft(const int bit_depth_in, const int bit_depth_out, const int shift_offset) {
    const int rsft = bit_depth_in + shift_offset - bit_depth_out;
    return rsft < 0 ? 0 : rsft;
}

inline int conv_bit_depth_rsft_add(const int bit_depth_in, const int bit_depth_out, const int shift_offset) {
    const int rsft = conv_bit_depth_rsft(bit_depth_in, bit_depth_out, shift_offset);
    return (rsft - 1 >= 0) ? 1 << (rsft - 1) : 0;
}

inline int conv_bit_depth(const int c, const int bit_depth_in, const int bit_depth_out, const int shift_offset) {
    if (bit_depth_out > bit_depth_in + shift_offset) {
        return c << conv_bit_depth_lsft(bit_depth_in, bit_depth_out, shift_offset);
    } else if (bit_depth_out < bit_depth_in + shift_offset) {
        const int x = (c + conv_bit_depth_rsft_add(bit_depth_in, bit_depth_out, shift_offset)) >> conv_bit_depth_rsft(bit_depth_in, bit_depth_out, shift_offset);
        const int low = 0;
        const int high = (1 << bit_depth_out) - 1;
        return (((x) <= (high)) ? (((x) >= (low)) ? (x) : (low)) : (high));
    } else {
        return c;
    }
}

#define NORM_SCALE_IN  (float)((1<<(sizeof(TypeIn)*8))-1)
#define NORM_SCALE_OUT (1.0f/(float)((1<<(sizeof(TypeOut)*8))-1))

#define BIT_DEPTH_CONV(x) (TypeOut)conv_bit_depth((x), in_bit_depth, out_bit_depth, 0)

#define BIT_DEPTH_CONV_FLOAT(x) (TypeOut)((out_bit_depth == in_bit_depth) \
    ? (x) \
    : ((out_bit_depth > in_bit_depth) \
        ? ((x) * (float)(1 << (out_bit_depth - in_bit_depth))) \
        : ((x) * (float)(1.0f / (1 << (in_bit_depth - out_bit_depth))))))

#define BIT_DEPTH_CONV_AVG(a, b) (TypeOut)conv_bit_depth((a)+(b), in_bit_depth, out_bit_depth, 1)

#define BIT_DEPTH_CONV_3x1_AVG(a, b) (TypeOut)conv_bit_depth(((a)<<1)+(a)+(b), in_bit_depth, out_bit_depth, 2)

#define BIT_DEPTH_CONV_7x1_AVG(a, b) (TypeOut)conv_bit_depth(((a)<<3)-(a)+(b), in_bit_depth, out_bit_depth, 3)

#define LOAD_IMG(src_img, ix, iy) (TypeIn)(read_imageui((src_img), sampler, (int2)((ix), (iy))).x)
#define LOAD_IMG_AYUV(src_img, ix, iy) convert_TypeIn4(read_imageui((src_img), sampler, (int2)((ix), (iy))))
#define LOAD_IMG_NV12_UV(src_img, src_u, src_v, ix, iy, cropX, cropY) { \
    uint4 ret = read_imageui((src_img), sampler, (int2)((ix) + ((cropX)>>1), (iy) + ((cropY)>>1))); \
    (src_u) = (TypeIn)ret.x; \
    (src_v) = (TypeIn)ret.y; \
}
#define LOAD_BUF(src_buf, ix, iy) *(__global TypeIn *)(&(src_buf)[(iy) * srcPitch + (ix) * sizeof(TypeIn)])
#define LOAD_BUF_AYUV(src_buf, ix, iy) *(__global TypeIn4 *)(&(src_buf)[(iy) * srcPitch + (ix) * sizeof(TypeIn4)])
#define LOAD_BUF_NV12_UV(src_buf, src_u, src_v, ix, iy, cropX, cropY) { \
    (src_u) = LOAD((src_buf), ((ix)<<1) + 0 + (cropX), (iy) + ((cropY)>>1)); \
    (src_v) = LOAD((src_buf), ((ix)<<1) + 1 + (cropX), (iy) + ((cropY)>>1)); \
}

#define LOAD_IMG_NORM(src_img, ix, iy) (TypeIn)(read_imagef((src_img), sampler, (int2)((ix), (iy))).x * NORM_SCALE_IN + 0.5f)
#define LOAD_IMG_NORM_AYUV(src_img, ix, iy) convert_TypeIn4(read_imagef((src_img), sampler, (int2)((ix), (iy))) * (float4)NORM_SCALE_IN + (float4)0.5f)
#define LOAD_IMG_NORM_NV12_UV(src_img, src_u, src_v, ix, iy, cropX, cropY) { \
    float4 ret = read_imagef((src_img), sampler, (int2)((ix) + ((cropX)>>1), (iy) + ((cropY)>>1))); \
    (src_u) = (TypeIn)(ret.x * NORM_SCALE_IN + 0.5f); \
    (src_v) = (TypeIn)(ret.y * NORM_SCALE_IN + 0.5f); \
}

#if MEM_TYPE_SRC == RGY_MEM_TYPE_GPU_IMAGE
#define IMAGE_SRC    1
#define LOAD         LOAD_IMG
#define LOAD_AYUV    LOAD_IMG_AYUV
#define LOAD_NV12_UV LOAD_IMG_NV12_UV
#elif MEM_TYPE_SRC == RGY_MEM_TYPE_GPU_IMAGE_NORMALIZED
#define IMAGE_SRC    1
#define LOAD         LOAD_IMG_NORM
#define LOAD_AYUV    LOAD_IMG_NORM_AYUV
#define LOAD_NV12_UV LOAD_IMG_NORM_NV12_UV
#else
#define IMAGE_SRC    0
#define LOAD         LOAD_BUF
#define LOAD_AYUV    LOAD_BUF_AYUV
#define LOAD_NV12_UV LOAD_BUF_NV12_UV
#endif

#define STORE_IMG(dst_img, ix, iy, val) write_imageui((dst_img), (int2)((ix), (iy)), (val))
#define STORE_IMG_AYUV(dst_img, ix, iy, val) write_imageui((dst_img), (int2)((ix), (iy)), convert_uint4(val))
#define STORE_IMG_NV12_UV(dst_img, ix, iy, val_u, val_v) { \
    uint4 val = (uint4)(val_u, val_v, val_v, val_v); \
    write_imageui((dst_img), (int2)((ix), (iy)), (val)); \
}

#define STORE_IMG_NORM(dst_img, ix, iy, val) write_imagef(dst_img, (int2)((ix), (iy)), (val * NORM_SCALE_OUT))
#define STORE_IMG_NORM_AYUV(dst_img, ix, iy, val) write_imagef(dst_img, (int2)((ix), (iy)), (convert_float4(val) * (float4)NORM_SCALE_OUT))
#define STORE_IMG_NORM_NV12_UV(dst_img, ix, iy, val_u, val_v) { \
    float4 val = (float4)(val_u * NORM_SCALE_OUT, val_v * NORM_SCALE_OUT, val_v * NORM_SCALE_OUT, val_v * NORM_SCALE_OUT); \
    write_imagef(dst_img, (int2)((ix), (iy)), (val)); \
}
#define STORE_BUF(dst_buf, ix, iy, val)  { \
    __global TypeOut *ptr = (__global TypeOut *)(&(dst_buf)[(iy) * dstPitch + (ix) * sizeof(TypeOut)]); \
    ptr[0] = (TypeOut)(val); \
}
#define STORE_BUF_AYUV(dst_buf, ix, iy, val)  { \
    __global TypeOut4 *ptr = (__global TypeOut4 *)(&(dst_buf)[(iy) * dstPitch + (ix) * sizeof(TypeOut4)]); \
    ptr[0] = (TypeOut4)(val); \
}
#define STORE_BUF_NV12_UV(dst_buf, ix, iy, val_u, val_v) { \
    STORE(dst_buf, ((ix) << 1) + 0, (iy), val_u); \
    STORE(dst_buf, ((ix) << 1) + 1, (iy), val_v); \
}
#if MEM_TYPE_DST == RGY_MEM_TYPE_GPU_IMAGE
#define IMAGE_DST     1
#define STORE         STORE_IMG
#define STORE_AYUV    STORE_IMG_AYUV
#define STORE_NV12_UV STORE_IMG_NV12_UV
#elif MEM_TYPE_DST == RGY_MEM_TYPE_GPU_IMAGE_NORMALIZED
#define IMAGE_DST     1
#define STORE         STORE_IMG_NORM
#define STORE_AYUV    STORE_IMG_NORM_AYUV
#define STORE_NV12_UV STORE_IMG_NORM_NV12_UV
#else
#define IMAGE_DST     0
#define STORE         STORE_BUF
#define STORE_AYUV    STORE_BUF_AYUV
#define STORE_NV12_UV STORE_BUF_NV12_UV
#endif

void conv_c_yuv420_yuv444_internal(
    int *pixDst11, int *pixDst12,
    int *pixDst21, int *pixDst22,
    int pixSrc01, int pixSrc02,
    int pixSrc11, int pixSrc12,
    int pixSrc21, int pixSrc22
) {
    pixSrc02 = (pixSrc01 + pixSrc02 + 1) >> 1;
    pixSrc12 = (pixSrc11 + pixSrc12 + 1) >> 1;
    pixSrc22 = (pixSrc21 + pixSrc22 + 1) >> 1;

    *pixDst11 = BIT_DEPTH_CONV_3x1_AVG(pixSrc11, pixSrc01);
    *pixDst12 = BIT_DEPTH_CONV_3x1_AVG(pixSrc12, pixSrc02);
    *pixDst21 = BIT_DEPTH_CONV_7x1_AVG(pixSrc11, pixSrc21);
    *pixDst22 = BIT_DEPTH_CONV_7x1_AVG(pixSrc12, pixSrc22);
}

void conv_c_yuv420_yuv444(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    const int dstPitch,
    const int dst_x, const int dst_y,
    int pixSrc01, int pixSrc02,
    int pixSrc11, int pixSrc12,
    int pixSrc21, int pixSrc22
) {
    int pixDst11, pixDst12, pixDst21, pixDst22;
    conv_c_yuv420_yuv444_internal(
        &pixDst11, &pixDst12, &pixDst21, &pixDst22,
        pixSrc01, pixSrc02, pixSrc11, pixSrc12, pixSrc21, pixSrc22
    );

    STORE(dst, dst_x+0, dst_y+0, (TypeOut)pixDst11);
    STORE(dst, dst_x+1, dst_y+0, (TypeOut)pixDst12);
    STORE(dst, dst_x+0, dst_y+1, (TypeOut)pixDst21);
    STORE(dst, dst_x+1, dst_y+1, (TypeOut)pixDst22);
}

__kernel void kernel_copy_plane(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
    int dstOffsetX,
    int dstOffsetY,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int srcOffsetX,
    int srcOffsetY,
    int width,
    int height
) {
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if (x < width && y < height) {
        TypeIn pixSrc = LOAD(src, x + srcOffsetX, y + srcOffsetY);
        TypeOut out = BIT_DEPTH_CONV(pixSrc);
        STORE(dst, x + dstOffsetX, y + dstOffsetY, out);
    }
}

__kernel void kernel_copy_plane_nv12(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int uvWidth,
    int uvHeight,
    int cropX,     // 輝度と同じcropを想定
    int cropY      // 輝度と同じcropを想定
) {
    const int uv_x = get_global_id(0);
    const int uv_y = get_global_id(1);
    if (uv_x < uvWidth && uv_y < uvHeight) {
        TypeIn pixSrcU, pixSrcV;
        LOAD_NV12_UV(src, pixSrcU, pixSrcV, uv_x, uv_y, cropX, cropY);
        TypeOut pixDstU = BIT_DEPTH_CONV(pixSrcU);
        TypeOut pixDstV = BIT_DEPTH_CONV(pixSrcV);
        STORE_NV12_UV(dst, uv_x, uv_y, pixDstU, pixDstV);
    }
}

__kernel void kernel_crop_nv12_yv12(
#if IMAGE_DST
    __write_only image2d_t dstU,
    __write_only image2d_t dstV,
#else
    __global uchar *dstU,
    __global uchar *dstV,
#endif
    int dstPitch,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int uvWidth,
    int uvHeight,
    int cropX,     // 輝度と同じcropを想定
    int cropY      // 輝度と同じcropを想定
) {
    const int uv_x = get_global_id(0);
    const int uv_y = get_global_id(1);
    if (uv_x < uvWidth && uv_y < uvHeight) {
        TypeIn pixSrcU, pixSrcV;
        LOAD_NV12_UV(src, pixSrcU, pixSrcV, uv_x, uv_y, cropX, cropY);
        TypeOut pixDstU = BIT_DEPTH_CONV(pixSrcU);
        TypeOut pixDstV = BIT_DEPTH_CONV(pixSrcV);
        STORE(dstU, uv_x, uv_y, pixDstU);
        STORE(dstV, uv_x, uv_y, pixDstV);
    }
}

__kernel void kernel_crop_nv12_yuv444(
#if IMAGE_DST
    __write_only image2d_t dstU,
    __write_only image2d_t dstV,
#else
    __global uchar *dstU,
    __global uchar *dstV,
#endif
    int dstPitch,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,     // 輝度と同じcropを想定
    int cropY      // 輝度と同じcropを想定
) {
    const int src_x = get_global_id(0);
    const int src_y = get_global_id(1);
    const int dst_x = src_x << 1;
    const int dst_y = src_y << 1;

    if (dst_x < dstWidth && dst_y < dstHeight) {
        const int loadx = src_x + (cropX>>1);
        const int loady = src_y + (cropY>>1);

        TypeIn pixSrcU01, pixSrcV01, pixSrcU02, pixSrcV02;
        TypeIn pixSrcU11, pixSrcV11, pixSrcU12, pixSrcV12;
        TypeIn pixSrcU21, pixSrcV21, pixSrcU22, pixSrcV22;
        LOAD_NV12_UV(src, pixSrcU01, pixSrcV01,     loadx,              max(loady-1, 0),         0, 0);
        LOAD_NV12_UV(src, pixSrcU02, pixSrcV02, min(loadx+1, srcWidth), max(loady-1, 0),         0, 0);
        LOAD_NV12_UV(src, pixSrcU11, pixSrcV11,     loadx,                  loady,               0, 0);
        LOAD_NV12_UV(src, pixSrcU12, pixSrcV12, min(loadx+1, srcWidth),     loady,               0, 0);
        LOAD_NV12_UV(src, pixSrcU21, pixSrcV21,     loadx,              min(loady+1, srcHeight), 0, 0);
        LOAD_NV12_UV(src, pixSrcU22, pixSrcV22, min(loadx+1, srcWidth), min(loady+1, srcHeight), 0, 0);

        conv_c_yuv420_yuv444(dstU, dstPitch, dst_x, dst_y, pixSrcU01, pixSrcU02, pixSrcU11, pixSrcU12, pixSrcU21, pixSrcU22);
        conv_c_yuv420_yuv444(dstV, dstPitch, dst_x, dst_y, pixSrcV01, pixSrcV02, pixSrcV11, pixSrcV12, pixSrcV21, pixSrcV22);
    }
}

__kernel void kernel_crop_c_yuv444_nv12(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t srcU,
    __read_only image2d_t srcV,
#else
    __global uchar *srcU,
    __global uchar *srcV,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,     // 輝度と同じcropを想定
    int cropY      // 輝度と同じcropを想定
) {
    const int dst_x = get_global_id(0);
    const int dst_y = get_global_id(1);

    if (dst_x < dstWidth && dst_y < dstHeight) {
        const int src_x = dst_x << 1;
        const int src_y = dst_y << 1;
        const int loadx = src_x + cropX;
        const int loady = src_y + cropY;
        const int pixSrcU00 = LOAD(srcU, loadx+0, loady+0);
        const int pixSrcU10 = LOAD(srcU, loadx+0, loady+1);
        const int pixSrcV00 = LOAD(srcV, loadx+0, loady+0);
        const int pixSrcV10 = LOAD(srcV, loadx+0, loady+1);
        TypeOut pixDstU = BIT_DEPTH_CONV_AVG(pixSrcU00, pixSrcU10);
        TypeOut pixDstV = BIT_DEPTH_CONV_AVG(pixSrcV00, pixSrcV10);
        STORE_NV12_UV(dst, dst_x, dst_y, pixDstU, pixDstV);
    }
}

__kernel void kernel_crop_yv12_nv12(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
#if IMAGE_SRC
    __read_only image2d_t srcU,
    __read_only image2d_t srcV,
#else
    __global uchar *srcU,
    __global uchar *srcV,
#endif
    int srcPitch,
    int uvWidth,
    int uvHeight,
    int cropX,     // 輝度と同じcropを想定
    int cropY      // 輝度と同じcropを想定
) {
    const int uv_x = get_global_id(0);
    const int uv_y = get_global_id(1);

    if (uv_x < uvWidth && uv_y < uvHeight) {
        const TypeIn pixSrcU = LOAD(srcU, uv_x + (cropX>>1), uv_y + (cropY>>1));
        const TypeIn pixSrcV = LOAD(srcV, uv_x + (cropX>>1), uv_y + (cropY>>1));
        const TypeOut pixDstU = BIT_DEPTH_CONV(pixSrcU);
        const TypeOut pixDstV = BIT_DEPTH_CONV(pixSrcV);
        STORE_NV12_UV(dst, uv_x, uv_y, pixDstU, pixDstV);
    }
}

__kernel void kernel_crop_c_yv12_yuv444(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,     // 輝度と同じcropを想定
    int cropY      // 輝度と同じcropを想定
) {
    const int src_x = get_global_id(0);
    const int src_y = get_global_id(1);
    const int dst_x = src_x << 1;
    const int dst_y = src_y << 1;

    if (dst_x < dstWidth && dst_y < dstHeight) {
        const int loadx = src_x + (cropX>>1);
        const int loady = src_y + (cropY>>1);
        const int pixSrc01 = LOAD(src,     loadx,              max(loady-1, 0)        );
        const int pixSrc02 = LOAD(src, min(loadx+1, srcWidth), max(loady-1, 0)        );
        const int pixSrc11 = LOAD(src,     loadx,                  loady              );
        const int pixSrc12 = LOAD(src, min(loadx+1, srcWidth),     loady              );
        const int pixSrc21 = LOAD(src,     loadx,              min(loady+1, srcHeight));
        const int pixSrc22 = LOAD(src, min(loadx+1, srcWidth), min(loady+1, srcHeight));

        conv_c_yuv420_yuv444(dst, dstPitch, dst_x, dst_y, pixSrc01, pixSrc02, pixSrc11, pixSrc12, pixSrc21, pixSrc22);
    }
}

__kernel void kernel_crop_c_yuv444_yv12(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,     // 輝度と同じcropを想定
    int cropY      // 輝度と同じcropを想定
) {
    const int dst_x = get_global_id(0);
    const int dst_y = get_global_id(1);

    if (dst_x < dstWidth && dst_y < dstHeight) {
        const int src_x = dst_x << 1;
        const int src_y = dst_y << 1;
        const int loadx = src_x + cropX;
        const int loady = src_y + cropY;
        const int pixSrc00 = LOAD(src, loadx+0, loady+0);
        const int pixSrc10 = LOAD(src, loadx+0, loady+1);
        const TypeOut pixDst = BIT_DEPTH_CONV_AVG(pixSrc00, pixSrc10);
        STORE(dst, dst_x, dst_y, pixDst);
    }
}

TypeOut4 conv_rgb_yuv(const TypeIn4 rgb) {
    const float fr = (float)rgb.z;
    const float fg = (float)rgb.y;
    const float fb = (float)rgb.x;
    const float fy =  0.257f * fr + 0.504f * fg + 0.098f * fb +  16.0f;
    const float fu = -0.148f * fr - 0.291f * fg + 0.439f * fb + 128.0f;
    const float fv =  0.439f * fr - 0.368f * fg - 0.071f * fb + 128.0f;
    TypeOut4 yuv;
    yuv.x = (TypeOut)(BIT_DEPTH_CONV_FLOAT(fy) + 0.5f);
    yuv.y = (TypeOut)(BIT_DEPTH_CONV_FLOAT(fu) + 0.5f);
    yuv.z = (TypeOut)(BIT_DEPTH_CONV_FLOAT(fv) + 0.5f);
    return yuv;
}

__kernel void kernel_crop_rgb32_yuv444(
#if IMAGE_DST
    __write_only image2d_t dstY,
    __write_only image2d_t dstU,
    __write_only image2d_t dstV,
#else
    __global uchar *dstY,
    __global uchar *dstU,
    __global uchar *dstV,
#endif
    int dstPitch,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,
    int cropY
) {
    const int dst_x = get_global_id(0);
    const int dst_y = get_global_id(1);

    if (dst_x < dstWidth && dst_y < dstHeight) {
        const int loadx = dst_x + cropX;
        const int loady = dst_y + cropY;
        const TypeIn4 pixSrcRGB = LOAD_AYUV(src, loadx, loady);
        TypeOut4 yuv = conv_rgb_yuv(pixSrcRGB);
        STORE(dstY, dst_x, dst_y, yuv.x);
        STORE(dstU, dst_x, dst_y, yuv.y);
        STORE(dstV, dst_x, dst_y, yuv.z);
    }
}

__kernel void kernel_crop_rgb32_yv12(
#if IMAGE_DST
    __write_only image2d_t dstY,
    __write_only image2d_t dstU,
    __write_only image2d_t dstV,
#else
    __global uchar *dstY,
    __global uchar *dstU,
    __global uchar *dstV,
#endif
    int dstPitchY,
    int dstPitchU,
    int dstPitchV,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,
    int cropY
) {
    const int dstC_x = get_global_id(0);
    const int dstC_y = get_global_id(1);
    const int dstY_x = dstC_x << 1;
    const int dstY_y = dstC_y << 1;

    if (dstY_x + 1 < dstWidth && dstY_y + 1 < dstHeight) {
        const int loadx = dstY_x + cropX;
        const int loady = dstY_y + cropY;
        const TypeIn4 pixSrcRGB00 = LOAD_AYUV(src, loadx+0, loady+0);
        const TypeIn4 pixSrcRGB01 = LOAD_AYUV(src, loadx+1, loady+0);
        const TypeIn4 pixSrcRGB10 = LOAD_AYUV(src, loadx+0, loady+1);
        const TypeIn4 pixSrcRGB11 = LOAD_AYUV(src, loadx+1, loady+1);
        const TypeOut4 yuv00 = conv_rgb_yuv(pixSrcRGB00);
        const TypeOut4 yuv01 = conv_rgb_yuv(pixSrcRGB01);
        const TypeOut4 yuv10 = conv_rgb_yuv(pixSrcRGB10);
        const TypeOut4 yuv11 = conv_rgb_yuv(pixSrcRGB11);
        int dstPitch = dstPitchY;
        STORE(dstY, dstY_x+0, dstY_y+0, yuv00.x);
        STORE(dstY, dstY_x+1, dstY_y+0, yuv01.x);
        STORE(dstY, dstY_x+0, dstY_y+1, yuv10.x);
        STORE(dstY, dstY_x+1, dstY_y+1, yuv11.x);
        const TypeOut pixU = (TypeOut)(((int)yuv00.y + (int)yuv10.y + 1) >> 1);
        const TypeOut pixV = (TypeOut)(((int)yuv00.z + (int)yuv10.z + 1) >> 1);
        dstPitch = dstPitchU;
        STORE(dstU, dstC_x, dstC_y, pixU);
        dstPitch = dstPitchV;
        STORE(dstV, dstC_x, dstC_y, pixV);
    }
}

__kernel void kernel_crop_rgb32_nv12(
#if IMAGE_DST
    __write_only image2d_t dstY,
    __write_only image2d_t dstC,
#else
    __global uchar *dstY,
    __global uchar *dstC,
#endif
    int dstPitchY,
    int dstPitchC,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,
    int cropY
) {
    const int dstC_x = get_global_id(0);
    const int dstC_y = get_global_id(1);
    const int dstY_x = dstC_x << 1;
    const int dstY_y = dstC_y << 1;

    if (dstY_x < dstWidth && dstY_y < dstHeight) {
        const int loadx = dstY_x + cropX;
        const int loady = dstY_y + cropY;
        const TypeIn4 pixSrcRGB00 = LOAD_AYUV(src, loadx+0, loady+0);
        const TypeIn4 pixSrcRGB01 = LOAD_AYUV(src, loadx+1, loady+0);
        const TypeIn4 pixSrcRGB10 = LOAD_AYUV(src, loadx+0, loady+1);
        const TypeIn4 pixSrcRGB11 = LOAD_AYUV(src, loadx+1, loady+1);
        const TypeOut4 yuv00 = conv_rgb_yuv(pixSrcRGB00);
        const TypeOut4 yuv01 = conv_rgb_yuv(pixSrcRGB01);
        const TypeOut4 yuv10 = conv_rgb_yuv(pixSrcRGB10);
        const TypeOut4 yuv11 = conv_rgb_yuv(pixSrcRGB11);
        int dstPitch = dstPitchY;
        STORE(dstY, dstY_x+0, dstY_y+0, yuv00.x);
        STORE(dstY, dstY_x+1, dstY_y+0, yuv01.x);
        STORE(dstY, dstY_x+0, dstY_y+1, yuv10.x);
        STORE(dstY, dstY_x+1, dstY_y+1, yuv11.x);
        const TypeOut pixU = (TypeOut)(((int)yuv00.y + (int)yuv10.y + 1) >> 1);
        const TypeOut pixV = (TypeOut)(((int)yuv00.z + (int)yuv10.z + 1) >> 1);
        dstPitch = dstPitchC;
        STORE_NV12_UV(dstC, dstC_x, dstC_y, pixU, pixV);
    }
}

__kernel void kernel_crop_ayuv_yuv444(
#if IMAGE_DST
    __write_only image2d_t dstY,
    __write_only image2d_t dstU,
    __write_only image2d_t dstV,
#else
    __global uchar *dstY,
    __global uchar *dstU,
    __global uchar *dstV,
#endif
    int dstPitch,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,
    int cropY
) {
    const int dst_x = get_global_id(0);
    const int dst_y = get_global_id(1);

    if (dst_x < dstWidth && dst_y < dstHeight) {
        const int loadx = dst_x + cropX;
        const int loady = dst_y + cropY;
        TypeIn4 pix = LOAD_AYUV(src, loadx, loady); //RGBA = VUYA
        TypeOut pixY = (TypeOut)BIT_DEPTH_CONV(pix.z);
        TypeOut pixU = (TypeOut)BIT_DEPTH_CONV(pix.y);
        TypeOut pixV = (TypeOut)BIT_DEPTH_CONV(pix.x);
        STORE(dstY, dst_x, dst_y, pixY);
        STORE(dstU, dst_x, dst_y, pixU);
        STORE(dstV, dst_x, dst_y, pixV);
    }
}

__kernel void kernel_crop_ayuv_yv12(
#if IMAGE_DST
    __write_only image2d_t dstY,
    __write_only image2d_t dstU,
    __write_only image2d_t dstV,
#else
    __global uchar *dstY,
    __global uchar *dstU,
    __global uchar *dstV,
#endif
    int dstPitch,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t src,
#else
    __global uchar *src,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,
    int cropY
) {
    const int dst_x_C = get_global_id(0);
    const int dst_y_C = get_global_id(1);
    const int dst_x_Y = dst_x_C << 1;
    const int dst_y_Y = dst_y_C << 1;

    if (dst_x_Y < dstWidth && dst_y_Y < dstHeight) {
        const int src_x = dst_x_Y;
        const int src_y = dst_y_Y;
        const int loadx = src_x + cropX;
        const int loady = src_y + cropY;
        const TypeIn4 pixSrc00 = LOAD_AYUV(src, loadx+0, loady+0);
        const TypeIn4 pixSrc01 = LOAD_AYUV(src, loadx+1, loady+0);
        const TypeIn4 pixSrc10 = LOAD_AYUV(src, loadx+0, loady+1);
        const TypeIn4 pixSrc11 = LOAD_AYUV(src, loadx+1, loady+1);
        TypeOut pixY00 = (TypeOut)BIT_DEPTH_CONV(pixSrc00.z);
        TypeOut pixY01 = (TypeOut)BIT_DEPTH_CONV(pixSrc01.z);
        TypeOut pixY10 = (TypeOut)BIT_DEPTH_CONV(pixSrc10.z);
        TypeOut pixY11 = (TypeOut)BIT_DEPTH_CONV(pixSrc11.z);
        TypeOut pixU   = (TypeOut)BIT_DEPTH_CONV_AVG(pixSrc00.y, pixSrc10.y);
        TypeOut pixV   = (TypeOut)BIT_DEPTH_CONV_AVG(pixSrc00.x, pixSrc10.x);
        STORE(dstY, dst_x_Y+0, dst_y_Y+0, pixY00);
        STORE(dstY, dst_x_Y+1, dst_y_Y+0, pixY01);
        STORE(dstY, dst_x_Y+0, dst_y_Y+1, pixY10);
        STORE(dstY, dst_x_Y+1, dst_y_Y+1, pixY11);
        STORE(dstU, dst_x_C,   dst_y_C,   pixU);
        STORE(dstV, dst_x_C,   dst_y_C,   pixV);
    }
}

__kernel void kernel_crop_yuv444_ayuv(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t srcY,
    __read_only image2d_t srcU,
    __read_only image2d_t srcV,
#else
    __global uchar *srcY,
    __global uchar *srcU,
    __global uchar *srcV,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,
    int cropY
) {
    const int dst_x = get_global_id(0);
    const int dst_y = get_global_id(1);

    if (dst_x < dstWidth && dst_y < dstHeight) {
        const int loadx = dst_x + cropX;
        const int loady = dst_y + cropY;
        const int pixY = LOAD(srcY, loadx, loady);
        const int pixU = LOAD(srcU, loadx, loady);
        const int pixV = LOAD(srcV, loadx, loady);
        TypeOut4 pix;
        pix.w = 0;
        pix.z = BIT_DEPTH_CONV(pixY);
        pix.y = BIT_DEPTH_CONV(pixU);
        pix.x = BIT_DEPTH_CONV(pixV);
        STORE_AYUV(dst, dst_x, dst_y, pix);
    }
}

__kernel void kernel_crop_yv12_ayuv(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
    int dstWidth,
    int dstHeight,
#if IMAGE_SRC
    __read_only image2d_t srcY,
    __read_only image2d_t srcU,
    __read_only image2d_t srcV,
#else
    __global uchar *srcY,
    __global uchar *srcU,
    __global uchar *srcV,
#endif
    int srcPitch,
    int srcWidth,
    int srcHeight,
    int cropX,
    int cropY
) {
    const int src_C_x = get_global_id(0);
    const int src_C_y = get_global_id(1);
    const int dst_x = src_C_x << 1;
    const int dst_y = src_C_y << 1;

    if (dst_x < dstWidth && dst_y < dstHeight) {
        const int load_C_x = src_C_x + (cropX>>1);
        const int load_C_y = src_C_y + (cropY>>1);

        const int pixSrcU01 = LOAD(srcU,     load_C_x,              max(load_C_y-1, 0)        );
        const int pixSrcU02 = LOAD(srcU, min(load_C_x+1, srcWidth), max(load_C_y-1, 0)        );
        const int pixSrcU11 = LOAD(srcU,     load_C_x,                  load_C_y              );
        const int pixSrcU12 = LOAD(srcU, min(load_C_x+1, srcWidth),     load_C_y              );
        const int pixSrcU21 = LOAD(srcU,     load_C_x,              min(load_C_y+1, srcHeight));
        const int pixSrcU22 = LOAD(srcU, min(load_C_x+1, srcWidth), min(load_C_y+1, srcHeight));

        const int pixSrcV01 = LOAD(srcV,     load_C_x,              max(load_C_y-1, 0)        );
        const int pixSrcV02 = LOAD(srcV, min(load_C_x+1, srcWidth), max(load_C_y-1, 0)        );
        const int pixSrcV11 = LOAD(srcV,     load_C_x,                  load_C_y              );
        const int pixSrcV12 = LOAD(srcV, min(load_C_x+1, srcWidth),     load_C_y              );
        const int pixSrcV21 = LOAD(srcV,     load_C_x,              min(load_C_y+1, srcHeight));
        const int pixSrcV22 = LOAD(srcV, min(load_C_x+1, srcWidth), min(load_C_y+1, srcHeight));

        int pixDstU11, pixDstU12, pixDstU21, pixDstU22;
        conv_c_yuv420_yuv444_internal(&pixDstU11, &pixDstU12, &pixDstU21, &pixDstU22, pixSrcU01, pixSrcU02, pixSrcU11, pixSrcU12, pixSrcU21, pixSrcU22);
        
        int pixDstV11, pixDstV12, pixDstV21, pixDstV22;
        conv_c_yuv420_yuv444_internal(&pixDstU11, &pixDstU12, &pixDstU21, &pixDstU22, pixSrcU01, pixSrcU02, pixSrcU11, pixSrcU12, pixSrcU21, pixSrcU22);
        
        const int load_Y_x = load_C_x << 1;
        const int load_Y_y = load_C_y << 1;

        const int pixSrcY11 = LOAD(srcY, load_Y_x+0, load_Y_y+0);
        const int pixSrcY12 = LOAD(srcY, load_Y_x+1, load_Y_y+0);
        const int pixSrcY21 = LOAD(srcY, load_Y_x+0, load_Y_y+1);
        const int pixSrcY22 = LOAD(srcY, load_Y_x+1, load_Y_y+1);

        TypeOut4 pix11, pix12, pix21, pix22;

        pix11.w = 0;
        pix11.z = BIT_DEPTH_CONV(pixSrcY11);
        pix11.y = pixDstU11;
        pix11.x = pixDstV11;

        pix12.w = 0;
        pix12.z = BIT_DEPTH_CONV(pixSrcY12);
        pix12.y = pixDstU12;
        pix12.x = pixDstV12;

        pix21.w = 0;
        pix21.z = BIT_DEPTH_CONV(pixSrcY21);
        pix21.y = pixDstU21;
        pix21.x = pixDstV21;

        pix22.w = 0;
        pix22.z = BIT_DEPTH_CONV(pixSrcY22);
        pix22.y = pixDstU22;
        pix22.x = pixDstV22;

        STORE_AYUV(dst, dst_x+0, dst_y+0, pix11);
        STORE_AYUV(dst, dst_x+1, dst_y+0, pix12);
        STORE_AYUV(dst, dst_x+0, dst_y+1, pix21);
        STORE_AYUV(dst, dst_x+1, dst_y+1, pix22);
    }
}

__kernel void kernel_separate_fields(
    __global uchar *dst0,
    __global uchar *dst1,
    int dstPitch,
    __global uchar *src,
    int srcPitch,
    int width,
    int height_field
) {
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if (x < width && y < height_field) {
        TypeIn pixSrc0 = LOAD_BUF(src, x, y*2+0);
        TypeIn pixSrc1 = LOAD_BUF(src, x, y*2+1);
        STORE_BUF(dst0, x, y, pixSrc0);
        STORE_BUF(dst1, x, y, pixSrc1);
    }
}

__kernel void kernel_merge_fields(
    __global uchar *dst,
    int dstPitch,
    __global uchar *src0,
    __global uchar *src1,
    int srcPitch,
    int width,
    int height_field
) {
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if (x < width && y < height_field) {
        TypeIn pixSrc0 = LOAD_BUF(src0, x, y);
        TypeIn pixSrc1 = LOAD_BUF(src1, x, y);
        STORE_BUF(dst, x, y*2+0, pixSrc0);
        STORE_BUF(dst, x, y*2+1, pixSrc1);
    }
}

__kernel void kernel_set_plane(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
    int width,
    int height,
    int cropX,
    int cropY,
    int value
) {
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if (x < width && y < height) {
        STORE(dst, x + cropX, y + cropY, value);
    }
}

__kernel void kernel_set_plane_nv12(
#if IMAGE_DST
    __write_only image2d_t dst,
#else
    __global uchar *dst,
#endif
    int dstPitch,
    int uvWidth,
    int uvHeight,
    int cropX,
    int cropY,
    int valueU,
    int valueV
) {
    const int uv_x = get_global_id(0);
    const int uv_y = get_global_id(1);
    if (uv_x < uvWidth && uv_y < uvHeight) {
        TypeOut pixDstU = valueU;
        TypeOut pixDstV = valueV;
        STORE_NV12_UV(dst, uv_x + cropX, uv_y + cropY, pixDstU, pixDstV);
    }
}

