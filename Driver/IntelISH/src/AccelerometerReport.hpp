// SPDX-License-Identifier: GPL-2.0-only
// Copyright © 2026 yjmd2222. All rights reserved.
#pragma once
#include "ALSReport.hpp"
#include "MotionReport.hpp"
namespace ISHAccel {
using ISHALS::Field;
using ISHALS::signedValue;
using ISHALS::extract;
using ISHALS::insert;
struct Layout {
    unsigned report {0}, featureBytes {0}, inputBytes {0};
    Field power, reporting, interval, axes[3];
};
// Parse HID short items, preserving separate input/feature offsets per report.
// Only accelerometer scalar controls are selected; all fields still advance report offsets.
inline bool parse(const unsigned char *bytes, unsigned size, Layout &out) {
    if (!bytes || !size || size > 4096) return false;
    struct Global {
        unsigned page {0}, report {0}, width {0}, count {0}, unit {0};
        int exponent {0}; long long minimum {0}, maximum {0};
    } g, saved[8];
    unsigned savedCount = 0, collections[32] {}, depth = 0;
    unsigned usages[64] {}, usageCount = 0, bits[3][256] {};
    Layout result;
    bool inAccel = false;
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
            } else return false; // Usage ranges/delimiters unsupported in this accelerometer port.
        } else if (type == 0) {
            if (tag == 10) {
                if (depth == 32) return false;
                unsigned usage = usageCount ? usages[0] : 0;
                collections[depth++] = usage;
                if (usage == 0x200073) {
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
                inAccel = false;
                for (unsigned i = 0; i < depth; ++i) if (collections[i] == 0x200073) inAccel = true;
                if (inAccel && !(value & 1)) {
                    unsigned usage = (value & 2) ? (usageCount ? usages[0] : 0) :
                        (depth ? collections[depth - 1] : 0);
                    Field *field = nullptr; unsigned enabledUsage = 0;
                    if (kind == 2 && usage == 0x200319) { field = &result.power; enabledUsage = 0x200851; }
                    if (kind == 2 && usage == 0x200316) { field = &result.reporting; enabledUsage = 0x200841; }
                    if (kind == 2 && usage == 0x20030e) field = &result.interval;
                    if (kind == 0 && usage >= 0x200453 && usage <= 0x200455 && (value & 2)) field = &result.axes[usage - 0x200453];
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
        !result.interval.width || !result.axes[0].width || !result.axes[1].width || !result.axes[2].width) return false;
    result.featureBytes = 1 + (bits[2][result.report] + 7) / 8;
    result.inputBytes = 1 + (bits[0][result.report] + 7) / 8;
    if (result.featureBytes > 512 || result.inputBytes > 512) return false;
    out = result; return true;
}
inline motion::Layout motionLayout(const Layout &layout) {
    motion::Layout m {motion::Kind::Acceleration, static_cast<uint8_t>(layout.report), true,
                      (layout.inputBytes - 1) * 8, {}};
    for (unsigned i = 0; i < 3; ++i) {
        const auto &f = layout.axes[i];
        m.axes[i] = {f.bit - 8, static_cast<uint8_t>(f.width), f.minimum, f.maximum,
                     f.unit, static_cast<int8_t>(f.exponent)};
    }
    return m;
}
}
