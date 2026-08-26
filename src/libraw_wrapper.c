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
#include <stdlib.h>
#include <string.h>

/* ── Result struct returned to Dart ─────────────────────────────────────── */

typedef struct {
    unsigned char* data;   /* RGB or RGBA pixel bytes                       */
    int            width;
    int            height;
    int            colors; /* 3 = RGB, 4 = RGBA                             */
    int            bits;   /* 8 or 16 bits per channel                      */
    int            data_size;
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
    int   width;
    int   height;
} RawImageMeta;

/* ── Decode a raw file to an 8-bit RGB bitmap ───────────────────────────── */

RawImageResult* raw_decode_file(const char* path) {
    libraw_data_t* lr = libraw_init(0);
    if (!lr) return NULL;

    /* Use sensible defaults for quick preview quality */
    lr->params.use_camera_wb   = 1;   /* use camera white balance            */
    lr->params.output_bps      = 8;   /* 8 bits per channel output           */
    lr->params.half_size       = 0;   /* full resolution                     */
    lr->params.no_auto_bright  = 0;

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

    result->width      = img->width;
    result->height     = img->height;
    result->colors     = img->colors;
    result->bits       = img->bits;
    result->data_size  = (int)img->data_size;
    result->data       = (unsigned char*)malloc(img->data_size);

    if (!result->data) {
        free(result);
        libraw_dcraw_clear_mem(img);
        libraw_close(lr);
        return NULL;
    }

    memcpy(result->data, img->data, img->data_size);

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
    out->width      = lr->sizes.width;
    out->height     = lr->sizes.height;

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
