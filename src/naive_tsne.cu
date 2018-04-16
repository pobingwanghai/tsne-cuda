/**
 * @brief Implementation of naive T-SNE
 * 
 * @file naive_tsne.cu
 * @author David Chan
 * @date 2018-04-04
 */

#include "naive_tsne.h"

struct func_inc_inv {
    __host__ __device__ float operator()(const float &x) const { return 1 / (x + 1); }
};

struct func_kl {
    __host__ __device__ float operator()(const float &x, const float &y) const { 
        return x == 0.0f ? 0.0f : x * (log(x) - log(y));
    }
};

struct func_exp {
    __host__ __device__ float operator()(const float &x) const { return exp(x); }
};

struct func_entropy_kernel {
    __host__ __device__ float operator()(const float &x) const { float val = x*log2(x); return (val != val) ? 0 : val; }
};

struct func_pow2 {
    __host__ __device__ float operator()(const float &x) const { return pow(2,x); }
};

__global__ void perplexity_search(float* __restrict__ sigmas, 
                                    float* __restrict__ lower_bound, 
                                    float* __restrict__ upper_bound,
                                    float* __restrict__ perplexity, 
                                    const float* __restrict__ pij, 
                                    const float target_perplexity, 
                                    const int N) 
{
    int TID = threadIdx.x + blockIdx.x * blockDim.x;
    if (TID > N) return;

    // Compute the perplexity for this point
    float entropy = 0.0f; 
    for (int i = 0; i < N; i++) {
        if (i != TID) {
            entropy += pij[i + TID*N]*log2(pij[i + TID*N]);
        }
    }
    perplexity[TID] = pow(2,-1.0*entropy);

    if (perplexity[TID] < target_perplexity) {
        upper_bound[TID] = sigmas[TID];
        
    } else {
        lower_bound[TID] = sigmas[TID];
    }
    sigmas[TID] = (upper_bound[TID] + lower_bound[TID])/2.0f;
}

__global__ void upper_lower_assign(float * __restrict__ sigmas,
                                    float * __restrict__ lower_bound,
                                    float * __restrict__ upper_bound,
                                    const float * __restrict__ perplexity,
                                    const float target_perplexity,
                                    const unsigned int N)
{
    int TID = threadIdx.x + blockIdx.x * blockDim.x;
    if (TID > N) return;

    if (perplexity[TID] > target_perplexity)
        upper_bound[TID] = sigmas[TID];
    else
        lower_bound[TID] = sigmas[TID];
    sigmas[TID] = (upper_bound[TID] + lower_bound[TID])/2.0f;
}

