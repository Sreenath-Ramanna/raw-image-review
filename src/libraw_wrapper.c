/*
 * libraw_wrapper.c
 *
 * Thin C wrapper around the LibRaw C API.
 * Compiled as a shared library (libraw_wrapper.so) and loaded via dart:ffi.
 *
 * Build:
 *   gcc -shared -fPIC -o libraw_wrapper.so libraw_wrapper.c \
 *       $(pkg-config --cflags --libs libraw) -lm
 */

#include <libraw/libraw.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ── Result struct returned to Dart ─────────────────────────────────────── */

typedef struct {
    unsigned char* data;   /* RGBA pixel bytes, ready for Flutter           */
    int            width;
    int            height;
    int            colors; /* always 4: the wrapper widens RGB before return */
    int            bits;   /* always 8                                      */
    int            data_size; /* width * height * 4                         */
} RawImageResult;

/* ── Embedded preview returned to Dart ──────────────────────────────────── */

#define RAW_THUMB_JPEG   1   /* data is a JPEG byte stream                   */
#define RAW_THUMB_BITMAP 2   /* data is uncompressed RGB                     */

typedef struct {
    unsigned char* data;
    int            data_size;
    int            format;   /* RAW_THUMB_*                                  */
    int            width;
    int            height;
    int            flip;     /* LibRaw orientation: 0 none, 3 180, 5 CCW, 6 CW */
} RawThumbResult;

/* ── Camera metadata returned to Dart ───────────────────────────────────── */

typedef struct {
    char make[64];
    char model[64];
    float iso_speed;
    float shutter;       /* exposure time in seconds                        */
    float aperture;
    float focal_len;
    int   width;         /* as displayed, i.e. after orientation is applied  */
    int   height;
    int   flip;          /* 0 none, 3 = 180, 5 = 90 CCW, 6 = 90 CW          */
} RawImageMeta;

/* ── Autofocus point returned to Dart ───────────────────────────────────── */

#define RAW_AF_VENDOR_NONE  0
#define RAW_AF_VENDOR_CANON 1
#define RAW_AF_VENDOR_NIKON 2

/* Deliberately returns the vendor's *raw* values rather than a resolved
 * pixel position. Canon and Nikon disagree on origin and sign, and the Canon
 * Y direction is still unconfirmed — so the interpretation lives in Dart where
 * it is unit-testable and can be changed without rebuilding this library.
 * See FOCUS_POINTS.md. */
typedef struct {
    int vendor;           /* RAW_AF_VENDOR_*                                 */
    int valid;            /* 1 if x/y hold a usable focus point              */
    int x, y;             /* raw, in the vendor's own coordinate system      */
    int width, height;    /* AF area size, in AF-image space                 */
    int af_image_width;   /* the space x/y/width/height are measured against */
    int af_image_height;
    int flip;             /* orientation; AF coords are recorded unrotated   */
    int points_in_focus;  /* how many points reported focus (Canon)          */
} RawFocusPoint;

static unsigned short af_u16(const unsigned char* p) {
    return (unsigned short)(p[0] | (p[1] << 8));
}

static short af_s16(const unsigned char* p) {
    return (short)(p[0] | (p[1] << 8));
}

/* Canon AFInfo2 (MakerNote 0x0026): a flat int16 array. Fixed header, then
 * four NumAFPoints-long arrays, then bitmasks flagging which points focused. */
