// SPDX-License-Identifier: GPL-2.0-only
// Copyright © 2026 yjmd2222. All rights reserved.
// macOS port groundwork for Intel ISH. Register definitions follow Intel's
// drivers/hid/intel-ish-hid/ipc/{hw-ish-regs.h,hw-ish.h,pci-ish.c}.
// IntelISH-CML: also matches Cannon/Comet Lake ISH (8086:9dfc, a37c, 02fc), drops the
// VirtualSMC light keys (no Lilu/VirtualSMC dependency), streams the accelerometer when the
// hub has no light sensor, and always publishes the report descriptors for diagnosis.
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOCommandGate.h>
#include <IOKit/pwr_mgt/IOPM.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOInterruptEventSource.h>
#include <libkern/OSByteOrder.h>
#include "Protocol.hpp"
#include "ALSReport.hpp"
#include "AccelerometerReport.hpp"
#include <kern/clock.h>
#include <pexpert/pexpert.h>
// Per-packet protocol tracing floods the kernel log buffer (tens of thousands of lines per
// minute); it is off unless the boot-arg -ishtrace is present. Errors and state changes still log.
static bool gIshTrace = false, gIshALS = false;
#define ISH_TRACE(...) do { if (gIshTrace) IOLog(__VA_ARGS__); } while (0)

class IntelISH : public IOService {
    OSDeclareDefaultStructors(IntelISH)
    IOPCIDevice *pci {nullptr};
    IOMemoryMap *mapping {nullptr};
    IOWorkLoop *loop {nullptr};
    IOTimerEventSource *timer {nullptr};
    IOInterruptEventSource *interrupt {nullptr};
    bool interruptAdded {false}, transportStarted {false};
    IOCommandGate *gate {nullptr};
    bool gateAdded {false}, pmStarted {false}, suspended {false};
    unsigned wakeCount {0};
    UInt16 deviceID {0};
    void restartTransport();
    static IOReturn powerAction(OSObject *owner, void *state, void *, void *, void *);
    UInt32 savedMask {0}, savedHost {0}, savedDMA {0};
    enum Stage { ResetSend, ResetWait, ReadyWait, VersionWait, EnumWait,
                 PropertiesWait, ConnectWait, HIDEnumWait, HIDDescriptorWait, ReportDescriptorWait, ALSFeatureGet, ALSFeatureSet, ALSFeatureVerify, ALSInputWait, AccelFeatureGet, AccelFeatureSet, AccelFeatureVerify, AccelInputWait, Streaming, Listening, DebugWait, Complete, Failed };
    Stage stage {ResetSend};
    unsigned elapsed {0}, deadline {1000}, totalTicks {0};
    unsigned client {0}, clientCount {0}, hidAddress {0};
    UInt8 clientMap[32] {};
    unsigned hidMaxMessage {0}, txCredits {0};
    bool connected {false}, requestPending {false};
    UInt8 pendingCommand {0}, pendingDevice {0};
    unsigned deviceCount {0}, deviceIndex {0};
    UInt8 deviceIDs[32] {};
    ISHProtocol::Assembly assembly;
    ISHALS::Layout als;
    bool alsFound {false}, streamingStarted {false};
    UInt8 alsDevice {0}, feature[512] {}, originalFeature[512] {};
    UInt8 requestData[512] {};
    unsigned requestSize {0}, lightSamples {0};
    ISHAccel::Layout accel;
    bool accelFound {false}, accelSetup {false}, accelReady {false};
    UInt8 accelDevice {0}, accelFeature[512] {};
    unsigned accelSamples {0}, pollCycle {0};
    unsigned unexpectedCount {0}, publishCount {0}, inputFailures {0}, debugSequence {0}, debugTimeouts {0};
    bool debugEnabled {false};
    Stage debugReturn {Listening};
    void recordUnexpected(const UInt8 *bytes, unsigned size);
    void notePublish(UInt8 device, const UInt8 *payload, unsigned length);
    void stepFailed(const char *reason, const UInt8 *bytes, unsigned size);
    void resume(Stage next);
    static IOReturn debugAction(OSObject *owner, void *data, void *, void *, void *);
    void beginAccel();
    void requestAccel(UInt8 command, Stage next, const char *name);
    bool accelInput(UInt8 device, const UInt8 *bytes, unsigned size);
    void beginALS();
    void requestReport(UInt8 command, Stage next, const char *name);
    bool lightInput(UInt8 device, const UInt8 *bytes, unsigned size);
    void sendISHTP(UInt8 firmware, UInt8 host, const UInt8 *bytes, unsigned size);
    void clientControl(UInt8 command);
    void requestHID(UInt8 command, UInt8 device, Stage next, const char *name);
    void sendHIDRequest();
    void receiveHID(const UInt8 *bytes, unsigned size);
    void receiveHIDMessage(const UInt8 *bytes, unsigned size);
    void dump(const char *label, const UInt8 *bytes, unsigned size);
    struct Packet { UInt32 doorbell; UInt8 bytes[128]; };
    Packet queue[8] {};
    unsigned head {0}, queued {0};
    unsigned samples {0};
    UInt32 read(UInt32 offset);
    void write(UInt32 offset, UInt32 value);
    void advance(Stage next, const char *name, unsigned timeout = 500);
    void fail(const char *reason);
    bool queuePacket(unsigned protocol, unsigned command, const UInt8 *bytes, unsigned size);
    void hbm(UInt8 command, UInt8 address = 0);
    void nextClient();
    void receive(UInt32 doorbell, const UInt8 *bytes, unsigned size);
    void pump();
    static void irq(OSObject *owner, IOInterruptEventSource *, int);
    UInt16 originalCommand {0};
    bool commandSaved {false};
    bool timerAdded {false};
    void snapshot();
    void cleanup();
    static void tick(OSObject *owner, IOTimerEventSource *source);
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn setPowerState(unsigned long state, IOService *) override;
    IOReturn setProperties(OSObject *properties) override;
};
OSDefineMetaClassAndStructors(IntelISH, IOService)