void thrust_search_perplexity(cublasHandle_t &handle,
                        thrust::device_vector<float> &sigmas,
                        thrust::device_vector<float> &lower_bound,
                        thrust::device_vector<float> &upper_bound,
                        thrust::device_vector<float> &perplexity,
                        const thrust::device_vector<float> &pij,
                        const float target_perplexity,
                        const unsigned int N)
{
    // std::cout << "pij:" << std::endl;
    // printarray(pij, N, N);
    // std::cout << std::endl;
    thrust::device_vector<float> entropy_(pij.size());
    thrust::transform(pij.begin(), pij.end(), entropy_.begin(), func_entropy_kernel());
    zero_diagonal(entropy_, N);

    // std::cout << "entropy:" << std::endl;
    // printarray(entropy_, N, N);
    // std::cout << std::endl;

    auto neg_entropy = Reduce::reduce_alpha(handle, entropy_, N, N, -1.0f, 1);

    // std::cout << "neg_entropy:" << std::endl;
    // printarray(neg_entropy, 1, N);
    // std::cout << std::endl;
    thrust::transform(neg_entropy.begin(), neg_entropy.end(), perplexity.begin(), func_pow2());
    // std::cout << "perplexity:" << std::endl;
    // printarray(perplexity, 1, N);
    // std::cout << std::endl;
    
    const unsigned int BLOCKSIZE = 32;
    const unsigned int NBLOCKS = iDivUp(N, BLOCKSIZE);
    upper_lower_assign<<<NBLOCKS,BLOCKSIZE>>>(thrust::raw_pointer_cast(sigmas.data()),
                                                thrust::raw_pointer_cast(lower_bound.data()),
                                                thrust::raw_pointer_cast(upper_bound.data()),
                                                thrust::raw_pointer_cast(perplexity.data()),
                                                target_perplexity,
                                                N);
    // std::cout << "sigmas" << std::endl;
    // printarray(sigmas, 1, N);
    // std::cout << std::endl;

}
thrust::device_vector<float> NaiveTSNE::compute_pij(cublasHandle_t &handle, 
                                         thrust::device_vector<float> &points, 
                                         thrust::device_vector<float> &sigma, 
                                         const unsigned int N, 
                                         const unsigned int NDIMS) 
{
    thrust::device_vector<float> pij_vals(N * N);
    Distance::squared_pairwise_dist(handle, pij_vals, points, N, NDIMS);

    // std::cout << "Sigma:" << std::endl;
    // printarray(sigma, N, 1);
    thrust::device_vector<float> sigma_squared(sigma.size());
    Math::square(sigma, sigma_squared);


    // std::cout << std::endl << std::endl << "Sigma Squared:" << std::endl;
    // printarray(sigma_squared, 1, N);
    
    // divide column by sigmas (matrix[i,:] gets divided by sigma_i^2)

    // std::cout << std::endl << std::endl << "PW-SQ dist:" << std::endl;
    // printarray(pij_vals, N, N);

    Broadcast::broadcast_matrix_vector(pij_vals, sigma_squared, N, N, thrust::divides<float>(), 0, -2.0f);

    // std::cout << std::endl << std::endl << "PW-SQ dist/-2sigma^2:" << std::endl;
    // printarray(pij_vals, N, N);

    thrust::transform(pij_vals.begin(), pij_vals.end(), pij_vals.begin(), func_exp());

    // std::cout << std::endl << std::endl << "Exp of prev..." << std::endl;
    // printarray(pij_vals, N, N);

    zero_diagonal(pij_vals, N);

    // std::cout << std::endl << std::endl << "Zeroed diagonals" << std::endl;
    // printarray(pij_vals, N, N);
    
    // Reduce::reduce_sum over cols
    auto sums = Reduce::reduce_sum(handle, pij_vals, N, N, 1);

    // std::cout << std::endl << std::endl << "Sums" << std::endl;
    // printarray(sums, 1, N);

    // divide column by resulting vector
    Broadcast::broadcast_matrix_vector(pij_vals, sums, N, N, thrust::divides<float>(), 0, 1.0f);

    // std::cout << std::endl << std::endl << "Normalized Cols" << std::endl;
    // printarray(pij_vals, N, N);

    // Do a symmetrization of the distribution
    float alpha = 0.5f;
    float beta = 0.5f;
    thrust::device_vector<float> pij_output(N*N);
    cublasSafeCall(cublasSgeam(handle, CUBLAS_OP_N, CUBLAS_OP_T, N, N, &alpha, thrust::raw_pointer_cast(pij_vals.data()), N, 
                               &beta, thrust::raw_pointer_cast(pij_vals.data()), N, thrust::raw_pointer_cast(pij_output.data()), N));

    // std::cout << std::endl << std::endl << "Final Output" << std::endl;
    // printarray(pij_output, N, N);
    
    return pij_output;
}

/**
  * Gradient formula from http://www.jmlr.org/papers/volume9/vandermaaten08a/vandermaaten08a.pdf
  * 
  * Given by ->
  *     forces_i = 4 * \sum_j (pij - qij)(yi - yj)(1 + ||y_i - y_j||^2)^-1
  * 
  * Notation below - in comments, actual variables in the code are referred to by <varname>_ to differentiate from the mathematical quantities
  *                     It's hard to name variables correctly because we don't want to keep allocating more memory. There's probably a better solution than this though.
  */
