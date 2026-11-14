// SPDX-License-Identifier: GPL-2.0-only
// Copyright © 2026 yjmd2222. All rights reserved.
#pragma once
#include "Protocol.hpp"
namespace ISHALS {
struct Field {
    unsigned bit {0}, width {0}, unit {0}, enabledValue {0};
    int exponent {0};
    long long minimum {0}, maximum {0};
};
struct Layout {
    unsigned report {0}, featureBytes {0}, inputBytes {0};
    Field power, reporting, interval, illuminance;
};
inline long long signedValue(unsigned value, unsigned bits) {
    if (!bits || bits > 32) return 0;
    return (value & (1U << (bits - 1))) ? static_cast<long long>(value) - (1LL << bits) : value;
}
inline bool extract(const unsigned char *bytes, unsigned size, const Field &f, unsigned &out) {
    if (!bytes || !f.width || f.width > 32 || f.bit > size * 8 || f.width > size * 8 - f.bit) return false;
    unsigned value = 0;
    for (unsigned i = 0; i < f.width; ++i)
        value |= unsigned((bytes[(f.bit + i) / 8] >> ((f.bit + i) % 8)) & 1) << i;
    out = value; return true;
}
inline bool insert(unsigned char *bytes, unsigned size, const Field &f, unsigned value) {
    unsigned old;
    if (!extract(bytes, size, f, old) || static_cast<long long>(value) < f.minimum ||
        static_cast<long long>(value) > f.maximum || (f.width < 32 && (value >> f.width))) return false;
    for (unsigned i = 0; i < f.width; ++i) {
        unsigned bit = f.bit + i; unsigned char mask = 1U << (bit % 8);
        bytes[bit / 8] = (bytes[bit / 8] & ~mask) | (((value >> i) & 1) ? mask : 0);
    }
    return true;
}
// Parse HID short items, preserving separate input/feature offsets per report.
// Only ALS scalar controls are selected; all fields still advance report offsets.
inline bool parse(const unsigned char *bytes, unsigned size, Layout &out) {
    if (!bytes || !size || size > 4096) return false;
    struct Global {
        unsigned page {0}, report {0}, width {0}, count {0}, unit {0};
        int exponent {0}; long long minimum {0}, maximum {0};
    } g, saved[8];
    unsigned savedCount = 0, collections[32] {}, depth = 0;
    unsigned usages[64] {}, usageCount = 0, bits[3][256] {};
    Layout result;
    bool inALS = false;
    for (unsigned pos = 0; pos < size;) {
        unsigned lead = bytes[pos++];
        if (lead == 254) return false; // Unsupported long items are never guessed.
        unsigned n = (lead & 3) == 3 ? 4 : lead & 3;
        if (n > size - pos) return false;
        unsigned value = 0;
        for (unsigned i = 0; i < n; ++i) value |= unsigned(bytes[pos + i]) << (i * 8);
        pos += n;
        unsigned type = (lead >> 2) & 3, tag = lead >> 4;
        if (type == 1) {
            switch (tag) {
                case 0: g.page = value; break;
                case 1: g.minimum = signedValue(value, n * 8); break;
                case 2: g.maximum = g.minimum < 0 ? signedValue(value, n * 8) : value; break;
                case 5: g.exponent = (value & 8) ? int(value & 15) - 16 : int(value & 15); break;
                case 6: g.unit = value; break;
                case 7: g.width = value; break;
                case 8: if (!value || value > 255) return false; g.report = value; break;
                case 9: g.count = value; break;
                case 10: if (savedCount == 8) return false; saved[savedCount++] = g; break;
                case 11: if (!savedCount) return false; g = saved[--savedCount]; break;
                default: break;
            }
        } else if (type == 2) {
            if (tag == 0) {
                if (usageCount == 64) return false;
                usages[usageCount++] = n == 4 ? value : (g.page << 16) | value;
            } else return false; // Usage ranges/delimiters unsupported in this ALS port.
        } else if (type == 0) {
            if (tag == 10) {
                if (depth == 32) return false;
                unsigned usage = usageCount ? usages[0] : 0;
                collections[depth++] = usage;
                if (usage == 0x200041) {
                    if (result.report) return false;
                    result.report = g.report;
                    if (!result.report) return false;
                }
            } else if (tag == 12) {
                if (!depth) return false; --depth;
            } else if (tag == 8 || tag == 9 || tag == 11) {
                unsigned kind = tag == 8 ? 0 : tag == 9 ? 1 : 2;
                // Fields wider than 32 bits (Dell's 192-bit custom values) only advance the
                // offsets; the controls and axes read below must still be 32 bits or less.
                if (!g.width || !g.count || g.width > 255 || g.count > 2048 ||
                    g.width * g.count > 16384 - bits[kind][g.report]) return false;
                inALS = false;
                for (unsigned i = 0; i < depth; ++i) if (collections[i] == 0x200041) inALS = true;
                if (inALS && !(value & 1)) {
                    unsigned usage = (value & 2) ? (usageCount ? usages[0] : 0) :
                        (depth ? collections[depth - 1] : 0);
                    Field *field = nullptr; unsigned enabledUsage = 0;
                    if (kind == 2 && usage == 0x200319) { field = &result.power; enabledUsage = 0x200851; }
                    if (kind == 2 && usage == 0x200316) { field = &result.reporting; enabledUsage = 0x200841; }
                    if (kind == 2 && usage == 0x20030e) field = &result.interval;
                    if (kind == 0 && usage == 0x2004d1) field = &result.illuminance;
                    if (field) {
                        if (field->width || g.report != result.report || g.count != 1 || g.width > 32) return false;
                        *field = {bits[kind][g.report] + 8, g.width, g.unit, 0,
                                  g.exponent, g.minimum, g.maximum};
                        if (enabledUsage) {
                            bool found = false;
                            for (unsigned i = 0; i < usageCount; ++i) if (usages[i] == enabledUsage) {
                                if (g.minimum < 0 || g.minimum + i > g.maximum) return false;
                                field->enabledValue = static_cast<unsigned>(g.minimum) + i; found = true;
                            }
                            if (!found) return false;
                        }
                    }
                }
                bits[kind][g.report] += g.width * g.count;
            }
            usageCount = 0;
        }
    }
    if (depth || savedCount || !result.report || !result.power.width || !result.reporting.width ||
        !result.interval.width || !result.illuminance.width) return false;
    result.featureBytes = 1 + (bits[2][result.report] + 7) / 8;
    result.inputBytes = 1 + (bits[0][result.report] + 7) / 8;
    if (result.featureBytes > 512 || result.illuminance.minimum < 0 ||
        (result.illuminance.unit != 0 && result.illuminance.unit != 1)) return false;
    out = result; return true;
}
inline bool milliLux(const unsigned char *bytes, unsigned size, const Layout &layout,
                     unsigned long long &value) {
    if (!bytes || size != layout.inputBytes || bytes[0] != layout.report) return false;
    unsigned raw;
    // Linux ALS accepts the reported u32; this firmware exceeds its declared
    // logical maximum (real packet 21685, declared maximum 10000).
    // Preserve packet/bit bounds and scaling; logical limits still guard writes.
    if (!extract(bytes, size, layout.illuminance, raw)) return false;
    unsigned long long scaled = raw;
    int exponent = layout.illuminance.exponent + 3;
    if (exponent > 10 || exponent < -8) return false;
    while (exponent > 0) { if (scaled > (~0ULL) / 10) return false; scaled *= 10; --exponent; }
    while (exponent < 0) { scaled /= 10; ++exponent; }
    value = scaled; return true;
}
}
