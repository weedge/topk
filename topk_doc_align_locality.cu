#include "helper.h"
#include "topk.h"

// https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#built-in-vector-types
typedef uint4 group_t;  // cuda uint4: 4 * uint (sizeof(uint4)=16 128bit)

// intersection(query,doc): query[i] == doc[j](0 <= i < query_size, 0 <= j < doc_size)
// score = total_intersection(query,doc) / max(query_size, doc_size)
void __global__ docQueryScoringCoalescedMemoryAccessSampleKernel(
    const __restrict__ uint16_t *docs,
    const int *doc_lens, const size_t n_docs,
    uint16_t *query, const int query_len, float *scores) {
#ifdef DEBUG
    printf("tid:%d GPU from block(%d, %d, %d), thread(%d, %d, %d)\n ",
           tid,
           blockIdx.x,
           blockIdx.y, blockIdx.z,
           threadIdx.x, threadIdx.y, threadIdx.z);
#endif
    // each thread process one doc-query pair scoring task
    register auto tid = blockIdx.x * blockDim.x + threadIdx.x, tnum = gridDim.x * blockDim.x;
    if (tid >= n_docs) {
        return;
    }

    __shared__ uint16_t query_on_shm[MAX_QUERY_SIZE];
#pragma unroll
    for (auto i = threadIdx.x; i < query_len; i += blockDim.x) {
        query_on_shm[i] = query[i];  // not very efficient query loading temporally, as assuming its not hotspot
    }

    __syncthreads();

    for (auto doc_id = tid; doc_id < n_docs; doc_id += tnum) {
        register int query_idx = 0;
        register float tmp_score = 0.;
        register bool no_more_load = false;

        for (auto i = 0; i < MAX_DOC_SIZE / (sizeof(group_t) / sizeof(uint16_t)); i++) {
            if (no_more_load) {
                break;
            }
            register group_t loaded = ((group_t *)docs)[i * n_docs + doc_id];  // tid
            register uint16_t *doc_segment = (uint16_t *)(&loaded);
            for (auto j = 0; j < sizeof(group_t) / sizeof(uint16_t); j++) {
                if (doc_segment[j] == 0) {
                    no_more_load = true;
                    break;
                    // return;
                }
                while (query_idx < query_len && query_on_shm[query_idx] < doc_segment[j]) {
                    ++query_idx;
                }
                if (query_idx < query_len) {
                    tmp_score += (query_on_shm[query_idx] == doc_segment[j]);
                }
            }
            __syncwarp();
        }
        scores[doc_id] = tmp_score / max(query_len, doc_lens[doc_id]);  // tid
    }
}

// todo: remove 2nd loop
__global__ void docsAlignKernel(const __restrict__ uint16_t *d_in_docs,
                                const int *d_in_doc_lens,
                                const size_t n_docs, uint16_t *d_out_docs) {
    register auto tid = blockIdx.x * blockDim.x + threadIdx.x, tnum = gridDim.x * blockDim.x;
    if (tid >= n_docs) {
        return;
    }

    for (auto doc_id = tid; doc_id < n_docs; doc_id += tnum) {
        for (int j = 0; j < d_in_doc_lens[doc_id]; j++) {
            auto group_sz = sizeof(group_t) / sizeof(uint16_t);
            auto layer_0_offset = j / group_sz;
            auto layer_0_stride = n_docs * group_sz;
            auto layer_1_offset = doc_id;
            auto layer_1_stride = group_sz;
            auto layer_2_offset = j % group_sz;
            auto final_offset = layer_0_offset * layer_0_stride + layer_1_offset * layer_1_stride + layer_2_offset;
            d_out_docs[final_offset] = *(d_in_docs + doc_id * MAX_DOC_SIZE + j);
        }
    }
}