float NaiveTSNE::compute_gradients(cublasHandle_t &handle, 
                        thrust::device_vector<float> &forces,
                        thrust::device_vector<float> &dist, 
                        thrust::device_vector<float> &ys, 
                        thrust::device_vector<float> &pij, 
                        thrust::device_vector<float> &qij, 
                        const unsigned int N,
                        const unsigned int PROJDIM,
                        float eta) 
{
    // dist_ = ||y_i - y_j||^2
    Distance::squared_pairwise_dist(handle, dist, ys, N, PROJDIM);

    // std::cout << std::endl << std::endl << "Dist" << std::endl;
    // printarray(dist, N, N);

    // dist_ = (1 + ||y_i - y_j||^2)^-1
    thrust::transform(dist.begin(), dist.end(), dist.begin(), func_inc_inv());
    zero_diagonal(dist, N);

    // std::cout << std::endl << std::endl << "Inc-Inv Dist" << std::endl;
    // printarray(dist, N, N);

    // qij_ = (1 + ||y_i - y_j||^2)^-1 / \Sum_{k != i} (1 + ||y_i - y_k||^2)^-1
    float sum = thrust::reduce(dist.begin(), dist.end(), 0.0f, thrust::plus<float>());
    thrust::transform(dist.begin(), dist.end(), thrust::make_constant_iterator<float>(sum), qij.begin(), thrust::divides<float>());

    // auto sums = Reduce::reduce_sum(handle, qij, N, N, 1);

    // std::cout << std::endl << std::endl << "Sum-Dist" << std::endl;
    // printarray(sums, 1, N);

    // Broadcast::broadcast_matrix_vector(qij, sums, N, N, thrust::divides<float>(), 0, 1.0f);

    // std::cout << std::endl << std::endl << "Qij" << std::endl;
    // printarray(qij, N, N);

    // Compute loss = \sum_ij pij * log(pij / qij)
    thrust::device_vector<float> loss_(N * N);
    thrust::transform(pij.begin(), pij.end(), qij.begin(), loss_.begin(), func_kl());
    zero_diagonal(loss_, N);

    // printarray(loss_, N, N);
    float loss = thrust::reduce(loss_.begin(), loss_.end(), 0.0f, thrust::plus<float>());

    // qij_ = pij - qij
    thrust::transform(pij.begin(), pij.end(), qij.begin(), qij.begin(), thrust::minus<float>());

    // std::cout << std::endl << std::endl << "Pij-Qij" << std::endl;
    // printarray(qij, N, N);

    // qij_ = (pij - qij)(1 + ||y_i - y_j||^2)^-1
    thrust::transform(qij.begin(), qij.end(), dist.begin(), qij.begin(), thrust::multiplies<float>());

    // std::cout << std::endl << std::endl << "A" << std::endl;
    // printarray(qij, N, N);

    // forces_ = \sum_j (pij - qij)(1 + ||y_i - y_j||^2)^-1
    float alpha = 1.0f;
    float beta = 0.0f;
    thrust::device_vector<float> ones(PROJDIM * N, 1.0f);
    cublasSafeCall(cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, N, PROJDIM, N, &alpha, 
                                thrust::raw_pointer_cast(qij.data()), N, thrust::raw_pointer_cast(ones.data()), N, &beta, 
                                thrust::raw_pointer_cast(forces.data()), N));

    // std::cout << std::endl << std::endl << "A * 1" << std::endl;
    // printarray(forces, 2, N);

    // forces_ = y_i * \sum_j (pij - qij)(1 + ||y_i - y_j||^2)^-1
    thrust::transform(forces.begin(), forces.end(), ys.begin(), forces.begin(), thrust::multiplies<float>());
    alpha = 4.0f * eta;
    beta = -4.0f * eta;
    // forces_ = 4 * y_i * \sum_j (pij - qij)(1 + ||y_i - y_j||^2)^-1 - 4 * \sum_j y_j(pij - qij)(1 + ||y_i - y_j||^2)^-1
    cublasSafeCall(cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, N, PROJDIM, N, &alpha, 
                                thrust::raw_pointer_cast(qij.data()), N, thrust::raw_pointer_cast(ys.data()), N, &beta, 
                                thrust::raw_pointer_cast(forces.data()), N));

    // std::cout << std::endl << std::endl << "Final Forces" << std::endl;
    // printarray(forces, 2, N);

    return loss;
}

