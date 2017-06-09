#include <iostream>
#include "gpu/mblas/nth_element.h"
#include "common/utils.h"
#include "matrix_wrapper.h"

using namespace std;

namespace amunmt {
namespace GPU {

#define UNROLL_MAXARG_LOOP( n, max ) \
  if (tid < (n) && tid + (n) < ( max ) ) { \
    if (sdata[tid + ( n ) ] > sdata[tid]) { \
      sdata[tid] = sdata[tid + ( n ) ]; \
      indices[tid] = indices[tid + ( n ) ]; \
    } \
  }

#define HANDLE_ERROR( err ) (HandleError( err, __FILE__, __LINE__ ))

__global__ void gMaxElement(mblas::MatrixWrapper<float> outWrap,
                            mblas::MatrixWrapper<int> indWrap,
                            float* d_out, int* d_ind,
                            float* d_in, int numBatches, int* batchFirstElementIdxs) {
  extern __shared__ float sdata[];
  __shared__ int indices[512];

  int tid = threadIdx.x;

  for (int batchIdx = 0; batchIdx < numBatches; ++batchIdx) {
    int begin = batchFirstElementIdxs[batchIdx];
    int end = batchFirstElementIdxs[batchIdx + 1];

    int i = begin + blockIdx.x * (blockDim.x * 2) + tid;

    sdata[tid] = -3.40282e+38f;

    if (i < end) {
      sdata[tid] = d_in[i];
      indices[tid] = i;
    }

    if (i + blockDim.x < end) {
      float a = d_in[i];
      float b = d_in[i + blockDim.x];
      if (a > b) {
        sdata[tid] = a;
        indices[tid] = i;
      } else {
        sdata[tid] = b;
        indices[tid] = i + blockDim.x;
      }
    }

    while (i + 2 * gridDim.x * blockDim.x < end) {
      i += 2 * gridDim.x * blockDim.x;

      float a = d_in[i];
      if (a > sdata[tid]) {
        sdata[tid] = a;
        indices[tid] = i;
      }

      if (i + blockDim.x < end) {
        float b = d_in[i + blockDim.x];
        if (b > sdata[tid]) {
          sdata[tid] = b;
          indices[tid] = i + blockDim.x;
        }
      }
    }

    __syncthreads();

    for (int s = (blockDim.x >> 1); s > 32; s >>= 1) {
      if (tid < s && tid + s < end) {
        if (sdata[tid + s] > sdata[tid]) {
          sdata[tid] = sdata[tid + s];
          indices[tid] = indices[tid + s];
        }
      }
      __syncthreads();
    }

    UNROLL_MAXARG_LOOP(32, end);
    UNROLL_MAXARG_LOOP(16, end);
    UNROLL_MAXARG_LOOP(8, end);
    UNROLL_MAXARG_LOOP(4, end);
    UNROLL_MAXARG_LOOP(2, end);
    UNROLL_MAXARG_LOOP(1, end);

    if (tid == 0) {
      outWrap[blockIdx.x + batchIdx * gridDim.x] = sdata[0];
      d_ind[blockIdx.x + batchIdx * gridDim.x] = indices[0];
    }
    __syncthreads();
  }
}

__global__ void gMaxElementUpdate(float* binCosts, int* binIdxs, float* probs, int *batchFirstElements, float* outCosts, int* outIdxs, int *cummulatedBeamSizes, int numBlocks_) {
  extern __shared__ float sdata[];
  __shared__ int indices[512];
  __shared__ float bestBinCost;
  __shared__ int bestBinCostIdx;

  const int tid = threadIdx.x;
  const int batchIdx = blockIdx.x;
  const int N = batchFirstElements[batchIdx + 1] - batchFirstElements[batchIdx];
  int num_bins = int(N / (2 * 512)) + int(N % (2 * 512) != 0);
  if (num_bins > 500) {
    num_bins = 500;
  }

  for (int pos = cummulatedBeamSizes[batchIdx]; pos < cummulatedBeamSizes[batchIdx + 1]; ++pos) {
    int i = tid;

    sdata[tid] = -3.40282e+38f;

    if (i < num_bins) {
      sdata[tid] = binCosts[batchIdx * numBlocks_ + i];
      indices[tid] = i;
    }

    if (i + blockDim.x < num_bins) {
      float a = binCosts[batchIdx * numBlocks_ + i];
      float b = binCosts[batchIdx * numBlocks_ + i + blockDim.x];
      if (a > b) {
        sdata[tid] = a;
        indices[tid] = i;
      } else {
        sdata[tid] = b;
        indices[tid] = i + blockDim.x;
      }
    }

    while (i + 2 * blockDim.x < num_bins) {
      i += 2 * blockDim.x;

      float a = binCosts[batchIdx * numBlocks_ + i];
      if (a > sdata[tid]) {
        sdata[tid] = a;
        indices[tid] = i;
      }

      if (i + blockDim.x < num_bins) {
        float b = binCosts[batchIdx * numBlocks_ + i + blockDim.x];
        if (b > sdata[tid]) {
          sdata[tid] = b;
          indices[tid] = i + blockDim.x;
        }
      }
    }

    __syncthreads();

    for (int s = (blockDim.x >> 1); s > 32; s >>= 1) {
      if (tid < s && tid + s < num_bins) {
        if (sdata[tid + s] > sdata[tid]) {
          sdata[tid] = sdata[tid + s];
          indices[tid] = indices[tid + s];
        }
      }
      __syncthreads();
    }

    UNROLL_MAXARG_LOOP(32, num_bins);
    UNROLL_MAXARG_LOOP(16, num_bins);
    UNROLL_MAXARG_LOOP(8, num_bins);
    UNROLL_MAXARG_LOOP(4, num_bins);
    UNROLL_MAXARG_LOOP(2, num_bins);
    UNROLL_MAXARG_LOOP(1, num_bins);

    if (tid == 0) {
      bestBinCost = sdata[0];
      bestBinCostIdx = batchIdx * numBlocks_ + indices[0];

      probs[binIdxs[bestBinCostIdx]] = -3.40282e+38f;

      outIdxs[pos] = binIdxs[bestBinCostIdx];
      outCosts[pos] = bestBinCost;
    }

    __syncthreads();

    i = batchFirstElements[batchIdx] + (bestBinCostIdx - batchIdx * numBlocks_) * (blockDim.x * 2) + tid;
    const int dist = num_bins * 2 * blockDim.x;

    sdata[tid] = -3.40282e+38f;

    if (i < batchFirstElements[batchIdx + 1]) {
      sdata[tid] = probs[i];
      indices[tid] = i;
    }

    if (i + blockDim.x < batchFirstElements[batchIdx + 1]) {
      float a = probs[i];
      float b = probs[i+blockDim.x];
      if (a > b) {
        sdata[tid] = a;
        indices[tid] = i;
      } else {
        sdata[tid] = b;
        indices[tid] = i + blockDim.x;
      }
    }

    while (i + dist < batchFirstElements[batchIdx + 1]) {
      i += dist;

      float a = probs[i];
      if (a > sdata[tid]) {
        sdata[tid] = a;
        indices[tid] = i;
      }

      if (i + blockDim.x < batchFirstElements[batchIdx + 1]) {
        float b = probs[i + blockDim.x];
        if (b > sdata[tid]) {
          sdata[tid] = b;
          indices[tid] = i + blockDim.x;
        }
      }
    }

    __syncthreads();

    for (int s = (blockDim.x >> 1); s > 32; s >>= 1) {
      if (tid < s && tid + s < batchFirstElements[batchIdx + 1]) {
        if (sdata[tid + s] > sdata[tid]) {
          sdata[tid] = sdata[tid + s];
          indices[tid] = indices[tid + s];
        }
      }
      __syncthreads();
    }

    UNROLL_MAXARG_LOOP(32, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(16, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(8, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(4, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(2, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(1, batchFirstElements[batchIdx + 1]);

    if (tid == 0) {
      binCosts[bestBinCostIdx] = sdata[0];
      binIdxs[bestBinCostIdx] = indices[0];
    }
    __syncthreads();
  }
}

__global__ void gGetValueByKey(float* d_in, float* d_out, int* indices, int n)
{
  int tid = threadIdx.x  + blockDim.x * blockIdx.x;
  if (tid < n) {
    int index = indices[tid];
    d_out[tid] = d_in[index];
  }
}

NthElement::NthElement(size_t maxBeamSize, size_t maxBatchSize, cudaStream_t& stream)
: stream_(stream)
, numBlocks_(std::min(500, int(maxBeamSize * 85000 / (2 * BLOCK_SIZE)) + int(maxBeamSize * 85000 % (2 * BLOCK_SIZE) != 0)))
, d_out(maxBatchSize * numBlocks_)
, d_ind(maxBatchSize * numBlocks_)
, d_res_idx(maxBatchSize * maxBeamSize)
, d_res(maxBatchSize * maxBeamSize)
{
  HANDLE_ERROR( cudaHostAlloc((void**) &h_res, maxBeamSize * maxBatchSize* sizeof(float),
                              cudaHostAllocDefault) );
  HANDLE_ERROR( cudaHostAlloc((void**) &h_res_idx, maxBeamSize * maxBatchSize * sizeof(int),
                              cudaHostAllocDefault) );

  HANDLE_ERROR( cudaMalloc((void**)&d_breakdown, maxBeamSize * sizeof(float)) );
  HANDLE_ERROR( cudaMalloc((void**)&d_batchPosition, (maxBatchSize + 1) * sizeof(int)) );
  HANDLE_ERROR( cudaMalloc((void**)&d_cumBeamSizes, (maxBatchSize + 1) * sizeof(int)) );
}

NthElement::~NthElement()
{
  HANDLE_ERROR(cudaFreeHost(h_res));
  HANDLE_ERROR(cudaFreeHost(h_res_idx));
  HANDLE_ERROR(cudaFree(d_breakdown));
  HANDLE_ERROR(cudaFree(d_batchPosition));
  HANDLE_ERROR(cudaFree(d_cumBeamSizes));
}

void NthElement::getNBestList(float* probs, const std::vector<int>& batchFirstElementIdxs,
                              const std::vector<int>& cummulatedBeamSizes)
{
  HANDLE_ERROR( cudaMemcpyAsync(d_batchPosition, batchFirstElementIdxs.data(), batchFirstElementIdxs.size() * sizeof(int),
                                cudaMemcpyHostToDevice, stream_) );
  HANDLE_ERROR( cudaMemcpyAsync(d_cumBeamSizes, cummulatedBeamSizes.data(), cummulatedBeamSizes.size() * sizeof(int),
                                cudaMemcpyHostToDevice, stream_) );

  const int numBatches = batchFirstElementIdxs.size() - 1;

  mblas::MatrixWrapper<float> outWrap(d_out);
  mblas::MatrixWrapper<int> indWrap(d_ind);

  gMaxElement<<<numBlocks_, BLOCK_SIZE, BLOCK_SIZE * sizeof(float), stream_>>>
    (outWrap, indWrap, thrust::raw_pointer_cast(d_out.data()), thrust::raw_pointer_cast(d_ind.data()), probs, numBatches, d_batchPosition);

  gMaxElementUpdate<<<numBatches, BLOCK_SIZE, BLOCK_SIZE * sizeof(float), stream_>>>
    (thrust::raw_pointer_cast(d_out.data()),
     thrust::raw_pointer_cast(d_ind.data()),
     probs,
     d_batchPosition,
     thrust::raw_pointer_cast(d_res.data()),
     thrust::raw_pointer_cast(d_res_idx.data()),
     d_cumBeamSizes,
     numBlocks_);
}

void NthElement::getNBestList(const std::vector<size_t>& beamSizes, mblas::Matrix& Probs,
                  std::vector<float>& outCosts, std::vector<unsigned>& outKeys,
                  const bool isFirst) {
  std::vector<int> cummulatedBeamSizes(beamSizes.size() + 1);
  std::vector<int> batchFirstElementIdxs(beamSizes.size() + 1);
  cummulatedBeamSizes[0] = 0;
  batchFirstElementIdxs[0] = 0;

  const size_t vocabSize = Probs.dim(1);
  for (size_t i = 0; i < beamSizes.size(); ++i) {

    cummulatedBeamSizes[i + 1] = cummulatedBeamSizes[i] + beamSizes[i];
    batchFirstElementIdxs[i + 1] = ((isFirst) ? (i + 1) : cummulatedBeamSizes[i + 1]) * vocabSize;
  }

  //cerr << endl;
  //cerr << "beamSizes=" << Debug(beamSizes, 2) << endl;
  //cerr << "cummulatedBeamSizes=" << Debug(cummulatedBeamSizes, 2) << endl;
  //cerr << "batchFirstElementIdxs=" << Debug(batchFirstElementIdxs, 2) << endl;
  //cerr << "1Probs=" << Probs.Debug() << endl;

  getNBestList(Probs.data(), batchFirstElementIdxs, cummulatedBeamSizes);

  //cerr << "2Probs=" << Probs.Debug() << endl;
  //cerr << "cummulatedBeamSizes.back()=" << cummulatedBeamSizes.back() << endl;
  //cerr << "cummulatedBeamSizes=" << Debug(cummulatedBeamSizes, 2) << endl;
  GetPairs(cummulatedBeamSizes.back(), outKeys, outCosts);

  //cerr << "outCosts=" << Debug(outCosts, 2) << endl;
  //cerr << "outKeys=" << Debug(outKeys, 2) << endl;
}

void NthElement::GetPairs(size_t number,
                    std::vector<unsigned>& outKeys,
                    std::vector<float>& outValues) {

  HANDLE_ERROR( cudaMemcpyAsync(h_res, thrust::raw_pointer_cast(d_res.data()), number * sizeof(float),
                                cudaMemcpyDeviceToHost, stream_) );
  HANDLE_ERROR( cudaMemcpyAsync(h_res_idx, thrust::raw_pointer_cast(d_res_idx.data()), number * sizeof(int),
                                cudaMemcpyDeviceToHost, stream_) );
  HANDLE_ERROR( cudaStreamSynchronize(stream_) );

  for (size_t i = 0; i < number; ++i) {
    outKeys.push_back(h_res_idx[i]);
    outValues.push_back(h_res[i]);
  }

  lastN = number;
}

void NthElement::getValueByKey(std::vector<float>& out, float* d_in) const
{
  gGetValueByKey<<<1, lastN, 0, stream_>>>
    (d_in, d_breakdown, h_res_idx, lastN);

  HANDLE_ERROR( cudaMemcpyAsync(out.data(), d_breakdown, lastN * sizeof(float),
                                cudaMemcpyDeviceToHost, stream_) );
  HANDLE_ERROR( cudaStreamSynchronize(stream_));
}

}  // namespace GPU
} // namespace amunmt
