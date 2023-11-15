ROOT_DIR=$(cd $(dirname $0); pwd)
cd $ROOT_DIR

RAPIDSAI_DIR=$HOME/rapidsai
#sh build_deps_rapidsai.sh
#unzip rapidsai.zip -d $RAPIDSAI_DIR

mkdir -p bin
nvcc ./src/main.cpp ./src/readfile.cu ./src/topk_doc_cudf_strings.cu -o ./bin/query_doc_scoring \
    -I./src/ \
	-std=c++17 --expt-relaxed-constexpr \
	-L/usr/local/cuda/lib64 -lcudart -lcuda \
	-L$RAPIDSAI_DIR/lib -lcudf -I$RAPIDSAI_DIR/include  \
	-O3 \
	-DFMT_HEADER_ONLY -DGPU -DPIO_TOPK \
	-g

if [ $? -eq 0 ]; then
	ldd ./bin/query_doc_scoring
	echo "build success"
else
	echo "build fail"
fi
