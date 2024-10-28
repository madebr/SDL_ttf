#!/usr/bin/env bash

set -ex

# NOTE: fxc is tested on Linux with https://github.com/mozilla/fxc2

FXC_DEFAULT=$(which fxc 2>/dev/null || echo "")
DXC_DEFAULT=$(which dxc 2>/dev/null || echo "")
SPIRV_CROSS_DEFAULT=$(which spirv-cross 2>/dev/null || echo "")

FXC=${FXC:-${FXC_DEFAULT}}
DXC=${DXC:-${DXC_DEFAULT}}
SPIRV_CROSS=${SPIRV_CROSS:-${SPIRV_CROSS_DEFAULT}}

echo "FXC=${FXC}"
echo "DXC=${DXC}"
echo "SPIRV_CROSS=${SPRIV_CROSS}"

[ "$FXC" != "" ] || echo "FXC not set and fxc not in PATH; D3D11 shaders will not be rebuilt"
[ "$DXC" != "" ] || echo "DXC not set and dxc not in PATH; D3D12 shaders will not be rebuilt"
[ "$SPIRV_CROSS" != "" ] || echo "SPIRV_CROSS not set and spirv-cross not in PATH; D3D11, D3D12, Metal shaders will not be rebuilt"

spirv_bundle="spir-v.h"
dxbc50_bundle="dxbc50.h"
dxil60_bundle="dxil60.h"
metal_bundle="metal.h"

rm -f "$spirv_bundle"
[ "$SPIRV_CROSS" != "" ] && rm -f "$metal_bundle"
[ "$SPIRV_CROSS" != "" ] && [ "$FXC" != "" ] && rm -f "$dxbc50_bundle"
[ "$SPIRV_CROSS" != "" ] && [ "$DXC" != "" ] && rm -f "$dxil60_bundle"

make-header() {
    xxd -i "$1" | sed \
        -e 's/^unsigned /const unsigned /g' \
        -e 's,^const,static const,' \
        > "$1.h"
}

compile-hlsl-dxbc() {
    local src="$1"
    local profile="$2"
    local output_basename="$3"
    local var_name="$(echo "$output_basename" | sed -e 's/\./_/g')"

    $FXC "$src" -Vnmain -E main -T "$2" "-Fh$output_basename.tmp.h" || exit $?
    sed \
        -e "s/g_main/$var_name/;s/\r//g" \
        -e 's,^const,static const,' \
        -e 's,const unsigned,const signed,' \
        < "$output_basename.tmp.h" \
        > "$output_basename.h"
    rm -f "$output_basename.tmp.h"
}

compile-hlsl-dxil() {
    local src="$1"
    local profile="$2"
    local output_basename="$3"
    local var_name="$(echo "$output_basename" | sed -e 's/\./_/g')"

    $DXC "$src" -E main -T $2 -Fh "$output_basename.tmp.h" -O3 || exit $?
    sed \
        -e "s/g_main/$var_name/;s/\r//g" \
        -e 's,^const,static const,' \
        < "$output_basename.tmp.h" \
        > "$output_basename.h"
    rm -f "$output_basename.tmp.h"
}

for i in *.vert *.frag; do
    spv="$i.spv"
    metal="$i.metal"
    hlsl50="$i.sm50.hlsl"
    dxbc50="$i.sm50.dxbc"
    hlsl60="$i.sm60.hlsl"
    dxil60="$i.sm60.dxil"

    glslangValidator -g0 -Os "$i" -V -o "$spv" --quiet

    make-header "$spv"
    echo "#include \"$spv.h\"" >> "$spirv_bundle"

    if [ "$SPIRV_CROSS" = "" ]; then
        continue
    fi

    $SPIRV_CROSS "$spv" --hlsl --shader-model 50 --hlsl-enable-compat --output "$hlsl50"
    $SPIRV_CROSS "$spv" --hlsl --shader-model 60 --hlsl-enable-compat --output "$hlsl60"

    if [ "${i##*.}" == "frag" ]; then
        hlsl_stage="ps"
    else
        hlsl_stage="vs"
    fi

    if [ "$FXC" != "" ]; then
        compile-hlsl-dxbc "$hlsl50" ${hlsl_stage}_5_0 "$dxbc50"
        echo "#include \"$dxbc50.h\"" >> "$dxbc50_bundle"
    fi

    if [ "$DXC" != "" ]; then
        compile-hlsl-dxil "$hlsl60" ${hlsl_stage}_6_0 "$dxil60"
        echo "#include \"$dxil60.h\"" >> "$dxil60_bundle"
    fi

    $SPIRV_CROSS "$spv" --msl --output "$metal"
    make-header "$metal"
    echo "#include \"$metal.h\"" >> "$metal_bundle"
done
