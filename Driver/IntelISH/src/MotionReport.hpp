// SPDX-License-Identifier: GPL-2.0-only
// Portable motion-report layer for the macOS Intel ISH port.
// Usage IDs and signedness follow Intel's Linux hid-sensor-accel-3d.c,
// hid-sensor-gyro-3d.c and include/linux/hid-sensor-ids.h.
#pragma once
#include <stdint.h>
#include <stddef.h>

namespace motion {
enum class Kind { Acceleration, Gravity, AngularVelocity };
struct Field {
    uint32_t bitOffset; // Relative to payload AFTER any report-ID byte.
    uint8_t bitSize;
    int64_t logicalMinimum;
    int64_t logicalMaximum;
    uint32_t unit;
    int8_t exponent; // Decoded HID signed four-bit exponent, -8..7.
};
struct Layout {
    Kind kind;
    uint8_t reportID;
    bool hasReportID;
    uint32_t payloadBits; // Includes padding and fields unrelated to axes.
    Field axes[3];
};
struct Sample {
    Kind kind;
    int64_t axes[3]; // Raw values; preserve metadata, never assume g or radians.
    uint64_t timestampNS;
};
enum class Result { OK, InvalidLayout, WrongReport, Truncated, OutOfRange };

inline int8_t exponent(uint8_t encoded) {
    encoded &= 15;
    return static_cast<int8_t>(encoded < 8 ? int(encoded) : int(encoded) - 16);
}
inline bool valid(const Layout &layout) {
    if (!layout.payloadBits || layout.payloadBits > 65536 ||
        (layout.hasReportID && !layout.reportID)) return false;
    for (unsigned i = 0; i < 3; ++i) {
        const auto &f = layout.axes[i];
        if (!f.bitSize || f.bitSize > 32 || f.bitOffset > layout.payloadBits ||
            f.bitSize > layout.payloadBits - f.bitOffset ||
            f.logicalMinimum > f.logicalMaximum || f.exponent < -8 || f.exponent > 7)
            return false;
        const int64_t lowest = f.logicalMinimum < 0 ? -(int64_t(1) << (f.bitSize - 1)) : 0;
        const int64_t highest = f.logicalMinimum < 0 ? (int64_t(1) << (f.bitSize - 1)) - 1 :
                                                      (int64_t(1) << f.bitSize) - 1;
        if (f.logicalMinimum < lowest || f.logicalMaximum > highest) return false;
        for (unsigned j = 0; j < i; ++j) {
            const auto &other = layout.axes[j];
            if (f.bitOffset < other.bitOffset + other.bitSize &&
                other.bitOffset < f.bitOffset + f.bitSize) return false;
        }
    }
    return true;
}
inline Result decode(const Layout &layout, const uint8_t *report, size_t length,
                     uint64_t timestampNS, Sample &output) {
    if (!valid(layout)) return Result::InvalidLayout;
    if (!report || !length) return Result::Truncated;
    if (layout.hasReportID) {
        if (*report != layout.reportID) return Result::WrongReport;
        ++report; --length;
    }
    if (length < (layout.payloadBits + 7) / 8) return Result::Truncated;
    Sample next {layout.kind, {0, 0, 0}, timestampNS};
    for (unsigned axis = 0; axis < 3; ++axis) {
        const auto &f = layout.axes[axis];
        uint64_t raw = 0;
        for (unsigned bit = 0; bit < f.bitSize; ++bit) {
            const uint32_t at = f.bitOffset + bit;
            raw |= uint64_t((report[at / 8] >> (at % 8)) & 1) << bit;
        }
        int64_t value = static_cast<int64_t>(raw);
        if (f.logicalMinimum < 0 && (raw & (uint64_t(1) << (f.bitSize - 1))))
            value -= int64_t(1) << f.bitSize;
        if (value < f.logicalMinimum || value > f.logicalMaximum) return Result::OutOfRange;
        next.axes[axis] = value;
    }
    output = next; // Reject bad packets without partially changing the sample.
    return Result::OK;
}
inline bool usage(Kind kind, uint32_t collection, uint32_t field, unsigned &axis) {
    const uint32_t expected = kind == Kind::AngularVelocity ? 0x200076 :
                              kind == Kind::Gravity ? 0x20007b : 0x200073;
    const uint32_t first = kind == Kind::AngularVelocity ? 0x200457 : 0x200453;
    if (collection != expected || field < first || field > first + 2) return false;
    axis = field - first;
    return true;
}
}