bool IntelISH::start(IOService *provider) {
    if (!IOService::start(provider)) return false;
    { char arg[8]; gIshTrace = PE_parse_boot_argn("-ishtrace", arg, sizeof(arg));
      gIshALS = PE_parse_boot_argn("-ishals", arg, sizeof(arg)); }
    pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci || pci->configRead16(kIOPCIConfigVendorID) != 0x8086) return false;
    // Sunrise Point-LP, Cannon Point-LP, Cannon Point-H, Comet Lake-LP: same IPC registers.
    deviceID = pci->configRead16(kIOPCIConfigDeviceID);
    if (deviceID != 0x9d35 && deviceID != 0x9dfc && deviceID != 0xa37c && deviceID != 0x02fc) return false;
    originalCommand = pci->configRead16(kIOPCIConfigCommand);
    commandSaved = true;
    // BAR address is supplied by PCI; never guess a physical address.
    pci->setMemoryEnable(true);
    // Kext IOLog lines don't reach the unified log on every system, so failures stay visible
    // in IORegistry: the driver stays attached, idle, with StartError set.
    setProperty("PCIDeviceID", deviceID, 16);
    debugEnabled = getProperty("DebugRequests") == kOSBooleanTrue;
    mapping = pci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0);
    if (!mapping || mapping->getLength() < 0x400) {
        IOLog("IntelISH: BAR0 unavailable or too small\n");
        setProperty("StartError", "BAR0 unavailable or too small");
        cleanup(); registerService(); return true;
    }
    loop = IOWorkLoop::workLoop();
    timer = IOTimerEventSource::timerEventSource(this, tick);
    if (!loop || !timer || loop->addEventSource(timer) != kIOReturnSuccess) {
        setProperty("StartError", "work loop or timer unavailable");
        cleanup(); registerService(); return true;
    }
    timerAdded = true;
    // Comet Lake's ISH has no MSI capability and, on some boards, no routed INTx either.
    // The 10 ms timer already drains the mailbox, so fall back to polling alone.
    auto specifiers = OSDynamicCast(OSArray, pci->getProperty("IOInterruptSpecifiers"));
    if (specifiers && specifiers->getCount() && (interrupt = IOInterruptEventSource::interruptEventSource(this, irq, pci)) &&
        loop->addEventSource(interrupt) == kIOReturnSuccess) {
        interruptAdded = true;
        setProperty("InterruptMode", "interrupt and polling");
    } else {
        if (interrupt) { interrupt->release(); interrupt = nullptr; }
        IOLog("IntelISH: no interrupt source, polling only\n");
        setProperty("InterruptMode", "polling");
    }
    savedMask = read(0x08); savedHost = read(0x38); savedDMA = read(0x368);
    setProperty("PortStage", "ALS and accelerometer descriptor-driven reports");
    setProperty("BAR0Physical", mapping->getPhysicalAddress(), 64);
    IOLog("IntelISH: 8086:%04x revision=%02x BAR0=%llx length=%llu PCI command=%04x\n",
          deviceID, pci->configRead8(kIOPCIConfigRevisionID),
          (unsigned long long)mapping->getPhysicalAddress(),
          (unsigned long long)mapping->getLength(), originalCommand);
    snapshot();
    gate = IOCommandGate::commandGate(this);
    if (!gate || loop->addEventSource(gate) != kIOReturnSuccess) {
        setProperty("StartError", "command gate unavailable");
        cleanup(); registerService(); return true;
    }
    gateAdded = true;
    restartTransport();
    PMinit(); pmStarted = true;
    static IOPMPowerState states[2] = {};
    states[0].version = states[1].version = 1;
    states[1].capabilityFlags = kIOPMPowerOn;
    states[1].outputPowerCharacter = kIOPMPowerOn;
    states[1].inputPowerRequirement = kIOPMPowerOn;
    provider->joinPMtree(this);
    registerPowerDriver(this, states, 2);
    registerService();
    return true;
}

// All transport state and MMIO changes serialize with timer/IRQ callbacks.
IOReturn IntelISH::setPowerState(unsigned long state, IOService *) {
    if (gate) gate->runAction(powerAction, reinterpret_cast<void *>(state));
    return kIOPMAckImplied;
}
IOReturn IntelISH::powerAction(OSObject *owner, void *state, void *, void *, void *) {
    auto *self = OSDynamicCast(IntelISH, owner);
    if (!self || !self->mapping) return kIOReturnNotReady;
    bool sleep = reinterpret_cast<uintptr_t>(state) == 0;
    if (sleep == self->suspended) return kIOReturnSuccess;
    self->suspended = sleep;
    self->setProperty("Suspended", sleep);
    self->setProperty("ALSControlsVerified", false);
    self->setProperty("AccelControlsVerified", false);
    self->removeProperty("AccelSample");
    if (sleep) {
        IOLog("IntelISH: PM sleep; stopping polling and mailbox access\n");
        self->timer->cancelTimeout();
        if (self->interrupt) self->interrupt->disable();
        self->snapshot();
        self->write(0x08, self->read(0x08) & ~1U);
        self->write(0x38, self->read(0x38) & ~0x80U);
        // Linux's firmware-sleep path clears DMA before PCI enters D3.
        self->write(0x368, 0);
        self->stage = Complete;
        self->setProperty("TransportState", "suspended");
    } else {
        self->setProperty("WakeCount", ++self->wakeCount, 32);
        IOLog("IntelISH: PM wake=%u; restarting IPC/HBM/HID and ALS controls\n", self->wakeCount);
        self->restartTransport();
    }
    return kIOReturnSuccess;
}
void IntelISH::restartTransport() {
    timer->cancelTimeout(); if (interrupt) interrupt->disable();
    head = queued = elapsed = totalTicks = 0;
    client = clientCount = hidAddress = hidMaxMessage = txCredits = 0;
    deviceCount = deviceIndex = requestSize = 0;
    connected = requestPending = alsFound = streamingStarted = false;
    assembly.used = 0;
    bzero(clientMap, sizeof(clientMap));
    als = ISHALS::Layout{};
    accel = ISHAccel::Layout{}; accelFound = accelSetup = accelReady = false;
    accelSamples = pollCycle = inputFailures = 0;
    setProperty("AccelControlsVerified", false); setProperty("AccelSampleCount", 0ULL, 32);
    removeProperty("AccelSample"); removeProperty("AccelError");
    removeProperty("TransportError"); removeProperty("ALSInputError");
    setProperty("HIDConnected", false); setProperty("ALSControlsVerified", false);
    removeProperty("ALSMilliLux"); removeProperty("ALSRawIlluminance");
    pci->setMemoryEnable(true); pci->setBusMasterEnable(true);
    transportStarted = true;
    write(0x38, read(0x38) | 0x80);
    write(0x08, (read(0x08) | 1) & ~0x100U);
    write(0x368, 1); write(0x54, 0);
    advance(ResetSend, "reset-send", 1000);
    UInt8 reset[4] = {1, 0, 0, 0};
    queuePacket(3, 3, reset, sizeof(reset));
    if (interrupt) interrupt->enable();
    timer->setTimeoutMS(10);
}