void doc_query_scoring_gpu(std::vector<std::vector<uint16_t>> &querys,
                           int start_doc_id,
                           std::vector<std::vector<uint16_t>> &docs,
                           std::vector<uint16_t> &lens,
                           std::vector<std::vector<int>> &indices,  // shape [querys.size(), TOPK]
                           std::vector<std::vector<float>> &scores  // shape [querys.size(), TOPK]
) {
    // use one gpu device
    cudaDeviceProp device_props;
    cudaGetDeviceProperties(&device_props, 0);
    cudaSetDevice(0);

#ifdef MAP_HOST_MEMORY
    // check deviceOverlap
    if (device_props.canMapHostMemory != 1) {
        printf("device don't support MapHostMemory,so can't zero copy\n");
    } else {
        printf("device support MapHostMemory,so can zero-copy\n");
        cudaSetDeviceFlags(cudaDeviceMapHost);
    }
#endif

    auto n_docs = docs.size();
    std::vector<float> s_scores(n_docs);
    std::vector<int> s_indices(n_docs);

    // launch kernel grid block size, just use 1D x
    int block = N_THREADS_IN_ONE_BLOCK;
    int grid = (n_docs + block - 1) / block;

    float *d_scores = nullptr;
    uint16_t *d_docs = nullptr, *d_in_docs = nullptr, *d_query = nullptr;
    int *d_doc_lens = nullptr;
    // int *d_doc_offsets = nullptr;

    // init device global memory
    std::chrono::high_resolution_clock::time_point dat = std::chrono::high_resolution_clock::now();
    cudaMalloc(&d_docs, sizeof(uint16_t) * MAX_DOC_SIZE * n_docs);
    cudaMalloc(&d_in_docs, sizeof(uint16_t) * MAX_DOC_SIZE * n_docs);
    cudaMalloc(&d_scores, sizeof(float) * n_docs);
    cudaMalloc(&d_doc_lens, sizeof(int) * n_docs);
    // cudaMalloc(&d_doc_offsets, sizeof(int) * n_docs);
    std::chrono::high_resolution_clock::time_point dat1 = std::chrono::high_resolution_clock::now();
    std::cout << "cudaMalloc docs cost " << std::chrono::duration_cast<std::chrono::milliseconds>(dat1 - dat).count() << " ms " << std::endl;

    // pre align docs -> h_docs [n_docs,MAX_DOC_SIZE], h_doc_lens_vec[n_docs] global memmory segment -> register
    std::chrono::high_resolution_clock::time_point dgt = std::chrono::high_resolution_clock::now();
    {
        std::chrono::high_resolution_clock::time_point pt = std::chrono::high_resolution_clock::now();
        cudaStream_t stream;
        cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking);

        uint16_t *h_docs = nullptr;
        int *h_doc_lens_vec = nullptr;
        // int *h_doc_offsets_vec = nullptr;
#ifdef PINNED_MEMORY
        // https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__MEMORY.html#group__CUDART__MEMORY_1gb65da58f444e7230d3322b6126bb4902
        cudaMallocHost(&h_docs, sizeof(uint16_t) * MAX_DOC_SIZE * n_docs);  // cudaHostAllocDefault
        // cudaHostAlloc(&h_docs, sizeof(uint16_t) * MAX_DOC_SIZE * n_docs, cudaHostAllocDefault);
        cudaHostAlloc(&h_doc_lens_vec, sizeof(int) * n_docs, cudaHostAllocDefault);
        // cudaHostAlloc(&h_doc_offsets_vec, sizeof(int) * n_docs, cudaHostAllocDefault);
#else
        h_docs = new uint16_t[MAX_DOC_SIZE * n_docs];
        h_doc_lens_vec = new int[n_docs];
        // h_doc_offsets_vec = new int[n_docs];
#endif
        // size_t offset = 0;
#pragma omp parallel for schedule(static)
        for (int i = 0; i < docs.size(); i++) {
            h_doc_lens_vec[i] = docs[i].size();
            // h_doc_offsets_vec[i] = MAX_DOC_SIZE * i;
            memcpy(h_docs + MAX_DOC_SIZE * i, docs[i].data(), sizeof(uint16_t) * h_doc_lens_vec[i]);
        }
        std::chrono::high_resolution_clock::time_point pt1 = std::chrono::high_resolution_clock::now();
        std::cout << "int offset cost " << std::chrono::duration_cast<std::chrono::milliseconds>(pt1 - pt).count() << " ms " << std::endl;

        std::chrono::high_resolution_clock::time_point dlt = std::chrono::high_resolution_clock::now();
        cudaMemcpyAsync(d_in_docs, h_docs, sizeof(uint16_t) * MAX_DOC_SIZE * n_docs, cudaMemcpyHostToDevice, stream);
        cudaMemcpyAsync(d_doc_lens, h_doc_lens_vec, sizeof(int) * n_docs, cudaMemcpyHostToDevice, stream);
        // cudaMemcpyAsync(d_doc_offsets, h_doc_offsets_vec, sizeof(int) * n_docs, cudaMemcpyHostToDevice, stream);
        std::chrono::high_resolution_clock::time_point dlt1 = std::chrono::high_resolution_clock::now();
        std::cout << "cudaMemcpy H2D doc_lens cost " << std::chrono::duration_cast<std::chrono::milliseconds>(dlt1 - dlt).count() << " ms " << std::endl;

        std::chrono::high_resolution_clock::time_point tt = std::chrono::high_resolution_clock::now();
        // cudaLaunchKernel
        docsAlignKernel<<<grid, block, 0, stream>>>(d_in_docs, d_doc_lens, n_docs, d_docs);
        // cudaStreamSynchronize(stream);

#ifdef PINNED_MEMORY
        cudaFreeHost(h_docs);
        cudaFreeHost(h_doc_lens_vec);
        // cudaFreeHost(h_doc_offsets_vec);
#else
        delete[] h_docs;
        delete[] h_doc_lens_vec;
        // delete[] h_doc_offsets_vec;
#endif
        cudaStreamDestroy(stream);

        std::chrono::high_resolution_clock::time_point tt1 = std::chrono::high_resolution_clock::now();
        std::cout << "docsAlignKernel cost " << std::chrono::duration_cast<std::chrono::milliseconds>(tt1 - tt).count() << " ms " << std::endl;
    }
    cudaFree(d_in_docs);
    // cudaFree(d_doc_offsets);
    std::chrono::high_resolution_clock::time_point dgt1 = std::chrono::high_resolution_clock::now();
    std::cout << "align group docs cost " << std::chrono::duration_cast<std::chrono::milliseconds>(dgt1 - dgt).count() << " ms " << std::endl;

    std::chrono::high_resolution_clock::time_point it = std::chrono::high_resolution_clock::now();
    // std::iota(s_indices.begin(), s_indices.end(), start_doc_id);