static void parse_canon_af(const unsigned char* d, unsigned len,
                           RawFocusPoint* out) {
    if (len < 16) return;

    unsigned num = af_u16(d + 4);
    out->af_image_width  = af_u16(d + 12);
    out->af_image_height = af_u16(d + 14);
    if (num == 0) return;

    unsigned need = 16 + num * 8;              /* widths+heights+xs+ys */
    unsigned mask_words = (num + 15) / 16;
    if (need + mask_words * 2 > len) return;

    const unsigned char* widths   = d + 16;
    const unsigned char* heights  = widths + num * 2;
    const unsigned char* xs       = heights + num * 2;
    const unsigned char* ys       = xs + num * 2;
    const unsigned char* in_focus = ys + num * 2;

    /* Average the points that reported focus. With subject tracking there is
     * usually exactly one; averaging keeps a multi-point result centred rather
     * than arbitrarily picking the first. */
    long sum_x = 0, sum_y = 0, sum_w = 0, sum_h = 0;
    int count = 0;
    for (unsigned i = 0; i < num; i++) {
        if (!(af_u16(in_focus + (i / 16) * 2) & (1u << (i % 16)))) continue;
        sum_x += af_s16(xs + i * 2);
        sum_y += af_s16(ys + i * 2);
        sum_w += af_u16(widths + i * 2);
        sum_h += af_u16(heights + i * 2);
        count++;
    }
    if (count == 0) return;

    out->x      = (int)(sum_x / count);
    out->y      = (int)(sum_y / count);
    out->width  = (int)(sum_w / count);
    out->height = (int)(sum_h / count);
    out->points_in_focus = count;
    out->valid  = 1;
}

/* Nikon AFInfo2 (MakerNote 0x00b7). Offsets are into the blob as LibRaw
 * presents it, which excludes the 4-byte version header ExifTool counts.
 * Verified against Z 6_2 files; see FOCUS_POINTS.md. */
static void parse_nikon_af(const unsigned char* d, unsigned len,
                           RawFocusPoint* out) {
    if (len < 50) return;

    out->af_image_width  = af_u16(d + 38);
    out->af_image_height = af_u16(d + 40);
    out->x               = af_u16(d + 42);
    out->y               = af_u16(d + 44);
    out->width           = af_u16(d + 46);
    out->height          = af_u16(d + 48);

    if (out->af_image_width == 0 || out->af_image_height == 0) return;
    /* A zeroed position means no AF data rather than a corner focus. */
    if (out->x == 0 && out->y == 0) return;

    out->points_in_focus = 1;
    out->valid = 1;
}

int raw_read_focus(const char* path, RawFocusPoint* out) {
    memset(out, 0, sizeof(*out));

    libraw_data_t* lr = libraw_init(0);
    if (!lr) return -1;

    if (libraw_open_file(lr, path) != LIBRAW_SUCCESS) {
        libraw_close(lr);
        return -1;
    }

    out->flip = lr->sizes.flip;

    /* MakerNotes are parsed during open, so no unpack is needed and this stays
     * as cheap as raw_read_meta. */
    for (int i = 0; i < lr->makernotes.common.afcount &&
                    i < LIBRAW_AFDATA_MAXCOUNT; i++) {
        libraw_afinfo_item_t* item = &lr->makernotes.common.afdata[i];
        if (!item->AFInfoData || item->AFInfoData_length == 0) continue;

        if (item->AFInfoData_tag == 0x0026) {
            out->vendor = RAW_AF_VENDOR_CANON;
            parse_canon_af(item->AFInfoData, item->AFInfoData_length, out);
        } else if (item->AFInfoData_tag == 0x00b7) {
            out->vendor = RAW_AF_VENDOR_NIKON;
            parse_nikon_af(item->AFInfoData, item->AFInfoData_length, out);
        }
        if (out->valid) break;
    }

    libraw_close(lr);
    return 0;
}

/* ── Widen packed RGB to RGBA ───────────────────────────────────────────── */

/* One 32-bit store per pixel rather than four byte stores. The destination
 * comes from malloc and every offset is a multiple of 4, so the writes are
 * aligned; -O3 vectorises this readily.
 *
 * The shift order assumes a little-endian host, which is what Flutter's
 * PixelFormat.rgba8888 expects on x86-64 and aarch64 alike. */