void IntelISH::snapshot() {
    // These status/doorbell registers are read without acknowledging messages.
    static const UInt32 offsets[] = {0x08, 0x0c, 0x34, 0x38, 0x48, 0x54, 0x368};
    static const char *names[] = {"InterruptMask", "InterruptStatus", "FirmwareStatus",
        "HostCommunication", "HostToISH", "ISHToHost", "DMAControl"};
    UInt32 values[7];
    const void *base = reinterpret_cast<const void *>(mapping->getVirtualAddress());
    for (unsigned i = 0; i < 7; i++) {
        values[i] = OSReadLittleInt32(base, offsets[i]);
        setProperty(names[i], values[i], 32);
    }
    setProperty("FirmwareState", (values[2] >> 12) & 0xf, 8);
    setProperty("SampleCount", ++samples, 32);
    IOLog("IntelISH: sample=%u PIMR=%08x PISR=%08x FWSTS=%08x state=%u HOSTCOMM=%08x H2I=%08x I2H=%08x RMP2=%08x\n",
        samples, values[0], values[1], values[2], (values[2] >> 12) & 0xf,
        values[3], values[4], values[5], values[6]);
}

UInt32 IntelISH::read(UInt32 offset) {
    return OSReadLittleInt32(reinterpret_cast<const void *>(mapping->getVirtualAddress()), offset);
}
void IntelISH::write(UInt32 offset, UInt32 value) {
    OSWriteLittleInt32(reinterpret_cast<void *>(mapping->getVirtualAddress()), offset, value);
    OSSynchronizeIO();
    (void)read(0x34); // Flush posted PCI writes.
}
void IntelISH::advance(Stage next, const char *name, unsigned timeout) {
    stage = next; elapsed = 0; deadline = timeout;
    setProperty("TransportState", name);
    ISH_TRACE("IntelISH: stage=%s FWSTS=%08x H2I=%08x I2H=%08x\n",
          name, read(0x34), read(0x48), read(0x54));
}
void IntelISH::fail(const char *reason) {
    accelReady = false; setProperty("AccelControlsVerified", false); removeProperty("AccelSample");
    IOLog("IntelISH: transport stopped: %s\n", reason);
    setProperty("TransportError", reason);
    advance(Failed, "failed"); snapshot();
    // Stop notifications/wake gate; do not perform a PCI or power-state reset.
    write(0x08, savedMask & ~1U);
    write(0x38, read(0x38) & ~0x80U);
    write(0x368, savedDMA);
    pci->setBusMasterEnable((originalCommand & 4) != 0);
    if (interrupt) interrupt->disable();
    snapshot();
}
bool IntelISH::queuePacket(unsigned protocol, unsigned command, const UInt8 *bytes, unsigned size) {
    if (size > 128 || queued == 8) { fail("TX bounds/queue overflow"); return false; }
    Packet &p = queue[(head + queued) % 8];
    bzero(p.bytes, sizeof(p.bytes));
    if (size) bcopy(bytes, p.bytes, size);
    p.doorbell = 0x80000000U | (protocol << 10) | (command << 16) | size;
    ++queued; return true;
}
void IntelISH::hbm(UInt8 command, UInt8 address) {
    UInt8 msg[8] = {0, 0, 4, 0x80, command, address, 0, 0};
    if (command == 1) { msg[5] = 0; msg[7] = 1; }
    queuePacket(1, 0, msg, sizeof(msg));
}
void IntelISH::nextClient() {
    while (client < 256 && !(clientMap[client / 8] & (1U << (client % 8)))) ++client;
    if (client == 256) {
        setProperty("FirmwareClientCount", clientCount, 32);
        setProperty("HIDClientAddress", hidAddress, 32);
        snapshot();
        if (!hidAddress || hidMaxMessage < 6 || hidMaxMessage > sizeof(assembly.bytes)) {
            fail("HID client missing/unsupported maximum message length"); return;
        }
        advance(ConnectWait, "HID-connect", 1500); clientControl(6); return;
    }
    advance(PropertiesWait, "client-properties");
    hbm(5, static_cast<UInt8>(client));
}
void IntelISH::receive(UInt32 bell, const UInt8 *bytes, unsigned size) {
    unsigned protocol = (bell >> 10) & 15, command = (bell >> 16) & 15;
    ISH_TRACE("IntelISH: RX doorbell=%08x length=%u\n", bell, size);
    if (protocol == 3) {
        if (command == 3 || command == 4) {
            if (size != 4) { fail("invalid reset response length"); return; }
            if (stage != ResetSend && stage != ResetWait) { fail("unexpected firmware reset"); return; }
            if (command == 4 && (bytes[0] != 1 || bytes[1] != 0)) {
                fail("reset response ID mismatch"); return;
            }
            if (command == 3) queuePacket(3, 4, bytes, 4);
            advance(ReadyWait, "firmware-ready", 200);
        }
        return;
    }
    if (protocol != 1) return;
    ISHProtocol::Header header {};
    if (!ISHProtocol::parse(bytes, size, header)) {
        dump("invalid-ISHTP", bytes, size); fail("invalid ISHTP header/length"); return;
    }
    ISH_TRACE("IntelISH: ISHTP fw=%u host=%u length=%u complete=%u\n",
          header.firmware, header.host, header.length, header.complete);
    const UInt8 *payload = bytes + 4;
    unsigned length = header.length;
    if (header.firmware && !header.host) {
        // Fixed clients are separate from HBM (Linux ishtp/bus.c).
        dump("fixed-client", bytes, size);
        if (header.firmware == 13 && header.complete && length == 12 &&
            ISHProtocol::little32(payload) == 1) {
            // SYSTEM_STATE_SUBSCRIBE: reply awake, as Linux ishtp_send_resume.
            UInt8 awake[16] = {2, 0, 0, 0};
            // We implement no sleep-state transitions yet; advertise no support.
            sendISHTP(13, 0, awake, sizeof(awake));
        }
        return;
    }
    if (header.firmware || header.host) {
        if (!connected || header.firmware != hidAddress || header.host != 1) {
            dump("unconnected-client", bytes, size); return;
        }
        if (!length || !assembly.append(payload, length, hidMaxMessage)) {
            fail("HID reassembly overflow/empty fragment"); return;
        }
        if (header.complete) {
            // One receive credit per complete message, not per IPC fragment.
            clientControl(8);
            receiveHID(assembly.bytes, assembly.used); assembly.used = 0;
        }
        return;
    }
    if (!header.complete || !length) {
        dump("invalid-HBM", bytes, size); fail("empty/fragmented HBM message"); return;
    }
    if (payload[0] == 8) {
        if (length != 8 || payload[1] != hidAddress || payload[2] != 1 || !connected) {
            dump("unexpected-flow-control", bytes, size); return;
        }
        if (txCredits >= 255) { fail("excessive TX flow credits"); return; }
        ++txCredits; ISH_TRACE("IntelISH: HID TX credit=%u\n", txCredits);
        sendHIDRequest(); return;
    }
    if (stage == ConnectWait && payload[0] == 0x86) {
        if (length != 4 || payload[1] != hidAddress || payload[2] != 1 || payload[3]) {
            dump("HID-connect-rejected", bytes, size); fail("HID connect rejected/malformed"); return;
        }
        connected = true; setProperty("HIDConnected", true);
        clientControl(8);
        requestHID(33, 0, HIDEnumWait, "HID-device-enumeration"); return;
    }
    if (stage == VersionWait && payload[0] == 0x81) {
        if (length != 4 || payload[1] != 1) { fail("HBM version rejected/malformed"); return; }
        IOLog("IntelISH: HBM 1.0 accepted (response version %u.%u)\n", payload[3], payload[2]);
        advance(EnumWait, "client-enumeration"); hbm(4);
    } else if (stage == EnumWait && payload[0] == 0x84) {
        if (length != 36) { fail("invalid enumeration bitmap"); return; }
        bcopy(payload + 4, clientMap, 32); client = 0; nextClient();
    } else if (stage == PropertiesWait && payload[0] == 0x85) {
        if (length != 32 || payload[1] != client || payload[2]) {
            fail("client properties rejected/malformed"); return;
        }
        const UInt8 *g = payload + 4;
        UInt32 maxLength = OSReadLittleInt32(payload, 24);
        IOLog("IntelISH: client=%u GUID=%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x version=%u max-connections=%u fixed=%u single=%u max-message=%u DMA-header=%u\n",
            client, OSReadLittleInt32(g, 0), OSReadLittleInt16(g, 4), OSReadLittleInt16(g, 6),
            g[8],g[9],g[10],g[11],g[12],g[13],g[14],g[15],
            payload[20],payload[21],payload[22],payload[23],maxLength,payload[28]);
        static const UInt8 hidGUID[16] = {0x58,0xcd,0xae,0x33,0x79,0xb6,0x54,0x4e,
            0x9b,0xd9,0xa0,0x4d,0x34,0xf0,0xc2,0x26};
        char property[32]; snprintf(property, sizeof(property), "FirmwareClient-%u", client);
        setProperty(property, const_cast<UInt8 *>(payload + 4), 28);
        if (!memcmp(g, hidGUID, 16)) {
            hidAddress = client; hidMaxMessage = maxLength; setProperty("HIDMaxMessage", maxLength, 32); IOLog("IntelISH: HID sensor client found at address=%u\n", client);
        }
        ++clientCount; ++client; nextClient();
    } else { dump("unexpected-HBM", bytes, size); fail("unexpected HBM response"); }
}
void IntelISH::dump(const char *label, const UInt8 *bytes, unsigned size) {
    // Bound unsolicited diagnostics; descriptor data is also retained in IORegistry.
    unsigned limit = size < 128 ? size : 128;
    for (unsigned offset = 0; offset < limit; offset += 16) {
        char hex[49] {}; unsigned end = limit - offset < 16 ? limit - offset : 16;
        for (unsigned i = 0; i < end; ++i) snprintf(hex + i * 3, 4, "%02x ", bytes[offset + i]);
        IOLog("IntelISH: %s offset=%u total=%u %s\n", label, offset, size, hex);
    }
}
void IntelISH::sendISHTP(UInt8 firmware, UInt8 host, const UInt8 *bytes, unsigned size) {
    unsigned fragments = (size + 123) / 124;
    if (!size || size > (host ? hidMaxMessage : 124) || fragments > 8 - queued) {
        fail("fragmented TX size/queue limit"); return;
    }
    for (unsigned offset = 0; offset < size;) {
        unsigned count = size - offset < 124 ? size - offset : 124;
        UInt8 packet[128] {};
        packet[0] = firmware; packet[1] = host;
        packet[2] = static_cast<UInt8>(count);
        packet[3] = offset + count == size ? 0x80 : 0;
        bcopy(bytes + offset, packet + 4, count);
        if (!queuePacket(1, 0, packet, count + 4)) return;
        offset += count;
    }
}
void IntelISH::clientControl(UInt8 command) {
    UInt8 msg[8] = {command, static_cast<UInt8>(hidAddress), 1, 0};
    sendISHTP(0, 0, msg, command == 8 ? 8 : 4);
}
void IntelISH::requestHID(UInt8 command, UInt8 device, Stage next, const char *name) {
    if (requestPending) { fail("overlapping HID requests"); return; }
    requestSize = 0;
    pendingCommand = command; pendingDevice = device; requestPending = true;
    advance(next, name, 1500); sendHIDRequest();
}
void IntelISH::sendHIDRequest() {
    if (!connected || !requestPending || !txCredits || stage == Failed) return;
    UInt8 msg[518] = {pendingCommand, pendingDevice, 0, 0, 0, 0};
    // Linux ISH leaves request header.size zero; payload still includes report ID.
    if (requestSize) bcopy(requestData, msg + 6, requestSize);
    --txCredits; requestPending = false;
    ISH_TRACE("IntelISH: HID request command=%u device=%u report=%u bytes=%u\n",
          pendingCommand, pendingDevice, requestSize ? requestData[0] : 0, requestSize);
    sendISHTP(static_cast<UInt8>(hidAddress), 1, msg, 6 + requestSize);
}
void IntelISH::receiveHID(const UInt8 *bytes, unsigned size) {
    // Linux host-interface replies can concatenate several messages.
    unsigned offset = 0;
    while (offset < size && stage != Failed) {
        if (size - offset < 6) { fail("truncated concatenated HID header"); return; }
        unsigned length = ISHProtocol::little16(bytes + offset + 4);
        if (length > size - offset - 6) { fail("truncated concatenated HID payload"); return; }
        receiveHIDMessage(bytes + offset, length + 6);
        offset += length + 6;
    }
}
void IntelISH::receiveHIDMessage(const UInt8 *bytes, unsigned size) {
    if (size < 6) { fail("short HID host-interface header"); return; }
    unsigned length = ISHProtocol::little16(bytes + 4);
    UInt8 command = bytes[0] & 0x7f;
    ISH_TRACE("IntelISH: HID response command=%u response=%u device=%u status=%u flags=%u length=%u assembled=%u\n",
          command, !!(bytes[0] & 0x80), bytes[1], bytes[2], bytes[3], length, size);
    if (length != size - 6) { dump("invalid-HID-length", bytes, size); fail("HID payload length mismatch"); return; }
    // Input publications may arrive asynchronously; discovery does not enable them.
    if (command == 5) {
        notePublish(bytes[1], bytes + 6, length);
        if (!bytes[2]) { lightInput(bytes[1], bytes + 6, length); accelInput(bytes[1], bytes + 6, length); }
        return;
    }
    if (command == 6) {
        // Linux report_list: total_size:u16, count:u8, flags:u8, then size:u16 + hostif messages.
        const UInt8 *list = bytes + 6;
        if (length < 4) {
            dump("invalid-input-list", bytes, size); return;
        }
        unsigned offset = 4;
        for (unsigned i = 0; i < list[2]; ++i) {
            if (length - offset < 8) return;
            unsigned itemSize = ISHProtocol::little16(list + offset);
            offset += 2;
            if (itemSize < 6 || itemSize > length - offset ||
                (ISHProtocol::little16(list + offset + 4) && ISHProtocol::little16(list + offset + 4) != itemSize - 6)) return;
            const UInt8 *item = list + offset;
            notePublish(item[1], item + 6, itemSize - 6);
            if ((item[0] & 0x7f) == 5 && !item[2]) { lightInput(item[1], item + 6, itemSize - 6); accelInput(item[1], item + 6, itemSize - 6); }
            offset += itemSize;
        }
        return;
    }
    // ENUM_DEVICES is addressed to the manager, not an individual sensor.
    // Linux ignores its response device_id; this firmware returns 0x0f.
    bool enumeration = stage == HIDEnumWait && command == 33;
    bool waiting = stage == HIDEnumWait || stage == HIDDescriptorWait || stage == ReportDescriptorWait ||
        (stage >= ALSFeatureGet && stage <= AccelInputWait) || stage == DebugWait;
    // Like Linux, ignore messages nobody asked for; the last eight stay in IORegistry.
    if (!waiting || !(bytes[0] & 0x80) || command != pendingCommand || (!enumeration && bytes[1] != pendingDevice)) {
        recordUnexpected(bytes, size); return;
    }
    if (stage == DebugWait) {
        setProperty("DebugResponse", const_cast<UInt8 *>(bytes), size);
        setProperty("DebugSequence", ++debugSequence, 32);
        resume(debugReturn); return;
    }
    // The status byte is not checked, as in Linux: Comet Lake firmware answers GET_FEATURE
    // with status 0xff and a valid report. Length and report ID checks catch bad answers.
    const UInt8 *payload = bytes + 6;
    if ((stage == AccelFeatureGet || stage == AccelFeatureVerify) && command == 2) {
        setProperty("AccelFeatureRaw", const_cast<UInt8 *>(payload), length < 512 ? length : 512);
        if (length != accel.featureBytes || payload[0] != accel.report) { stepFailed("accelerometer feature ID/length mismatch", bytes, size); return; }
        setProperty("AccelFeatureCurrent", const_cast<UInt8 *>(payload), length);
        unsigned power, reporting, interval;
        if (!ISHALS::extract(payload, length, accel.power, power) ||
            !ISHALS::extract(payload, length, accel.reporting, reporting) ||
            !ISHALS::extract(payload, length, accel.interval, interval)) { stepFailed("accelerometer controls unavailable", nullptr, 0); return; }
        setProperty("AccelReportIntervalRaw", interval, 32);
        if (stage == AccelFeatureGet) {
            setProperty("AccelFeatureOriginal", const_cast<UInt8 *>(payload), length);
            bcopy(payload, accelFeature, length);
            if (!ISHALS::insert(accelFeature, length, accel.power, accel.power.enabledValue) ||
                !ISHALS::insert(accelFeature, length, accel.reporting, accel.reporting.enabledValue)) { stepFailed("accelerometer controls out of range", nullptr, 0); return; }
            setProperty("AccelFeatureRequested", accelFeature, length);
            requestAccel(3, AccelFeatureSet, "accel-set-feature");
        } else {
            if (power != accel.power.enabledValue || reporting != accel.reporting.enabledValue) { stepFailed("accelerometer feature readback mismatch", nullptr, 0); return; }
            accelReady = true; setProperty("AccelControlsVerified", true);
            requestAccel(4, AccelInputWait, "accel-get-input");
        }
    } else if (stage == AccelFeatureSet && command == 3) {
        requestAccel(2, AccelFeatureVerify, "accel-feature-readback");
    } else if (stage == AccelInputWait && command == 4) {
        if (!accelInput(bytes[1], payload, length)) { stepFailed("accelerometer input did not decode", bytes, size); return; }
        inputFailures = 0; removeProperty("AccelInputError");
        advance(Streaming, "ALS-accelerometer-reporting"); timer->setTimeoutMS(100);
    } else if ((stage == ALSFeatureGet || stage == ALSFeatureVerify) && command == 2) {
        dump("ALS-feature", payload, length);
        if (length != als.featureBytes || payload[0] != als.report) {
            fail("ALS feature report ID/length mismatch"); return;
        }
        setProperty("ALSFeatureCurrent", const_cast<UInt8 *>(payload), length);
        unsigned power, reporting, interval;
        if (!ISHALS::extract(payload, length, als.power, power) ||
            !ISHALS::extract(payload, length, als.reporting, reporting) ||
            !ISHALS::extract(payload, length, als.interval, interval)) {
            fail("ALS feature controls unavailable"); return;
        }
        IOLog("IntelISH: ALS feature power=%u reporting=%u interval=%u interval-unit=%x exponent=%d\n",
              power, reporting, interval, als.interval.unit, als.interval.exponent);
        setProperty("ALSReportIntervalRaw", interval, 32);
        if (stage == ALSFeatureGet) {
            bcopy(payload, originalFeature, length); bcopy(payload, feature, length);
            setProperty("ALSFeatureOriginal", originalFeature, length);
            // Preserve interval/sensitivity and every other field. Only power/reporting change.
            if (!ISHALS::insert(feature, length, als.power, als.power.enabledValue) ||
                !ISHALS::insert(feature, length, als.reporting, als.reporting.enabledValue)) {
                fail("ALS control values out of range"); return;
            }
            setProperty("ALSFeatureRequested", feature, length);
            requestReport(3, ALSFeatureSet, "ALS-set-feature");
        } else {
            if (power != als.power.enabledValue || reporting != als.reporting.enabledValue) {
                fail("ALS feature readback did not confirm power/reporting"); return;
            }
            setProperty("ALSControlsVerified", true);
            requestReport(4, ALSInputWait, "ALS-get-input");
        }
    } else if (stage == ALSFeatureSet && command == 3) {
        requestReport(2, ALSFeatureVerify, "ALS-feature-readback");
    } else if (stage == ALSInputWait && command == 4) {
        if (!lightInput(bytes[1], payload, length)) { fail("ALS input did not decode"); return; }
        streamingStarted = true;
        if (accelFound && !accelSetup) { beginAccel(); return; }
        advance(Streaming, "ALS-accelerometer-reporting");
        timer->setTimeoutMS(accelReady ? 100 : 1000);
    } else if (stage == HIDEnumWait && command == 33) {
        if (!length || payload[0] > 32 || length != 1 + unsigned(payload[0]) * 9) {
            fail("invalid HID device enumeration"); return;
        }
        deviceCount = payload[0]; setProperty("HIDDeviceCount", deviceCount, 32);
        setProperty("HIDDeviceList", const_cast<UInt8 *>(payload), length);
        for (unsigned i = 0; i < deviceCount; ++i) {
            const UInt8 *info = payload + 1 + i * 9;
            unsigned id = ISHProtocol::little32(info);
            if (id > 255) { fail("HID device ID cannot fit host interface"); return; }
            for (unsigned j = 0; j < i; ++j) if (deviceIDs[j] == id) {
                fail("duplicate HID device ID"); return;
            }
            deviceIDs[i] = static_cast<UInt8>(id);
            IOLog("IntelISH: HID device index=%u id=%u class=%u PID=%04x VID=%04x\n",
                i, id, info[4], ISHProtocol::little16(info + 5), ISHProtocol::little16(info + 7));
        }
        if (!deviceCount) { advance(Complete, "no-HID-devices"); snapshot(); return; }
        deviceIndex = 0;
        requestHID(0, deviceIDs[0], HIDDescriptorWait, "HID-descriptor");
    } else if ((stage == HIDDescriptorWait && command == 0) ||
               (stage == ReportDescriptorWait && command == 1)) {
        if (!length) { fail("empty HID descriptor"); return; }
        char name[40]; snprintf(name, sizeof(name), "%s-%u",
            command == 0 ? "HIDDescriptor" : "ReportDescriptor", bytes[1]);
        if (!setProperty(name, const_cast<UInt8 *>(payload), length)) {
            fail("cannot retain HID descriptor"); return;
        }
        if (gIshTrace) dump(name, payload, length);
        // The light sensor is optional (boot-arg -ishals): Comet Lake firmware rejects the ALS
        // requests, and macOS already has the light sensor through SMCLightSensor.
        if (command == 1 && !alsFound && gIshALS) {
            ISHALS::Layout layout;
            if (ISHALS::parse(payload, length, layout)) {
                als = layout; alsDevice = bytes[1]; alsFound = true;
                IOLog("IntelISH: ALS layout device=%u report=%u feature-bytes=%u input-bytes=%u power=%u/%u reporting=%u/%u illum=%u/%u exponent=%d unit=%x\n",
                    alsDevice, als.report, als.featureBytes, als.inputBytes,
                    als.power.bit,als.power.width,als.reporting.bit,als.reporting.width,
                    als.illuminance.bit,als.illuminance.width,als.illuminance.exponent,als.illuminance.unit);
            }
        }
        if (command == 1 && !accelFound) {
            ISHAccel::Layout layout;
            if (ISHAccel::parse(payload, length, layout) && motion::valid(ISHAccel::motionLayout(layout))) {
                accel = layout; accelDevice = bytes[1]; accelFound = true;
                setProperty("AccelDeviceID", accelDevice, 8); setProperty("AccelReportID", accel.report, 8);
                setProperty("AccelInputBytes", accel.inputBytes, 32); setProperty("AccelFeatureBytes", accel.featureBytes, 32);
                for (unsigned i = 0; i < 3; ++i) {
                    char key[40], metadata[160];
                    snprintf(key, sizeof(key), "AccelAxis-%c", 'X' + i);
                    const auto &f = accel.axes[i];
                    snprintf(metadata, sizeof(metadata), "bit=%u width=%u min=%lld max=%lld unit=0x%x exponent=%d", f.bit, f.width, f.minimum, f.maximum, f.unit, f.exponent);
                    setProperty(key, metadata);
                    IOLog("IntelISH: accel layout device=%u report=%u %c %s\n", accelDevice, accel.report, 'X'+i, metadata);
                }
            }
        }
        if (command == 0) requestHID(1, deviceIDs[deviceIndex], ReportDescriptorWait, "HID-report-descriptor");
        else if (++deviceIndex < deviceCount)
            requestHID(0, deviceIDs[deviceIndex], HIDDescriptorWait, "HID-descriptor");
        else { snapshot(); beginALS(); }
    } else { recordUnexpected(bytes, size); }
}
void IntelISH::beginAccel() {
    accelSetup = true; streamingStarted = true;
    requestAccel(2, AccelFeatureGet, "accel-get-feature");
}
void IntelISH::requestAccel(UInt8 command, Stage next, const char *name) {
    if (requestPending) { fail("overlapping accelerometer request"); return; }
    pendingCommand = command; pendingDevice = accelDevice;
    requestSize = command == 3 ? accel.featureBytes : 1;
    if (command == 3) bcopy(accelFeature, requestData, requestSize);
    else requestData[0] = static_cast<UInt8>(accel.report);
    requestPending = true; advance(next, name, 300); sendHIDRequest();
}
void IntelISH::recordUnexpected(const UInt8 *bytes, unsigned size) {
    // Stage, the request being waited on, then the first 64 bytes of the message.
    UInt8 record[68] = {static_cast<UInt8>(stage), pendingCommand, pendingDevice, 0};
    unsigned n = size < 64 ? size : 64;
    bcopy(bytes, record + 4, n);
    char key[24]; snprintf(key, sizeof(key), "Unexpected-%u", unexpectedCount % 8);
    setProperty(key, record, n + 4);
    setProperty("UnexpectedCount", ++unexpectedCount, 32);
}
void IntelISH::notePublish(UInt8 device, const UInt8 *payload, unsigned length) {
    if (++publishCount > 16 && (publishCount % 64)) return;
    char key[24]; snprintf(key, sizeof(key), "LastPublish-%u", device);
    setProperty(key, const_cast<UInt8 *>(payload), length < 160 ? length : 160);
    setProperty("PublishCount", publishCount, 32);
}
void IntelISH::resume(Stage next) {
    advance(next, next == Streaming ? "ALS-accelerometer-reporting" : "listening");
}
// A request the firmware refused, answered wrongly or never answered. The accelerometer
// path degrades instead of stopping: skip the feature setup, then stop polling and only
// listen for published reports.
void IntelISH::stepFailed(const char *reason, const UInt8 *bytes, unsigned size) {
    if (bytes) recordUnexpected(bytes, size);
    requestPending = false;
    if (stage == AccelFeatureGet || stage == AccelFeatureSet || stage == AccelFeatureVerify) {
        setProperty("AccelFeatureError", reason);
        accelReady = true;   // decode whatever input arrives
        requestAccel(4, AccelInputWait, "accel-get-input");
    } else if (stage == AccelInputWait) {
        setProperty("AccelInputError", reason);
        if (!accelSamples || ++inputFailures >= 20) resume(Listening); else resume(Streaming);
    } else if (stage == DebugWait) {
        setProperty("DebugTimeouts", ++debugTimeouts, 32);
        resume(debugReturn);
    } else fail(reason);
}
// Diagnostics for porting to other laptops. Off unless the personality in Info.plist has
// DebugRequests = true: user space then sets the DebugRequest property to
// <command, device, payload...> and reads the answer from DebugResponse; <ff> restarts the transport.
IOReturn IntelISH::setProperties(OSObject *properties) {
    auto dict = OSDynamicCast(OSDictionary, properties);
    auto data = dict ? OSDynamicCast(OSData, dict->getObject("DebugRequest")) : nullptr;
    if (!debugEnabled || !data || !gate) return kIOReturnUnsupported;
    return gate->runAction(debugAction, data);
}
IOReturn IntelISH::debugAction(OSObject *owner, void *arg, void *, void *, void *) {
    auto *self = OSDynamicCast(IntelISH, owner);
    auto *data = static_cast<OSData *>(arg);
    if (!self || !data || !self->mapping || !self->timer) return kIOReturnNotReady;
    unsigned n = data->getLength();
    auto *b = static_cast<const UInt8 *>(data->getBytesNoCopy());
    if (!b || !n) return kIOReturnBadArgument;
    if (self->suspended) return kIOReturnNotReady;
    if (n == 1 && b[0] == 0xff) { self->restartTransport(); return kIOReturnSuccess; }
    if (n < 2 || n - 2 > sizeof(self->requestData) || n + 4 > self->hidMaxMessage) return kIOReturnBadArgument;
    if (!self->connected || self->requestPending || (self->stage != Listening && self->stage != Streaming))
        return kIOReturnBusy;
    self->debugReturn = self->stage;
    self->pendingCommand = b[0]; self->pendingDevice = b[1];
    self->requestSize = n - 2;
    if (self->requestSize) bcopy(b + 2, self->requestData, self->requestSize);
    self->requestPending = true;
    self->advance(DebugWait, "debug-request", 200);
    self->sendHIDRequest();
    self->timer->setTimeoutMS(10);
    return kIOReturnSuccess;
}
bool IntelISH::accelInput(UInt8 device, const UInt8 *bytes, unsigned size) {
    if (!accelReady || device != accelDevice || !size || bytes[0] != accel.report) return false;
    uint64_t ticks, ns; clock_get_uptime(&ticks); absolutetime_to_nanoseconds(ticks, &ns);
    motion::Sample sample;
    auto result = motion::decode(ISHAccel::motionLayout(accel), bytes, size, ns, sample);
    if (size != accel.inputBytes || result != motion::Result::OK) {
        setProperty("AccelError", "input size/ID/axis bounds mismatch"); return false;
    }
    auto dict = OSDictionary::withCapacity(7);
    if (!dict) { setProperty("AccelError", "sample allocation failed"); return false; }
    auto put = [&](const char *key, uint64_t value) {
        auto number = OSNumber::withNumber(value, 64);
        if (number) { dict->setObject(key, number); number->release(); }
    };
    put("RawX", static_cast<uint64_t>(sample.axes[0])); put("RawY", static_cast<uint64_t>(sample.axes[1]));
    put("RawZ", static_cast<uint64_t>(sample.axes[2])); put("TimestampNS", ns); put("Sequence", ++accelSamples);
    put("DeviceID", accelDevice); put("ReportID", accel.report);
    setProperty("AccelSample", dict); dict->release();
    setProperty("AccelInputReport", const_cast<UInt8 *>(bytes), size);
    setProperty("AccelSampleCount", accelSamples, 32); removeProperty("AccelError");
    if (accelSamples <= 8 || !(accelSamples % 100))
        IOLog("IntelISH: accel sample=%u x=%lld y=%lld z=%lld timestamp=%llu\n", accelSamples,
              static_cast<long long>(sample.axes[0]), static_cast<long long>(sample.axes[1]),
              static_cast<long long>(sample.axes[2]), ns);
    return true;
}
void IntelISH::beginALS() {
    if (!alsFound) {
        if (accelFound) { setProperty("ALSPresent", false); beginAccel(); return; }
        fail("no supported ALS or accelerometer descriptor found"); return;
    }
    setProperty("ALSDeviceID", alsDevice, 8); setProperty("ALSReportID", als.report, 8);
    setProperty("ALSUnitExponent", static_cast<UInt32>(als.illuminance.exponent), 32);
    requestReport(2, ALSFeatureGet, "ALS-get-feature");
}
void IntelISH::requestReport(UInt8 command, Stage next, const char *name) {
    if (requestPending) { fail("overlapping ALS requests"); return; }
    pendingCommand = command; pendingDevice = alsDevice;
    requestSize = command == 3 ? als.featureBytes : 1;
    if (command == 3) bcopy(feature, requestData, requestSize);
    else requestData[0] = static_cast<UInt8>(als.report);
    requestPending = true; advance(next, name, 1500); sendHIDRequest();
}
bool IntelISH::lightInput(UInt8 device, const UInt8 *bytes, unsigned size) {
    if (!alsFound || device != alsDevice || !size || bytes[0] != als.report) return false;
    unsigned long long milliLux;
    if (!ISHALS::milliLux(bytes, size, als, milliLux)) {
        dump("invalid-ALS-input", bytes, size); setProperty("ALSInputError", "report size/ID/scaling mismatch"); return false;
    }
    unsigned raw;
    ISHALS::extract(bytes, size, als.illuminance, raw);
    setProperty("ALSInputReport", const_cast<UInt8 *>(bytes), size);
    setProperty("ALSRawIlluminance", raw, 32);
    setProperty("ALSExceedsDeclaredMaximum", static_cast<long long>(raw) > als.illuminance.maximum);
    setProperty("ALSMilliLux", milliLux, 64);
    setProperty("ALSSampleCount", ++lightSamples, 32);
    removeProperty("ALSInputError");
    if (lightSamples <= 8 || !(lightSamples % 30))
        IOLog("IntelISH: ALS sample=%u raw=%u exponent=%d lux=%llu.%03llu\n",
              lightSamples, raw, als.illuminance.exponent, milliLux / 1000, milliLux % 1000);
    return true;
}
void IntelISH::pump() {
    if (suspended || stage == Failed) return;
    UInt32 status = read(0x0c);
    if (status) write(0x0c, status); // Linux: only busy-clear status is writable.
    UInt32 bell = read(0x54);
    if (bell & 0x80000000U) {
        unsigned size = bell & 0x3ff;
        UInt8 bytes[128] {};
        if (size <= sizeof(bytes)) {
            for (unsigned i = 0; i < (size + 3) / 4; ++i)
                OSWriteLittleInt32(bytes, i * 4, read(0x60 + i * 4));
        }
        // Capture the mailbox before clearing the busy doorbell.
        write(0x54, 0);
        if (size > sizeof(bytes)) fail("oversized IPC packet");
        else receive(bell, bytes, size);
    }
    if (suspended || stage == Failed) return;
    if (queued && !(read(0x48) & 0x80000000U)) {
        Packet &p = queue[head];
        unsigned size = p.doorbell & 0x3ff;
        for (unsigned i = 0; i < (size + 3) / 4; ++i)
            write(0xe0 + i * 4, OSReadLittleInt32(p.bytes, i * 4));
        ISH_TRACE("IntelISH: TX doorbell=%08x length=%u\n", p.doorbell, size);
        write(0x48, p.doorbell);
        head = (head + 1) % 8; --queued;
        if (stage == ResetSend) advance(ResetWait, "reset-ack", 1000);
    }
    if (stage == ReadyWait && !queued && !(read(0x48) & 0x80000000U) &&
        (read(0x34) & 3) == 3) {
        advance(VersionWait, "HBM-version"); hbm(1);
    }
}
void IntelISH::irq(OSObject *owner, IOInterruptEventSource *, int) {
    auto *self = OSDynamicCast(IntelISH, owner);
    if (self && self->mapping && self->transportStarted) self->pump();
}
void IntelISH::tick(OSObject *owner, IOTimerEventSource *source) {
    auto *self = OSDynamicCast(IntelISH, owner);
    if (!self || !self->mapping || self->suspended) return;
    if (self->stage == Complete || self->stage == Failed) return;
    if (self->stage == Streaming) {
        if (self->accelReady && (!self->alsFound || (++self->pollCycle % 10)))
            self->requestAccel(4, AccelInputWait, "accel-get-input");
        else self->requestReport(4, ALSInputWait, "ALS-get-input");
    }
    self->pump();
    if (self->stage == Complete || self->stage == Failed) return;
    if (self->stage == Streaming) { source->setTimeoutMS(self->accelReady ? 100 : 1000); return; }
    if (self->stage == Listening) { source->setTimeoutMS(20); return; }   // no interrupt: keep draining the mailbox
    if (++self->elapsed >= self->deadline || (!self->streamingStarted && ++self->totalTicks >= 6000)) {
        self->stepFailed("stage/overall timeout (10 ms timer ticks)", nullptr, 0);
        if (self->stage == Complete || self->stage == Failed) return;
        source->setTimeoutMS(self->stage == Streaming ? 100 : self->stage == Listening ? 20 : 10); return;
    }
    if (!self->streamingStarted && !(self->totalTicks % 100)) self->snapshot();
    source->setTimeoutMS(10);
}

