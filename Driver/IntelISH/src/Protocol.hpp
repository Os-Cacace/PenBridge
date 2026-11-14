// SPDX-License-Identifier: GPL-2.0-only
// Copyright © 2026 yjmd2222. All rights reserved.
#pragma once
namespace ISHProtocol {
struct Header {
    unsigned firmware, host, length;
    bool complete;
};
inline unsigned little16(const unsigned char *p) { return p[0] | (unsigned(p[1]) << 8); }
inline unsigned little32(const unsigned char *p) {
    return little16(p) | (little16(p + 2) << 16);
}
inline bool parse(const unsigned char *p, unsigned size, Header &out) {
    if (!p || size < 4 || size > 128) return false;
    unsigned word = little32(p);
    Header result {p[0], p[1], (word >> 16) & 511, bool(word & 0x80000000U)};
    if ((word & 0x7e000000U) || result.length != size - 4) return false;
    out = result; return true;
}
struct Assembly {
    unsigned char bytes[4096] {};
    unsigned used {0};
    bool append(const unsigned char *p, unsigned size, unsigned limit) {
        if (!p || limit > sizeof(bytes) || used > limit || size > limit - used) return false;
        for (unsigned i = 0; i < size; ++i) bytes[used + i] = p[i];
        used += size; return true;
    }
};
}
