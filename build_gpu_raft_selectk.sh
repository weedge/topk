ROOT_DIR=$(cd $(dirname $0); pwd)
cd $ROOT_DIR

#sh build_deps_rapidsai.sh

RAPIDSAI_DIR=$HOME/rapidsai
mkdir -p bin
nvcc ./src/main.cpp ./src/topk_raft_selectk.cu -o ./bin/query_doc_scoring \
    -I./src/ \
	-std=c++17 --expt-relaxed-constexpr --extended-lambda -arch=sm_70 \
	-L/usr/local/cuda/lib64 -lcudart -lcuda \
	-L$RAPIDSAI_DIR/lib -lraft -I$RAPIDSAI_DIR/include \
	-Xlinker="-rpath,$RAPIDSAI_DIR/lib" \
	-O3 \
	-DGPU -DFMT_HEADER_ONLY \
	-g

if [ $? -eq 0 ]; then
  echo "build success"
else
  echo "build fail"
fi
