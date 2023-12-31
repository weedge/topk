#include "helper.h"
#include "topk.h"

// intersection(query,doc): query[i] == doc[j](0 <= i < query_size, 0 <= j < doc_size)
// score = total_intersection(query,doc) / max(query_size, doc_size)
void __global__ docQueryScoringCoalescedMemoryAccessKernel(
    cudf::column_device_view const d_docs, const size_t n_docs,
    uint16_t *query, const int query_len, float *scores) {
    // each thread process one doc-query pair scoring task
    register auto tid = blockIdx.x * blockDim.x + threadIdx.x, tnum = gridDim.x * blockDim.x;
    if (tid >= n_docs) {
        return;
    }

    __shared__ uint16_t query_on_shm[MAX_QUERY_SIZE];
#pragma unroll
    for (auto i = threadIdx.x; i < query_len; i += blockDim.x) {
        // not very efficient query loading temporally, as assuming its not hotspot
        query_on_shm[i] = query[i];
    }
    __syncthreads();

    auto docs = cudf::detail::lists_column_device_view(d_docs);
    for (auto doc_id = tid; doc_id < n_docs; doc_id += tnum) {
        register int query_idx = 0;
        register float tmp_score = 0.;
        auto const doc = d_docs.element<cudf::string_view>(doc_id);
        auto offset_s = docs.offset_at(doc_id);
        auto offset_e = docs.offset_at(doc_id + 1);
        auto sub_view = docs.child().slice(offset_s, offset_e - offset_s);
        for (auto i = 0; i < sub_view.size(); i++) {
            auto const item = sub_view.element<cudf::string_view>(i);
            int num = h_atoi(item.data());
            while (query_idx < query_len && query_on_shm[query_idx] < num) {
                ++query_idx;
            }
            if (query_idx < query_len) {
                tmp_score += (query_on_shm[query_idx] == num);
            }
            __syncwarp();
        }
        scores[doc_id] = tmp_score / max(query_len, sub_view.size());
    }
}

void doc_query_scoring_gpu(std::vector<std::vector<uint16_t>> &querys,
                           int start_doc_id, const int n_docs,
                           cudf::column_device_view const d_docs,
                           std::vector<std::vector<int>> &indices,
                           std::vector<std::vector<float>> &scores,
                           rmm::cuda_stream_view stream) {
    // use one gpu device
    cudaDeviceProp device_props;
    cudaGetDeviceProperties(&device_props, 0);
    cudaSetDevice(0);

    std::vector<int> s_indices(n_docs);
    // std::vector<float> s_scores(n_docs);
    // use cudaMallocHost to allocate pinned memory
    float *s_scores = nullptr;
    cudaHostAlloc(&s_scores, sizeof(float) * n_docs, cudaHostAllocDefault);

    std::chrono::high_resolution_clock::time_point it = std::chrono::high_resolution_clock::now();
    // std::iota(s_indices.begin(), s_indices.end(), start_doc_id);
    // #pragma omp parallel for schedule(static)
    for (int j = 0; j < n_docs; ++j) {
        s_indices[j] = j + start_doc_id;
    }
    std::chrono::high_resolution_clock::time_point it1 = std::chrono::high_resolution_clock::now();
    std::cout << "iota indeices cost " << std::chrono::duration_cast<std::chrono::milliseconds>(it1 - it).count() << " ms " << std::endl;

    // launch kernel
    int block = N_THREADS_IN_ONE_BLOCK;
    int grid = (n_docs + block - 1) / block;

    // allocate device global memory for outputs
    float *d_scores = nullptr;
    std::chrono::high_resolution_clock::time_point dat = std::chrono::high_resolution_clock::now();
    cudaMalloc(&d_scores, sizeof(float) * n_docs);
    std::chrono::high_resolution_clock::time_point dat1 = std::chrono::high_resolution_clock::now();
    std::cout << "cudaMalloc cost " << std::chrono::duration_cast<std::chrono::milliseconds>(dat1 - dat).count() << " ms " << std::endl;

    for (auto &query : querys) {
        // allocate device global memory for input query
        const size_t query_len = query.size();
        uint16_t *d_query = nullptr;
        std::chrono::high_resolution_clock::time_point qt = std::chrono::high_resolution_clock::now();
        cudaMalloc(&d_query, sizeof(uint16_t) * query_len);
        cudaMemcpyAsync(d_query, query.data(), sizeof(uint16_t) * query_len, cudaMemcpyHostToDevice, stream.value());
        std::chrono::high_resolution_clock::time_point qt1 = std::chrono::high_resolution_clock::now();
        std::cout << "cudaMemcpy H2D query cost " << std::chrono::duration_cast<std::chrono::milliseconds>(qt1 - qt).count() << " ms " << std::endl;

        show_mem_usage();

        std::chrono::high_resolution_clock::time_point tt = std::chrono::high_resolution_clock::now();
        // cudaLaunchKernel
        docQueryScoringCoalescedMemoryAccessKernel<<<grid, block, 0, stream.value()>>>(d_docs, n_docs,
                                                                                       d_query, query_len, d_scores);
        cudaMemcpyAsync(s_scores, d_scores, sizeof(float) * n_docs, cudaMemcpyDeviceToHost, stream.value());
        cudaStreamSynchronize(stream.value());
        std::chrono::high_resolution_clock::time_point tt1 = std::chrono::high_resolution_clock::now();
        std::cout << "docQueryScoringCoalescedMemoryAccessKernel cost " << std::chrono::duration_cast<std::chrono::milliseconds>(tt1 - tt).count() << " ms " << std::endl;

        std::chrono::high_resolution_clock::time_point t = std::chrono::high_resolution_clock::now();
        int topk = n_docs > TOPK ? TOPK : n_docs;
        // sort scores with Heap-based sort
        std::partial_sort(s_indices.begin(), s_indices.begin() + topk, s_indices.end(),
                          [s_scores, start_doc_id](const int &a, const int &b) {
                              if (s_scores[a - start_doc_id] != s_scores[b - start_doc_id]) {
                                  return s_scores[a - start_doc_id] > s_scores[b - start_doc_id];  // by score DESC
                              }
                              return a < b;  // the same score, by index ASC
                          });
        std::chrono::high_resolution_clock::time_point t1 = std::chrono::high_resolution_clock::now();
        std::cout << "heap partial_sort cost " << std::chrono::duration_cast<std::chrono::microseconds>(t1 - t).count() << " microseconds " << std::endl;

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

    cudaFree(d_scores);
    cudaFreeHost(s_scores);
}