static void expand_rgb_to_rgba(const unsigned char* src, unsigned char* dst,
                               size_t pixels) {
    uint32_t* out = (uint32_t*)dst;
    for (size_t i = 0; i < pixels; i++) {
        const unsigned char* p = src + i * 3;
        out[i] = 0xFF000000u | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) |
                 (uint32_t)p[0];
    }
}

/* ── Decode a raw file to an 8-bit RGBA bitmap ──────────────────────────── */

RawImageResult* raw_decode_file(const char* path) {
    libraw_data_t* lr = libraw_init(0);
    if (!lr) return NULL;

    /* Use sensible defaults for quick preview quality */
    lr->params.use_camera_wb   = 1;   /* use camera white balance            */
    lr->params.output_bps      = 8;   /* 8 bits per channel output           */
    lr->params.half_size       = 0;   /* full resolution                     */
    lr->params.no_auto_bright  = 0;

    /* PPG rather than LibRaw's default AHD. Measured on a 33 MP CR3: 1390 ms
     * against 2081 ms, a 1.5x saving on the step that is ~82% of the decode.
     * The cost is small — median difference from AHD is 1/255 and the 90th
     * percentile is 6 — though the tail lands on high-frequency edges, so a
     * dedicated raw converter is still the right tool for final output.
     * This viewer exists to judge keep-or-discard, where that does not matter.
     * 0 linear, 1 VNG, 2 PPG, 3 AHD, 4 DCB, 11 DHT, 12 AAHD. */
    lr->params.user_qual       = 2;

    if (libraw_open_file(lr, path) != LIBRAW_SUCCESS) {
        libraw_close(lr);
        return NULL;
    }

    if (libraw_unpack(lr) != LIBRAW_SUCCESS) {
        libraw_close(lr);
        return NULL;
    }

    if (libraw_dcraw_process(lr) != LIBRAW_SUCCESS) {
        libraw_close(lr);
        return NULL;
    }

    int errc = 0;
    libraw_processed_image_t* img = libraw_dcraw_make_mem_image(lr, &errc);
    if (!img || errc != LIBRAW_SUCCESS) {
        libraw_close(lr);
        return NULL;
    }

    RawImageResult* result = (RawImageResult*)malloc(sizeof(RawImageResult));
    if (!result) {
        libraw_dcraw_clear_mem(img);
        libraw_close(lr);
        return NULL;
    }

    /* Only 8-bit output is produced (output_bps is pinned to 8 above), and
     * LibRaw emits 3 or 4 components. Anything else would silently misread the
     * buffer, so refuse it rather than guess. */
    if (img->bits != 8 || (img->colors != 3 && img->colors != 4)) {
        free(result);
        libraw_dcraw_clear_mem(img);
        libraw_close(lr);
        return NULL;
    }

    const size_t pixels = (size_t)img->width * (size_t)img->height;
    const size_t rgba_size = pixels * 4;

    result->width      = img->width;
    result->height     = img->height;
    result->colors     = 4;            /* always RGBA leaving here */
    result->bits       = 8;
    result->data_size  = (int)rgba_size;
    result->data       = (unsigned char*)malloc(rgba_size);

    if (!result->data) {
        free(result);
        libraw_dcraw_clear_mem(img);
        libraw_close(lr);
        return NULL;
    }

    /* Expand to RGBA here rather than in Dart. This costs almost nothing: the
     * bytes were already being copied out of LibRaw's buffer, so widening
     * during that pass replaces the memcpy instead of adding a second sweep.
     * It also spares Dart a full-image loop over ~30M pixels. */
    if (img->colors == 3) {
        expand_rgb_to_rgba(img->data, result->data, pixels);
    } else {
        memcpy(result->data, img->data, rgba_size);
    }

    libraw_dcraw_clear_mem(img);
    libraw_close(lr);
    return result;
}

/* ── Read metadata without full decoding (fast) ─────────────────────────── */