void IntelISH::cleanup() {
    if (pmStarted) { PMstop(); pmStarted = false; }
    if (gate) {
        gate->disable();
        if (loop && gateAdded) loop->removeEventSource(gate);
        gate->release(); gate = nullptr;
    }
    gateAdded = false;
    if (interrupt) {
        interrupt->disable();
        if (loop && interruptAdded) loop->removeEventSource(interrupt);
        interrupt->release(); interrupt = nullptr;
    }
    interruptAdded = false;
    if (mapping && transportStarted) {
        write(0x08, savedMask); write(0x38, savedHost); write(0x368, savedDMA);
        pci->setBusMasterEnable((originalCommand & 4) != 0);
    }
    transportStarted = false;
    if (timer) {
        timer->cancelTimeout(); timer->disable();
        if (loop && timerAdded) loop->removeEventSource(timer);
        timer->release(); timer = nullptr;
    }
    timerAdded = false;
    if (loop) { loop->release(); loop = nullptr; }
    if (mapping) { mapping->release(); mapping = nullptr; }
    if (pci && commandSaved) pci->setMemoryEnable((originalCommand & 2) != 0);
    commandSaved = false;
}
void IntelISH::stop(IOService *provider) {
    cleanup(); IOService::stop(provider);
}

extern "C" kern_return_t IntelISH_start(kmod_info_t *, void *) { return KERN_SUCCESS; }
extern "C" kern_return_t IntelISH_stop(kmod_info_t *, void *) { return KERN_FAILURE; }
