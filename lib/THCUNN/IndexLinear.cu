#include "THCUNN.h"
#include "THCHalf.h"
#include "THCHalfAutoNumerics.cuh"
#include "THCAtomics.cuh"

#define divup(a, b) ((a) + (b) - 1) / (b)
const int THREADS_PER_BLOCK = 256;
const int THREADS_X = 32;
const int THREADS_Y = THREADS_PER_BLOCK / THREADS_X;
const int REPEAT = 32;

/* sign MACRO */
#ifndef clamp
#define clamp(a, low, high) max(min((a), (high)), (low))
#endif

template<typename Ty>
__global__ static
void updateOutput(
    Ty *output,
    const Ty *values,
    const long *cumSumSizes,
    const long *keys,
    const long batchSize,
    const long outDim,
    Ty *weight,
    const Ty *bias,
    const long weightStride,
    const long keysOffset,
    int maxNormalize)
{
    /*******************************************************
     * Adapted from the following file in arrayfire
     * https://github.com/arrayfire/arrayfire/blob/v3.4.1/src/backend/opencl/kernel/csrmm.cl
     *
     *******************************************************
     * Original copyright notice can be seen below:
     *
     * Copyright (c) 2016, ArrayFire
     * All rights reserved.
     *
     * This file is distributed under 3-clause BSD license.
     * The complete license agreement can be obtained at:
     * http://arrayfire.com/licenses/BSD-3-Clause
     ********************************************************/

    const long tidx = threadIdx.x;
    const long tidy = threadIdx.y;
    const long tid  = tidy * blockDim.x + tidx;
    const long gidx = blockIdx.x * blockDim.x + tidx;


    Ty *nWeight = weight;
     // Offset the number of elements specified by  maxNormalize
    weight += gidx + maxNormalize;
    output += gidx;

    bool within_N = (gidx < outDim);

    __shared__ Ty s_values[THREADS_PER_BLOCK];
    __shared__ long s_keys[THREADS_PER_BLOCK];

    const long rowId = blockIdx.y;
    // if (rowId >= batchSize) return;

    // Load the nonzero column offsets for current row
    const long batchStart = rowId == 0 ? 0 : cumSumSizes[rowId - 1];
    const long batchEnd   = cumSumSizes[rowId];
    const long batchStride = blockDim.x * blockDim.y;

    Ty outVal = 0;
    // Since the number of nonzero elements might be greater than local memory available,
    // Load only part of the row into local memory, perform partial dot, repeat until done.
    for (long id = batchStart; id < batchEnd; id += batchStride) {
        // Load the current chunk of the row into local memory
        long lim = min(batchEnd - id, (long)batchStride);

        // Subtract 1 from keys[id + tid] to convert base 1 to base 0
        long key = tid < lim ? keys[id + tid] + keysOffset : -1;
        Ty val = tid < lim ? values[id + tid] : 0;

        if (maxNormalize && tid < lim) {
            Ty *nWeightCurr = nWeight + key * weightStride;
            val = clamp(val * nWeightCurr[1], -1.0, 1.0) + nWeightCurr[3];
        }

        s_keys[tid] = key;
        s_values[tid] = val;
        __syncthreads();

        // Perform a single "dot" operation for each thread
        for (long idy = tidy; within_N && idy < lim; idy += blockDim.y) {
            outVal += s_values[idy] * weight[weightStride * s_keys[idy]];
        }
        __syncthreads();
    }

    // s_values is no longer used at this point. Reuse it for reducing outVal.
    // A reduction along the y dimension now gives a single output value along x.
    s_values[tid] = outVal;
    for (long y = blockDim.y / 2; y >= 1; y /= 2) {
        __syncthreads();
        if (tidy < y) s_values[tid] = s_values[tid] + s_values[tid + y * blockDim.x];
    }

    if (within_N && tidy == 0) {
        output[rowId * outDim] = s_values[tid] + bias[gidx];
    }
}

