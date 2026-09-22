#include "zstd_shim.h"

/* Anchor symbol so the CZSTD target has a compiled object and links libzstd. */
int codexling_zstd_anchor(void) {
    return (int)ZSTD_VERSION_NUMBER;
}
