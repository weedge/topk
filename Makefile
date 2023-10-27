DOC_CN?=10
QUERY_CN?=10

init:
	mkdir -p bin

gen:
	@bash gen.sh $(DOC_CN)
	@bash gen_querys.sh $(QUERY_CN)

build_cpu: init
	g++ ./main.cpp -o ./bin/query_doc_scoring_cpu  -I./ -std=c++11 -pthread -O3 -g 

build_cpu_concurency: init
	g++ ./main.cpp -o ./bin/query_doc_scoring_cpu_concurency  -I./ -std=c++11 -pthread -O3 -g -DCPU_CONCURENCY

build_cpu_gpu: init
	nvcc ./main.cpp ./topk.cu -o ./bin/query_doc_scoring_cpu_gpu  \
		-I./ -L/usr/local/cuda/lib64 -lcudart -lcuda \
		-O3 -g

build_cpu_concurency_gpu: init
	nvcc ./main.cpp ./topk.cu -o ./bin/query_doc_scoring_cpu_concurency_gpu  \
		-I./ -L/usr/local/cuda/lib64 -lcudart -lcuda \
		-O3 -g \
		-DCPU_CONCURENCY

build_examples: init
	g++ -g -O3 -o bin/example_threadpool example_threadpool.cpp -std=c++11 -pthread

clean:
	rm -rf bin/*

clean_testdata:
	rm -rf testdata/*