// This kernel is launched with [M x 1] blocks of size [X x Y].
// Each block writes X entries to the output for the given batchId.
template<typename Ty>
__global__ static
void updateOutputTrain(
    Ty *output,
    Ty *normalizedValues,
    const Ty *values,
    const long *cumSumSizes,
    const long *keys,
    const long batchSize,
    const long outDim,
    Ty *weight,
    const Ty *bias,
    const long weightStride,
    const long keysOffset,
    int maxNormalize,
    long batchId)
{
    const long tidx = threadIdx.x;
    const long tidy = threadIdx.y;
    const long tid  = tidy * blockDim.x + tidx;
    const long gidx = blockIdx.x * blockDim.x + tidx;

    const long batchStart = batchId == 0 ? 0 : cumSumSizes[batchId - 1];
    const long batchEnd   = cumSumSizes[batchId];
    const long batchLimit = batchEnd - batchStart;

    // A dot operation is performed by a single block.
    // Calculate the number of iterations required to load all elements from current batch.
    const long iters = divup(batchLimit, blockDim.x * blockDim.y);

    Ty *nWeight = weight;
    // Offset to the current output id
    weight += maxNormalize + gidx;
    output += batchId * outDim + gidx;

    // Offset to the current batch
    keys += batchStart;
    values += batchStart;
    normalizedValues += batchStart;

    __shared__ Ty s_values[THREADS_PER_BLOCK];
    __shared__ long s_keys[THREADS_PER_BLOCK];

    Ty outVal = 0;
    // Not bailing early because we need __syncthreads later
    for (long n = 0; n < iters; n++) {
        long off = n * blockDim.y * blockDim.x;
        long lim = min((long)blockDim.y * blockDim.x, batchLimit - off);


        // Each block uses all of its threads to load data.
        // This ensures coalesced reads from global memory.
        // Each variable in shared memory is then used by all the threads in a warp.
        if (tid < lim) {
            Ty val = values[off + tid];
            long key = keys[off + tid] + keysOffset;
            long nWeightOffset = key * weightStride;

            Ty absVal = fabs(val);
            Ty maxVal = nWeight[key * weightStride + 0];
            if (absVal > maxVal) {
                // Updating maxVal and invMaxVal
                nWeight[nWeightOffset + 0] = absVal;
                nWeight[nWeightOffset + 1] = 1.0/absVal;
                maxVal = absVal;
            }

            // TODO: implement a smarter update scale following the CPU implementation.
            nWeight[nWeightOffset + 2] = 1.0;
            s_values[tid] = val / maxVal + nWeight[nWeightOffset + 3];
            s_keys[tid] = key;
            normalizedValues[off + tid] = s_values[tid];
        }
        __syncthreads();

        if (gidx < outDim) {
            // Performing the partial dot operation for each thread
            for (long id = tidy; id < lim; id += blockDim.y) {
                outVal += s_values[id] * weight[weightStride * s_keys[id]];
            }
        }
        __syncthreads();
    }

    // s_values is no longer used at this point. Reuse it for reducing outVal.
    // A reduction along the y dimension now gives a single output value along x.
    s_values[tid] = outVal;
    for (long y = blockDim.y / 2; y >= 1; y /= 2) {
        __syncthreads();
        if (tidy < y) s_values[tid] = s_values[tid] + s_values[tid + y * blockDim.x];
    }

    // Writing the final value from the first lane into the output.
    if (gidx < outDim && tidy == 0) {
        *output = s_values[tid] + bias[gidx];
    }
}