#pragma omp parallel for schedule(static)
    for (int j = 0; j < n_docs; ++j) {
        s_indices[j] = j + start_doc_id;
    }
    std::chrono::high_resolution_clock::time_point it1 = std::chrono::high_resolution_clock::now();
    std::cout << "iota indeices cost " << std::chrono::duration_cast<std::chrono::milliseconds>(it1 - it).count() << " ms " << std::endl;

    for (auto &query : querys) {
        const size_t query_len = query.size();
        cudaMalloc(&d_query, sizeof(uint16_t) * query_len);
        std::chrono::high_resolution_clock::time_point qt = std::chrono::high_resolution_clock::now();
        cudaMemcpy(d_query, query.data(), sizeof(uint16_t) * query_len, cudaMemcpyHostToDevice);
        std::chrono::high_resolution_clock::time_point qt1 = std::chrono::high_resolution_clock::now();
        std::cout << "cudaMemcpy H2D query cost " << std::chrono::duration_cast<std::chrono::milliseconds>(qt1 - qt).count() << " ms " << std::endl;

        show_mem_usage();

        std::chrono::high_resolution_clock::time_point tt = std::chrono::high_resolution_clock::now();
        // cudaLaunchKernel
        docQueryScoringCoalescedMemoryAccessSampleKernel<<<grid, block>>>(d_docs,
                                                                          d_doc_lens, n_docs, d_query, query_len, d_scores);
        cudaDeviceSynchronize();
        cudaMemcpy(s_scores.data(), d_scores, sizeof(float) * n_docs, cudaMemcpyDeviceToHost);
        std::chrono::high_resolution_clock::time_point tt1 = std::chrono::high_resolution_clock::now();
        std::cout << "docQueryScoringCoalescedMemoryAccessSampleKernel cost " << std::chrono::duration_cast<std::chrono::milliseconds>(tt1 - tt).count() << " ms " << std::endl;
        std::chrono::high_resolution_clock::time_point t = std::chrono::high_resolution_clock::now();
        int topk = n_docs > TOPK ? TOPK : n_docs;
        // sort scores with Heap-based sort
        // todo: Bitonic sort by gpu
        std::partial_sort(s_indices.begin(), s_indices.begin() + topk, s_indices.end(),
                          [&s_scores, start_doc_id](const int &a, const int &b) {
                              if (s_scores[a - start_doc_id] != s_scores[b - start_doc_id]) {
                                  return s_scores[a - start_doc_id] > s_scores[b - start_doc_id];  // by score DESC
                              }
                              return a < b;  // the same score, by index ASC
                          });
        std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
        std::cout << "heap partial_sort cost " << std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t).count() << " ms " << std::endl;

        std::vector<int> topk_doc_ids(s_indices.begin(), s_indices.begin() + topk);
        indices.emplace_back(topk_doc_ids);

        std::vector<float> topk_scores(topk_doc_ids.size());
        int i = 0;
        for (auto doc_id : topk_doc_ids) {
            topk_scores[i++] = s_scores[doc_id - start_doc_id];
        }
        scores.emplace_back(topk_scores);

        cudaFree(d_query);
    }

    cudaFree(d_docs);
    cudaFree(d_scores);
    cudaFree(d_doc_lens);
}
