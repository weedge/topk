#!/bin/sh
set -e

ROOT_DIR=$(cd $(dirname $0); pwd)
cd $ROOT_DIR

mkdir -p third_party 
cd third_party

# faiss block select topk source code
wget https://github.com/facebookresearch/faiss/archive/refs/tags/v1.7.4.zip -O faiss-1.7.4.zip
unzip faiss-1.7.4.zip
mv faiss-1.7.4/faiss ./
rm -r faiss-1.7.4
rm faiss-1.7.4.zip

# bucket-based select topk source code
# fork from https://github.com/upsj/gpu_selection.git 
# change uint32 -> int
git clone https://github.com/weedge/gpu_selection.git

# Dr.topk source code
# fork from https://github.com/Anil-Gaihre/DrTopKSC.git
# change radix/bitonic select
git clone https://github.com/weedge/DrTopKSC.git