// This kernel takes in the following inputs:
// values of size [keysSize x 1] and gradOutput of size [batchSize x outDim],
// to generate gradWeight of size [keysSize x outDim]
// nth block along y dimension computes on the non zero elements from the nth batch.
template<typename Ty>
__global__ static
void accGradWeight(
    Ty *gradWeight,
    const Ty *gradOutput,
    const Ty *values,
    const long  *cumSumSizes,
    const long  outDim,
    const long  gradWeightStride,
    const Ty scale,
    const Ty weightDecay,
    const int maxNormalize)
{
    const long bidy = blockIdx.y;
    const long tidx = threadIdx.x;
    const long tidy = threadIdx.y;
    const long tid  = tidy * blockDim.x + tidx;
    const long ntid = blockDim.x * blockDim.y;
    const long gidx = blockIdx.x * blockDim.x + tidx;

    // All the y threads in the block will use the same gradOutput value
    gradOutput += bidy * outDim;
    Ty gradOutVal = scale * (gidx < outDim ? gradOutput[gidx] : 0);

    // Calculate the amount of work for the current block / batch.
    const long batchStart = bidy == 0 ? 0 : cumSumSizes[bidy - 1];
    const long batchEnd   = cumSumSizes[bidy];
    const long batchLimit = batchEnd - batchStart;

    // Number of iterations required to finish the work for the current batch.
    const long iters    = divup(batchLimit, ntid);

    // Offset the values to the current batch.
    values += batchStart;

    // When maxNormalize is enabled, gradWeight will be twice the size.
    // The first half will contain the gradients required for maxNormalization.
    // The second half will contain the gradients required for updating weights.
    // if maxNormalize is false, both will evaluate to the same pointer.
    Ty *gradWeight0 = gradWeight + batchStart * gradWeightStride + gidx;
    Ty *gradWeight1 = gradWeight0 + (maxNormalize ? outDim : 0);

    __shared__ Ty s_values[THREADS_PER_BLOCK];

    // Using iters to avoid divergence + synchtreads
    for (long n = 0; n < iters; n++) {
        long off = n * ntid;
        long id = off + tid;
        long lim = min(ntid, batchLimit - off);

        // Read the values required for the current iteration.
        s_values[tid] = id < batchLimit ? values[id] : 0;
        __syncthreads();

        if (gidx < outDim) {
            if (maxNormalize) {
                for (long idy = tidy; idy < lim; idy += blockDim.y) {
                    // gradOutVal is already scaled
                    gradWeight0[(off + idy) * gradWeightStride] = gradOutVal;
                }
            }

            for (long idy = tidy; idy < lim; idy += blockDim.y) {
                gradWeight1[(off + idy) * gradWeightStride] = s_values[idy] * gradOutVal;
            }
        }
        __syncthreads();
    }
}

// The gradBias is just a reduction of gradOutput along the batches.
// There is only one block along y dimension performing the reduction.
template<typename Ty, bool update>
__global__ static
void accGradBias(
    Ty *buffer,
    const Ty *gradOutput,
    const long  outDim,
    const long  batchSize,
    const Ty scale,
    const Ty weightDecay)
{
    const int tidx = threadIdx.x;
    const int tidy = threadIdx.y;
    const int tid = tidy * blockDim.x + tidx;
    const long idx = blockIdx.x * blockDim.x + tidx;


    Ty gradBiasVal = 0;
    gradOutput += idx;
    __shared__ Ty s_gradBiasVals[THREADS_PER_BLOCK];

    // Each thread along y calculates the partial sum.
    if (idx < outDim) {
        for (long idy = tidy; idy < batchSize; idy += blockDim.y) {
            gradBiasVal += gradOutput[idy * outDim];
        }
    }
    s_gradBiasVals[tid] = gradBiasVal * scale;
    __syncthreads();

    // Perform reduction is performed along y.
    for (int y = blockDim.y / 2; y >= 1; y /= 2) {
        if (tidy < y) {
            s_gradBiasVals[tid] += s_gradBiasVals[tid + y * blockDim.x];
        }
        __syncthreads();
    }

    // Write the output only from the first lane.
    if (tidy == 0 && idx < outDim) {
        if (update) {
            // If performing inplace update, subtract from bias.
            Ty *bias = buffer;
            bias[idx] = (bias[idx] - s_gradBiasVals[tid]);
        } else {
            // If just accumulating gradients, write to gradBias.
            Ty *gradBias = buffer;
            gradBias[idx] = s_gradBiasVals[tid];
        }
    }
}

