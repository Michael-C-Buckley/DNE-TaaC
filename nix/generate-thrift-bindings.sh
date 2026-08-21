#!/usr/bin/env bash
set -euo pipefail

THRIFT1=${1:?missing thrift1 path}
FBTHRIFT_SOURCE=${2:?missing FBThrift source path}
FBOSS_SOURCE=${3:?missing FBOSS source path}
TAAC_SOURCE=${4:?missing TAAC source path}
OUTPUT=${5:?missing output path}

STAGING="$OUTPUT/staging"
GENERATED="$OUTPUT/generated"

mkdir -p \
  "$STAGING/configerator/structs/neteng/taac" \
  "$STAGING/configerator/structs/neteng/ixia" \
  "$STAGING/neteng/test_infra/dne/utils/if" \
  "$GENERATED"

ln -s "$TAAC_SOURCE/taac/thrift/taac/health_check.thrift" \
  "$STAGING/configerator/structs/neteng/taac/health_check.thrift"
ln -s "$TAAC_SOURCE/taac/thrift/taac/test_as_a_config.thrift" \
  "$STAGING/configerator/structs/neteng/taac/test_as_a_config.thrift"
ln -s "$TAAC_SOURCE/taac/thrift/ixia/ixia.thrift" \
  "$STAGING/configerator/structs/neteng/ixia/ixia.thrift"
ln -s "$TAAC_SOURCE/taac/thrift/neteng/test_infra/dne/utils/if/qos_config.thrift" \
  "$STAGING/neteng/test_infra/dne/utils/if/qos_config.thrift"

# thrift/CMakeLists.txt is the canonical binding manifest.  Extracting its
# source arguments here prevents the Nix and CMake build paths from acquiring
# subtly different schema sets.
manifest="$OUTPUT/binding-manifest"
sed -n \
  -e 's@.*"${FBOSS_THRIFT_DIR}/\([^"]*\)".*@FBOSS \1@p' \
  -e 's@.*"${UPSTREAM_THRIFT_DIR}/\([^"]*\)".*@TAAC \1@p' \
  "$TAAC_SOURCE/thrift/CMakeLists.txt" > "$manifest"

while read -r origin relative_path; do
  case "$origin" in
    FBOSS) schema="$FBOSS_SOURCE/$relative_path" ;;
    TAAC) schema="$TAAC_SOURCE/taac/thrift/$relative_path" ;;
    *) echo "unknown schema origin: $origin" >&2; exit 1 ;;
  esac

  "$THRIFT1" \
    --gen mstch_python:json \
    -I "$STAGING" \
    -I "$FBOSS_SOURCE" \
    -I "$FBTHRIFT_SOURCE" \
    -o "$GENERATED" \
    "$schema"
done < "$manifest"

mv "$GENERATED/gen-python" "$OUTPUT/gen-python"

# The source tree uses both current thrift_types/thrift_clients module names
# and their legacy types/ttypes/clients aliases.
while IFS= read -r -d '' generated_file; do
  generated_dir=$(dirname "$generated_file")
  printf '%s\n' 'from .thrift_types import *' > "$generated_dir/types.py"
  printf '%s\n' 'from .thrift_types import *' > "$generated_dir/ttypes.py"
done < <(find "$OUTPUT/gen-python" -name thrift_types.py -print0)

while IFS= read -r -d '' generated_file; do
  generated_dir=$(dirname "$generated_file")
  printf '%s\n' 'from .thrift_clients import *' > "$generated_dir/clients.py"
done < <(find "$OUTPUT/gen-python" -name thrift_clients.py -print0)

# canonical_rib_py3 is an internal helper module rather than a Thrift schema,
# so it is not present in the FBOSS source slice.  TAAC only relies on its two
# thin async wrappers around methods that are part of the generated OSS client.
canonical_rib_dir="$OUTPUT/gen-python/neteng/fboss/bgp/client"
mkdir -p "$canonical_rib_dir"
touch "$OUTPUT/gen-python/neteng/fboss/bgp/__init__.py"
touch "$canonical_rib_dir/__init__.py"
printf '%s\n' \
  'async def get_rib_entries(client, afi):' \
  '    return await client.getRibEntries(afi)' \
  '' \
  '' \
  'async def get_rib_subprefixes(client, prefix):' \
  '    return await client.getRibSubprefixes(prefix)' \
  > "$canonical_rib_dir/canonical_rib_py3.py"

# TAAC also supports the newer split summary/detail update-group API.  The
# pinned FBOSS schema exposes the same data through getUpdateGroupInfo with an
# optional group_id, so preserve the newer names as a compatibility surface.
bgp_types="$OUTPUT/gen-python/neteng/fboss/bgp_thrift/types.py"
printf '%s\n' \
  '' \
  'try:' \
  '    TGetUpdateGroupSummariesResponse' \
  'except NameError:' \
  '    TGetUpdateGroupSummariesResponse = TGetUpdateGroupInfoResponse' \
  >> "$bgp_types"

bgp_clients="$OUTPUT/gen-python/neteng/fboss/bgp_thrift/clients.py"
printf '%s\n' \
  '' \
  'from .thrift_types import TGetUpdateGroupInfoRequest' \
  '' \
  'if not hasattr(TBgpService.Async, "getUpdateGroupSummaries"):' \
  '    async def _get_update_group_summaries(self, *, rpc_options=None):' \
  '        request = TGetUpdateGroupInfoRequest()' \
  '        return await self.getUpdateGroupInfo(request, rpc_options=rpc_options)' \
  '    TBgpService.Async.getUpdateGroupSummaries = _get_update_group_summaries' \
  >> "$bgp_clients"