int raw_read_meta(const char* path, RawImageMeta* out) {
    libraw_data_t* lr = libraw_init(0);
    if (!lr) return -1;

    if (libraw_open_file(lr, path) != LIBRAW_SUCCESS) {
        libraw_close(lr);
        return -1;
    }

    strncpy(out->make,  lr->idata.make,  sizeof(out->make)  - 1);
    strncpy(out->model, lr->idata.model, sizeof(out->model) - 1);
    out->make[sizeof(out->make)   - 1] = '\0';
    out->model[sizeof(out->model) - 1] = '\0';

    out->iso_speed  = lr->other.iso_speed;
    out->shutter    = lr->other.shutter;
    out->aperture   = lr->other.aperture;
    out->focal_len  = lr->other.focal_len;
    out->flip       = lr->sizes.flip;

    /* sizes.width/height describe the unrotated sensor area, but
     * dcraw_process applies the camera orientation — so a portrait frame
     * decodes transposed. Report what the user will actually see, otherwise
     * every portrait shot claims landscape dimensions. */
    if (lr->sizes.flip == 5 || lr->sizes.flip == 6) {
        out->width  = lr->sizes.height;
        out->height = lr->sizes.width;
    } else {
        out->width  = lr->sizes.width;
        out->height = lr->sizes.height;
    }

    libraw_close(lr);
    return 0;
}

/* ── Extract the embedded preview (fast path) ───────────────────────────── */

/* Cameras embed a full-size JPEG rendering of the frame. Pulling that out
 * costs tens of milliseconds against seconds for a full demosaic, so it is
 * used to put something on screen while raw_decode_file runs.
 *
 * The JPEG is handed to Dart undecoded — Flutter decodes JPEG natively, and
 * doing it there avoids a libjpeg dependency here. Note the preview is stored
 * unrotated, so `flip` must be applied by the caller; raw_decode_file's output
 * is already rotated by dcraw_process. */
RawThumbResult* raw_decode_thumb(const char* path) {
    libraw_data_t* lr = libraw_init(0);
    if (!lr) return NULL;

    if (libraw_open_file(lr, path) != LIBRAW_SUCCESS) {
        libraw_close(lr);
        return NULL;
    }

    if (libraw_unpack_thumb(lr) != LIBRAW_SUCCESS) {
        libraw_close(lr);
        return NULL;
    }

    int format;
    switch (lr->thumbnail.tformat) {
        case LIBRAW_THUMBNAIL_JPEG:   format = RAW_THUMB_JPEG;   break;
        case LIBRAW_THUMBNAIL_BITMAP: format = RAW_THUMB_BITMAP; break;
        default:
            /* 16-bit, layered and video previews are not worth handling: the
             * full decode is on its way regardless. */
            libraw_close(lr);
            return NULL;
    }

    if (!lr->thumbnail.thumb || lr->thumbnail.tlength == 0) {
        libraw_close(lr);
        return NULL;
    }

    RawThumbResult* out = (RawThumbResult*)malloc(sizeof(RawThumbResult));
    if (!out) {
        libraw_close(lr);
        return NULL;
    }

    out->data_size = (int)lr->thumbnail.tlength;
    out->format    = format;
    out->width     = lr->thumbnail.twidth;
    out->height    = lr->thumbnail.theight;
    out->flip      = lr->sizes.flip;
    out->data      = (unsigned char*)malloc(lr->thumbnail.tlength);

    if (!out->data) {
        free(out);
        libraw_close(lr);
        return NULL;
    }

    memcpy(out->data, lr->thumbnail.thumb, lr->thumbnail.tlength);

    libraw_close(lr);
    return out;
}

void raw_free_thumb(RawThumbResult* thumb) {
    if (thumb) {
        free(thumb->data);
        free(thumb);
    }
}

/* ── Free the result buffer ─────────────────────────────────────────────── */

void raw_free_result(RawImageResult* result) {
    if (result) {
        free(result->data);
        free(result);
    }
}
