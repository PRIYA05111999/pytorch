#include <ATen/Dispatch.h>
#include <c10/macros/Macros.h>
#include <ATen/native/DispatchStub.h>
#include <ATen/native/cuda/Utils.cuh>
#include <ATen/native/cuda/MultiTensorApply.cuh>

// NOTE: CUDA on Windows requires that the enclosing function
// of a __device__ lambda not have internal linkage.

namespace at { namespace native {

namespace {

template<typename x_t, template<class> class Op>
struct BinaryOpScalarFunctor_ {
    __device__ void operator() (
        int chunk_size,
        TensorListMetadata<1>& tl,
        x_t scalar) {
            int tensor_loc = tl.block_to_tensor[blockIdx.x];
            int chunk_idx = tl.block_to_chunk[blockIdx.x];
            int n = tl.sizes[tensor_loc];

            x_t* x = (x_t*)tl.addresses[0][tensor_loc];
            x += chunk_idx * chunk_size;

            n -= chunk_idx * chunk_size;

            x_t r_x[kILP];

            // to make things simple, we put aligned case in a different code path
            if(n % kILP == 0 && chunk_size % kILP == 0 && is_aligned(x)) {
                for(int i_start = threadIdx.x; i_start * kILP < n && i_start * kILP < chunk_size; i_start += blockDim.x) {
                    // load
                    load_store(r_x, x, 0 , i_start);
#pragma unroll
                    for(int ii = 0; ii < kILP; ii++) {
                        r_x[ii] = Op<x_t>()(static_cast<x_t>(r_x[ii]), scalar);
                    }
                    // store
                    load_store(x, r_x, i_start, 0);
                }
            }
            else {
                // Non-divergent exit condition for __syncthreads, not necessary here
                for(int i_start = 0; i_start < n && i_start < chunk_size; i_start += blockDim.x * kILP) {
#pragma unroll
                    for(int ii = 0; ii < kILP; ii++) {
                        r_x[ii] = 0;
                        int i = i_start + threadIdx.x + ii * blockDim.x;
                        if(i < n && i < chunk_size) {
                            r_x[ii] = x[i];
                        }
                    }
#pragma unroll
                    for(int ii = 0; ii < kILP; ii++) {
                        r_x[ii] = Op<x_t>()(static_cast<x_t>(r_x[ii]), scalar);
                    }
#pragma unroll
                    for(int ii = 0; ii < kILP; ii++) {
                        int i = i_start + threadIdx.x + ii * blockDim.x;
                        if(i < n && i < chunk_size)
                            x[i] = r_x[ii];
                    }
                }
            }
        }
};

template<typename x_t, typename out_t, template<class> class Op>
struct BinaryOpScalarFunctor {
    __device__ void operator() (
        int chunk_size,
        TensorListMetadata<2>& tl,
        x_t scalar) {
            int tensor_loc = tl.block_to_tensor[blockIdx.x];
            int chunk_idx = tl.block_to_chunk[blockIdx.x];
            int n = tl.sizes[tensor_loc];

            x_t* x = (x_t*)tl.addresses[0][tensor_loc];
            x += chunk_idx * chunk_size;

            out_t* out = (out_t*)tl.addresses[1][tensor_loc];
            out += chunk_idx * chunk_size;

            n -= chunk_idx * chunk_size;

            x_t r_x[kILP];
            out_t r_out[kILP];

            // to make things simple, we put aligned case in a different code path
            if(n % kILP == 0 && chunk_size % kILP == 0 && is_aligned(x) && is_aligned(out)) {
                for(int i_start = threadIdx.x; i_start * kILP < n && i_start * kILP < chunk_size; i_start += blockDim.x) {
                    // load
                    load_store(r_x, x, 0 , i_start);
#pragma unroll
                    for(int ii = 0; ii < kILP; ii++) {
                        r_out[ii] = Op<x_t>()(static_cast<x_t>(r_x[ii]), scalar);
                    }
                    // store
                    load_store(out, r_out, i_start, 0);
                }
            }
            else {
                // Non-divergent exit condition for __syncthreads, not necessary here
                for(int i_start = 0; i_start < n && i_start < chunk_size; i_start += blockDim.x * kILP) {
#pragma unroll
                    for(int ii = 0; ii < kILP; ii++) {
                        r_x[ii] = 0;
                        int i = i_start + threadIdx.x + ii * blockDim.x;
                        if(i < n && i < chunk_size) {
                            r_x[ii] = x[i];
                        }
                    }
#pragma unroll
                    for(int ii = 0; ii < kILP; ii++) {
                        r_out[ii] = Op<x_t>()(static_cast<x_t>(r_x[ii]), scalar);
                    }
#pragma unroll
                    for(int ii = 0; ii < kILP; ii++) {
                        int i = i_start + threadIdx.x + ii * blockDim.x;
                        if(i < n && i < chunk_size)
                            out[i] = r_out[ii];
                    }
                }
            }
        }
};

} // namespace

template<template<class> class Op>
std::vector<Tensor> foreach_binary_op(TensorList tensors, Scalar scalar) {
    TORCH_CHECK(std::all_of(tensors.begin(), tensors.end(), [] (const Tensor& t) {
        return t.layout() == at::kStrided;
    }), "Only tensors with strided layouts are supported.");

    TORCH_CHECK(std::all_of(tensors.begin(), tensors.end(), [] (const Tensor& t) {
        return t.is_non_overlapping_and_dense();
    }), "Only non overlapping and dense tensors are supported.");

    std::vector<std::vector<at::Tensor>> tensor_lists; 
    std::vector<at::Tensor> vec_res;
    for (int i = 0; i < tensors.size(); i++) {
        vec_res.emplace_back(torch::empty_like(tensors[i]));
    }

    tensor_lists.emplace_back(std::move(tensors.vec()));
    tensor_lists.emplace_back(std::move(vec_res));

    AT_DISPATCH_ALL_TYPES_AND_COMPLEX_AND3(kBool, kBFloat16, kHalf, tensors[0].scalar_type(), "foreach_tensor_add_scalar_kernel_cuda", [&]() {
        multi_tensor_apply<2>(tensor_lists, BinaryOpScalarFunctor<scalar_t, scalar_t, Op>(), scalar.to<scalar_t>());
    });
    return tensor_lists[1];
}

template<template<class> class Op>
std::vector<Tensor> foreach_binary_op_(TensorList tensors, Scalar scalar) {
    TORCH_CHECK(std::all_of(tensors.begin(), tensors.end(), [] (const Tensor& t) {
        return t.layout() == at::kStrided;
    }), "Only tensors with strided layouts are supported.");

    TORCH_CHECK(std::all_of(tensors.begin(), tensors.end(), [] (const Tensor& t) {
        return t.is_non_overlapping_and_dense();
    }), "Only non overlapping and dense tensors are supported.");
    
    std::vector<std::vector<at::Tensor>> tensor_lists; 
    tensor_lists.emplace_back(std::move(tensors.vec()));

    AT_DISPATCH_ALL_TYPES_AND_COMPLEX_AND3(kBool, kBFloat16, kHalf, tensors[0].scalar_type(), "foreach_tensor_add_scalar__kernel_cuda", [&]() {
        multi_tensor_apply<1>(tensor_lists, BinaryOpScalarFunctor_<scalar_t, Op>(), scalar.to<scalar_t>());
    });
    return tensor_lists[0];
}

std::vector<Tensor> foreach_tensor_add_scalar_kernel_cuda(TensorList tensors, Scalar scalar) {
    return foreach_binary_op<std::plus>(tensors, scalar);
}

std::vector<Tensor> foreach_tensor_add_scalar__kernel_cuda(TensorList tensors, Scalar scalar) {
    return foreach_binary_op_<std::plus>(tensors, scalar);
}

std::vector<Tensor> foreach_tensor_sub_scalar_kernel_cuda(TensorList tensors, Scalar scalar) {
    return foreach_binary_op<std::minus>(tensors, scalar);
}

std::vector<Tensor> foreach_tensor_sub_scalar__kernel_cuda(TensorList tensors, Scalar scalar) {
    return foreach_binary_op_<std::minus>(tensors, scalar);
}

std::vector<Tensor> foreach_tensor_mul_scalar_kernel_cuda(TensorList tensors, Scalar scalar) {
    return foreach_binary_op<std::multiplies>(tensors, scalar);
}

std::vector<Tensor> foreach_tensor_mul_scalar__kernel_cuda(TensorList tensors, Scalar scalar) {
    return foreach_binary_op_<std::multiplies>(tensors, scalar);
}

std::vector<Tensor> foreach_tensor_div_scalar_kernel_cuda(TensorList tensors, Scalar scalar) {
    return foreach_binary_op<std::divides>(tensors, scalar);
}

std::vector<Tensor> foreach_tensor_div_scalar__kernel_cuda(TensorList tensors, Scalar scalar) {
    return foreach_binary_op_<std::divides>(tensors, scalar);
}

}} // namespace at::native
