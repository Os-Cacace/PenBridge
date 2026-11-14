#include <mach/mach_types.h>
extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);
extern kern_return_t IntelISH_start(kmod_info_t *ki, void *data);
extern kern_return_t IntelISH_stop(kmod_info_t *ki, void *data);
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(org.yjmd2222.IntelISH, "0.7.0-cml5", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = IntelISH_start;
__private_extern__ kmod_stop_func_t *_antimain = IntelISH_stop;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
