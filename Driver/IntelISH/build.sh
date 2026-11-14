#!/bin/zsh
# Builds IntelISH.kext into build/ next to this script. Needs the Xcode Command Line Tools
# and acidanthera's MacKernelSDK: set MACKERNELSDK to a copy, or let this script clone it.
#   zsh Driver/IntelISH/build.sh
set -e
R=${0:A:h}
SDK=${MACKERNELSDK:-$R/MacKernelSDK}
[[ -d $SDK/Headers ]] || git clone --depth 1 https://github.com/acidanthera/MacKernelSDK.git $SDK
O=$R/build/obj; K=$R/build/IntelISH.kext
rm -rf $R/build; mkdir -p $O $K/Contents/MacOS
CF=(-target x86_64-apple-macos10.15 -arch x86_64 -O2 -mkernel -fapple-kext -nostdinc -nostdlib -fno-builtin
    -fno-common -fno-stack-protector -fno-asynchronous-unwind-tables -fno-non-call-exceptions -msoft-float
    -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
    -I$SDK/Headers -Wno-unknown-warning-option -Wno-ossharedptr-misuse -Wno-vla -Wno-implicit-int-conversion)
clang++ $CF -std=c++17 -fno-rtti -fno-exceptions -c $R/src/IntelISH.cpp -o $O/IntelISH.o
clang   ${CF:#-fapple-kext} -std=c11 -c $R/src/kmod_info.c -o $O/kmod_info.o
RT=$(ls -d /Library/Developer/CommandLineTools/usr/lib/clang/*/lib/darwin $(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/*/lib/darwin 2>/dev/null | head -1)
clang++ -target x86_64-apple-macos10.15 -arch x86_64 -nostdlib -Xlinker -kext -Xlinker -static \
    -L$SDK/Library/x86_64 -lkmod $RT/libclang_rt.cc_kext.a \
    $O/kmod_info.o $O/IntelISH.o -o $K/Contents/MacOS/IntelISH
# A kext without kmod_info is silently skipped at boot, so refuse to produce one.
nm -m $K/Contents/MacOS/IntelISH | grep -q "external _kmod_info" || { print -u2 "kmod_info missing from the binary"; exit 1 }
cp $R/src/Info.plist $K/Contents/Info.plist
plutil -lint $K/Contents/Info.plist >/dev/null
rm -rf $O
echo "built $K ($(md5 -q $K/Contents/MacOS/IntelISH))"