thrust::device_vector<float> NaiveTSNE::tsne(cublasHandle_t &handle, 
                                        thrust::device_vector<float> &points, 
                                        const unsigned int N, 
                                        const unsigned int NDIMS,
                                        const unsigned int PROJDIM)
{
    Math::max_norm(points);

    // Choose the right sigmas
    std::cout << "Selecting sigmas to match perplexity..." << std::endl;

    //TODO: Fix perplexity search

    // float perplexity_target = 16.0f;
    // float perplexity_diff = 1;

    thrust::device_vector<float> sigmas = Random::rand_in_range(N, 0.2f, 0.4f);
    // thrust::device_vector<float> best_sigmas(N);
    // thrust::device_vector<float> perplexity(N);
    // thrust::device_vector<float> lbs(N, 0.0f);
    // thrust::device_vector<float> ubs(N, 512.0f);

    // auto pij = compute_pij(handle, points, sigmas, N, NDIMS);
    // int iters = 1;
    // float best_perplexity = 100000.0f;

    // while (perplexity_diff > 1e-4 && iters < 5000) {
    //     // printarray(perplexity,1,N);
    //     // printarray(sigmas,1,N);
    //     thrust_search_perplexity(handle, sigmas, lbs, ubs, perplexity, pij, perplexity_target, N);
    //     float perplexity_diff = abs(thrust::reduce(perplexity.begin(), perplexity.end())/((float) N) - perplexity_target);
    //     //if (iters % 500 == 0)
    //     //    printf("Current perplexity delta after %d iterations: %0.5f\n", iters, perplexity_diff);

    //     if (perplexity_diff < best_perplexity){
    //         best_perplexity = perplexity_diff;
    //         printf("!! Best perplexity found in %d iterations: %0.5f\n", iters, perplexity_diff);
    //         thrust::copy(sigmas.begin(), sigmas.end(), best_sigmas.begin());
    //     }

    //     pij = compute_pij(handle, points, sigmas, N, NDIMS);
    //     iters++;
    // } // Close perplexity search

    auto pij = NaiveTSNE::compute_pij(handle, points, sigmas, N, NDIMS);

    //std::cout << "Pij" << std::endl;
    //printarray(pij, N, N);
    
    thrust::device_vector<float> forces(N * PROJDIM);
    thrust::device_vector<float> ys = Random::random_vector(N * PROJDIM);
    
    // Momentum variables
    thrust::device_vector<float> yt_1(N * PROJDIM);
    thrust::device_vector<float> momentum(N * PROJDIM);
    float momentum_weight = 0.8f;


    //printarray(ys, N, 2);
    thrust::device_vector<float> qij(N * N);
    thrust::device_vector<float> dist(N * N);
    float eta = 1.00f;
    float loss = 0.0f;

    
    #ifdef DEBUG
        // Dump the original points
        std::ofstream dump_points_file;
        dump_points_file.open ("dump_points.txt");
        dump_points_file << N << " " << NDIMS << std::endl;
        for (int i = 0; i < N; i++) {
            for (int j = 0; j < NDIMS; j++) {
                dump_points_file << points[i + j*N] << " ";
            }
            dump_points_file << std::endl;
        }
        dump_points_file.close();
    #endif

    
    #ifdef DEBUG
        // Create a dump file for the points
        std::ofstream dump_file;
        dump_file.open("dump_ys.txt");
        float host_ys[N * PROJDIM];
        dump_file << N << " " << PROJDIM << std::endl;
    #endif

    for (int i = 0; i < 5000; i++) {
        loss = NaiveTSNE::compute_gradients(handle, forces, dist, ys, pij, qij, N, PROJDIM, eta);
        
        // Compute the momentum
        thrust::transform(ys.begin(), ys.end(), yt_1.begin(), momentum.begin(), thrust::minus<float>());
        thrust::transform(momentum.begin(), momentum.end(), thrust::make_constant_iterator(momentum_weight), momentum.begin(), thrust::multiplies<float>() );
        thrust::copy(ys.begin(), ys.end(), yt_1.begin());

        // Apply the forces
        thrust::transform(ys.begin(), ys.end(), forces.begin(), ys.begin(), thrust::plus<float>());
        thrust::transform(ys.begin(), ys.end(), momentum.begin(), ys.begin(), thrust::plus<float>());

        //TODO: Add early termination for loss deltas
        
        if (i % 10 == 0)
            std::cout << "Iteration: " << i << ", Loss: " << loss << ", ForceMag: " << Math::norm(forces) << std::endl;

        #ifdef DEBUG
            // Dump the points
            thrust::copy(ys.begin(), ys.end(), host_ys);
            for (int i = 0; i < N; i++) {
                for (int j = 0; j < PROJDIM; j++) {
                    dump_file << host_ys[i + j*N] << " ";
                }
                dump_file << std::endl;
            }
        #endif
    }
    #ifdef DEBUG
        dump_file.close();
    #endif
    return ys;
}