// Use gradWeight from accGradWeight to update the weight.
// This kernel is launched batchSize number of times.
// At each step in the iteration, the weights are updated in a sparse manner.
template<typename Ty>
__global__ static
void updateWeight(
    Ty *weight,
    const Ty *gradWeight,
    const long *keys,
    const long *cumSumSizes,
    const long outDim,
    const long gradWeightStride,
    const long weightStride,
    const long keysOffset,
    const Ty learningRate,
    const Ty weightDecay,
    const int maxNormalize,
    const long batchId)
{
    long gidx = blockIdx.x * blockDim.x + threadIdx.x;
    long gidy = blockIdx.y * blockDim.y + threadIdx.y;

    // Find the limits of the work to be done
    const long batchStart = batchId == 0 ? 0 : cumSumSizes[batchId - 1];
    const long batchEnd = cumSumSizes[batchId];

    // When maxNormalize is turned on, the weight tensor will contain
    // an extra "maxNormalize" number of terms per output at the beginning.
    // When maxNormalize is false, both will evaluate to same pointer.
    // when maxNormalize is true,
    // - nWeight[2] will contain the individual scaling factor.
    // - nWeight[3] will contain the individual bias for the normalized input.
    Ty *nWeight = weight;
    weight += maxNormalize + gidx;

    // When maxNormalize is enabled, gradWeight will be twice the size.
    // The first half will contain the gradients required for maxNormalization.
    // The second half will contain the gradients required for updating weights.
    // if maxNormalize is false, both will evaluate to the same pointer.
    const Ty *gradWeight0 = gradWeight + gidx;
    const Ty *gradWeight1 = gradWeight0 + (maxNormalize ? outDim : 0);

    if (gidx >= outDim) return;
    for (long id = batchStart + gidy; id < batchEnd; id += blockDim.y * gridDim.y) {
        Ty lr = learningRate;
        Ty wd = weightDecay;
        long weightOffset = (keys[id] + keysOffset) * weightStride;
        Ty weightVal = weight[weightOffset];

        if (maxNormalize) {
            Ty scale = nWeight[weightOffset + 2];
            lr *= scale;
            wd *= scale;
            // nWeight[3] needs to be updated in the following manner for a given input.
            // nWeight[3] = nWeight[3] - sum(gradWeight0[gidx] * weight[gidx]);
            // Since problem is parallelized along gidx, use atomicAdd for the update.
            Ty gradNormBias = lr * weightVal * gradWeight0[id * gradWeightStride];
            atomicAdd(nWeight + weightOffset + 3, -gradNormBias);
        }

        // Perform the regular update
        Ty gradWeightVal = lr * gradWeight1[id * gradWeightStride];
        if (weightDecay == 0) {
            weight[weightOffset] = weightVal - gradWeightVal;
        } else {
            weight[weightOffset] = weightVal * (1 - wd) - gradWeightVal;
        }
    }
}

