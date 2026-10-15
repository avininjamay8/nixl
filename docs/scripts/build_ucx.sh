#!/bin/bash
#SBATCH -J build-ucx
#SBATCH -N1
#SBATCH --gres=gpu:1
#SBATCH --time=01:30:00
# Build UCX v1.22.0 with the two ionic patches and install it into a NIXL
# prefix. NIXL and nixlbench are copied from an existing NIXL install; they
# load libucp from the new prefix at runtime. Submit from this dir:
#   sbatch --export=ALL,NIXL_SRC=<nixl install>,OUT=<new prefix> build_ucx.sh
set -euo pipefail
: "${NIXL_SRC:?existing NIXL prefix with bin/nixlbench}" "${OUT:?output prefix}"
IMAGE=${IMAGE:-vllm/vllm-openai-rocm:nightly}
UCX_REF=${UCX_REF:-v1.22.0}
DIR=${SLURM_SUBMIT_DIR:-$PWD}
WORK=/tmp/$USER/ucx-build-${SLURM_JOB_ID:-local}
mkdir -p "$WORK/prefix" "$OUT"

docker run --rm --network host \
  -v "$WORK:/work" -v "$NIXL_SRC:/nixl:ro" -v "$DIR:/scripts:ro" \
  -e UCX_REF="$UCX_REF" \
  --entrypoint bash "$IMAGE" -lc '
set -euo pipefail
apt-get update -qq
apt-get install -y -qq build-essential git autoconf automake libtool pkg-config \
  libnuma-dev libibverbs-dev librdmacm-dev >/dev/null
git clone -q --depth 1 --branch "$UCX_REF" https://github.com/openucx/ucx.git /work/ucx
cd /work/ucx
python3 /scripts/ucx_ionic_nosrq.patch.py
python3 /scripts/ucx_rocm_get_via_put.patch.py
./autogen.sh >/dev/null
mkdir build && cd build
../configure -q --prefix=/work/prefix --with-rocm=/opt/rocm --without-cuda --enable-mt
make -j"$(nproc)" >/dev/null
make install >/dev/null
mkdir -p /work/prefix/bin /work/prefix/lib/x86_64-linux-gnu
cp -a /nixl/bin/nixlbench /work/prefix/bin/
cp -a /nixl/lib/x86_64-linux-gnu/. /work/prefix/lib/x86_64-linux-gnu/
for f in /nixl/lib/lib*; do
  [[ $(basename "$f") == libuc[pmst]* ]] || [[ -e /work/prefix/lib/$(basename "$f") ]] || cp -a "$f" /work/prefix/lib/
done
LD_LIBRARY_PATH=/work/prefix/lib /work/prefix/bin/ucx_info -v | head -2
'
rsync -a --delete "$WORK/prefix/" "$OUT/"
echo "installed $OUT"