// This kernel is launched batchSize number of times.
// At each step in the iteration, the weights are updated in place in a sparse manner.
template<typename Ty>
__global__ static
void accUpdateWeight(
    Ty *weight,
    const long weightStride,
    const Ty *gradOutput,
    const long outDim,
    const Ty *values,
    const long *cumSumSizes,
    const long *keys,
    const long keysOffset,
    const Ty scale,
    const Ty weightDecay,
    const int maxNormalize,
    const long batchId)
{
    // Parallel along outDim.
    long gidx = blockIdx.x * blockDim.x + threadIdx.x;
    // Parallel along the sparse input size for current batch.
    long gidy = blockIdx.y * blockDim.y + threadIdx.y;

    if (gidx >= outDim) return;

    // Find the limits of the work to be done.
    const long batchStart = batchId == 0 ? 0 : cumSumSizes[batchId - 1];
    const long batchEnd = cumSumSizes[batchId];

    gradOutput += batchId * outDim;
    Ty gradOutVal = scale * (gidx < outDim ? gradOutput[gidx] : 0);

    // When maxNormalize is turned on, the weight tensor will contain
    // an extra "maxNormalize" number of terms per output at the beginning.
    // When maxNormalize is false, both will evaluate to same pointer.
    // when maxNormalize is true,
    // - nWeight[2] will contain the individual scaling factor.
    // - nWeight[3] will contain the individual bias for the normalized input.
    Ty *nWeight = weight;
    weight += maxNormalize + gidx;

    for (long id = batchStart + gidy; id < batchEnd; id += blockDim.y * gridDim.y) {
        Ty wd = weightDecay;
        long weightOffset = (keys[id] + keysOffset) * weightStride;
        Ty gradWeightVal = gradOutVal * values[id];
        Ty weightVal = weight[weightOffset];

        if (maxNormalize) {
            Ty nScale = nWeight[weightOffset + 2];
            gradWeightVal *= nScale;
            wd *= nScale;
            // nWeight[3] needs to be updated in the following manner for a given input.
            // nWeight[3] = nWeight[3] - sum(gradOut[gidx] * weight[gidx]);
            // Since problem is parallelized along gidx, use atomicAdd for the update.
            Ty gradNormBias = nScale * weightVal * gradOutVal;
            atomicAdd(nWeight + weightOffset + 3, -gradNormBias);
        }

        // Perform the regular update
        if (weightDecay == 0) {
            weight[weightOffset] = weightVal - gradWeightVal;
        } else {
            weight[weightOffset] = weightVal * (1 - wd) - gradWeightVal;
        }
    }
}


#ifdef CUDA_HALF_TENSOR
void THNN_CudaHalfIndexLinear_updateOutput(
                  THCState *state,
                  THCudaLongTensor *keys,
                  long keysOffset,
                  THCudaHalfTensor *values,
                  THCudaLongTensor *sizes,
                  THCudaLongTensor *cumSumSizes,
                  THCudaHalfTensor *output,
                  THCudaHalfTensor *weight,
                  THCudaHalfTensor *bias,
                  THCudaHalfTensor *normalizedValues,
                  int   train) {
    THError("THCudaHalfTensor not supported with IndexLinear");
}

void THNN_CudaHalfIndexLinear_accGradParameters(
                  THCState *state,
                  THCudaLongTensor *keys,
                  long keysOffset,
                  THCudaHalfTensor *values,
                  THCudaLongTensor *sizes,
                  THCudaLongTensor *cumSumSizes,
                  THCudaHalfTensor *gradOutput,
                  THCudaHalfTensor *gradWeight,
                  THCudaHalfTensor *gradBias,
                  THCudaHalfTensor *weight,
                  THCudaHalfTensor *bias,
                  THCudaHalfTensor* valuesBuffer,
                  float weightDecay,
                  float scale) {
    THError("THCudaHalfTensor not supported with IndexLinear");
}

void THNN_CudaHalfIndexLinear_accUpdateGradParameters(
                  THCState *state,
                  THCudaLongTensor *keys,
                  long keysOffset,
                  THCudaHalfTensor *values,
                  THCudaLongTensor *sizes,
                  THCudaLongTensor *cumSumSizes,
                  THCudaHalfTensor *gradOutput,
                  THCudaHalfTensor *weight,
                  THCudaHalfTensor *bias,
                  float weightDecay,
                  float scale) {
    THError("THCudaHalfTensor not supported with IndexLinear");
}

void THNN_CudaHalfIndexLinear_updateParameters(
                  THCState *state,
                  THCudaHalfTensor *gradWeight,
                  THCudaHalfTensor *gradBias,
                  THCudaHalfTensor *weight,
                  THCudaHalfTensor *bias,
                  THCudaLongTensor *runningKeys,
                  THCudaLongTensor *cumSumSizes,
                  long keysOffset,
                  float weightDecay,
                  float learningRate) {
    THError("THCudaHalfTensor not supported with IndexLinear");
}
#endif

#include "generic/IndexLinear.cu"
#include "THCGenerateFloatType.h"
#include "generic/IndexLinear.cu"
#include "THCGenerateDoubleType.h"
