#ifdef GPU_ENABLED
#include "GridGPUFluidKernel.h"
#include "GPUHelper.h"
#include <thrust/device_ptr.h>
#include <thrust/device_vector.h>
#include <thrust/sort.h>
#include <thrust/unique.h>
#include <thrust/pair.h>
#include <thrust/execution_policy.h>

#define GRID_ART_PRESSURE 1
#define GRID_VORTICITY 1

const int kgrid_BLOCKSIZE_1D = 512;
const int kgrid_BLOCKSIZE_REDUCED = 256;
const int kgrid_NUM_NEIGHBORS = 5;
const int kgrid_MAX_CELL_SIZE = 20;

const scalar kgrid_EPS = 0.001;

const scalar kgrid_RELAXATION = 0.01;

// artificial pressure constants
const scalar kgrid_DELTA_Q_SCALE = 0.1;
const scalar kgrid_ART_PRESSURE_K = 0.1;
const scalar kgrid_ART_PRESSURE_N = 6;

// XSPH constants
const scalar kgrid_XSPH_C = 0.01;
const scalar kgrid_VORTICITY_EPS = 0.01;

bool grid_deviceHappy = true;

// fluid characteristics
__constant__ scalar c_h;

// grid bounds
__constant__ scalar c_minX;
__constant__ scalar c_maxX;
__constant__ scalar c_minY;
__constant__ scalar c_maxY;
__constant__ scalar c_minZ;
__constant__ scalar c_maxZ;
__constant__ scalar c_eps;

// grid size
__constant__ int c_gridSizeX;
__constant__ int c_gridSizeY;
__constant__ int c_gridSizeZ;

///////////////////////////////////////////////
/// Function Headers
///////////////////////////////////////////////

// kernel functions
__device__ scalar kgrid_Poly6Kernel(Vector3s &pi, Vector3s &pj, scalar h);
__device__ Vector3s kgrid_SpikyKernelGrad(Vector3s &pi, Vector3s &pj, scalar h);

// gradient functions
__device__ Vector3s kgrid_calcGradConstraint(Vector3s& pi, Vector3s& pj, scalar p0, scalar h);
__device__ Vector3s kgrid_calcGradConstraintAtI(Vector3s &pi,
                                                Vector3s* neighbor_ppos, int neighbor_count,
                                                scalar p0, scalar h);

// helper functions for getting grid indices
__device__ void kgrid_getGridLocation(Vector3s pos, int &i, int &j, int &k);
__device__ int kgrid_getGridIndex(int i, int j, int k);
__device__ void kgrid_getGridLocationFromIndex(int id, int &i, int &j, int &k);

// helper function for getting grid size
__host__ void hgrid_getGridSize(FluidBoundingBox* fbox, scalar h,
                               int &gridSizeX, int &gridSizeY, int &gridSizeZ);

// helper function for getting k nearest neighbors
__host__ void hgrid_findKNearestNeighbors(int **g_neighbors, int **g_gridIndex,
                                          int **g_grid,
                                          grid_gpu_block_t **g_particles,
                                          int num_particles,
                                          scalar h,
                                          int grid_size);

__device__ Vector3s kgrid_getFluidVolumePosition(FluidVolume& volume, int k);

__global__ void kgrid_initializePositions(grid_gpu_block_t *g_particles, FluidVolume* g_volumes,
                                     int num_particles, int num_volumes);
__global__ void kgrid_updateVBO(float* vbo, grid_gpu_block_t *g_particles, int num_particles);


// apply forces
__global__ void kgrid_applyForces(grid_gpu_block_t *g_particles,
                                  int num_particles,
                                  Vector3s accumForce,
                                  scalar mass,
                                  scalar dt);

// clear grid
__global__ void kgrid_clearGrid(int *g_grid, int grid_size);

// get grid indices
__global__ void kgrid_getGridIndices(grid_gpu_block_t *g_particles,
                                     int num_particles,
                                     int *g_gridIndex);

// get grid cells
__global__ void kgrid_setGridCells(int *g_gridIndex,
                                   int num_particles,
                                   int *g_grid,
                                   int num_cells);

// find k nearest neighbors
__global__ void kgrid_findKNearestNeighbors(grid_gpu_block_t *g_particles,
                                            int num_particles,
                                            int *g_neighbors,
                                            int *g_gridIndex,
                                            int *g_grid,
                                            int num_cells,
                                            scalar h);

// calculate lambda
__global__ void kgrid_calculateLambda(grid_gpu_block_t *g_particles,
                                      int num_particles,
                                      int *g_neighbors,
                                      scalar mass,
                                      scalar h,
                                      scalar p0);

// calculate dpos
__global__ void kgrid_calculateDPos(grid_gpu_block_t *g_particles,
                                    int num_particles,
                                    int *g_neighbors,
                                    scalar h, scalar p0);

// preserve fluid boundary
__global__ void kgrid_preserveFluidBoundary(grid_gpu_block_t *g_particles,
                                            int num_particles);

// update ppos
__global__ void kgrid_updatePPos(grid_gpu_block_t *g_particles,
                                 int num_particles);


// update velocity
__global__ void kgrid_updateVelocity(grid_gpu_block_t *g_particles,
                                     int num_particles,
                                     scalar dt);

// apply xsph and viscosity
__global__ void kgrid_applyXSPHAndOmega(grid_gpu_block_t *g_particles,
                                        int num_particles,
                                        int *g_neighbors,
                                        scalar h);

// apply vorticity
__global__ void kgrid_applyVorticity(grid_gpu_block_t *g_particles,
                                     int num_particles,
                                     int *g_neighbors,
                                     scalar h);

// update position
__global__ void kgrid_updatePosition(grid_gpu_block_t *g_particles,
                                     int num_particles);

// Nearest Neighbor kernels
__global__ void kgrid_clearGrid(int *grid, int grid_size);


////////////////////////////////////////////////
/// Implementation
////////////////////////////////////////////////

/// Init fluid

void grid_initGPUFluid(int **g_neighbors, int **g_gridIndex,
                       int **g_grid,
                       grid_gpu_block_t **g_particles,
                       FluidVolume* h_volumes, int num_volumes,
                       FluidBoundingBox* h_boundingBox,
                       scalar h) {

    int num_particles = 0;
    for (int i=0; i<num_volumes; i++) {
        num_particles += h_volumes[i].m_numParticles;
    }

    // initialize volumes array (free afterward)
    FluidVolume* g_volumes;
    GPU_CHECKERROR(cudaMalloc((void **)&g_volumes,
                              sizeof(FluidVolume)*num_volumes));
    // printf("%f, %f; %f, %f; %f, %f\n", h_volumes[0].m_minX, h_volumes[0].m_maxX, h_volumes[0].m_minY, h_volumes[0].m_maxY, h_volumes[0].m_minZ, h_volumes[0].m_maxZ); 

    GPU_CHECKERROR(cudaMemcpy((void *)g_volumes, (void *)h_volumes,
                              sizeof(FluidVolume)*num_volumes,
                              cudaMemcpyHostToDevice));

    // allocate particles
    GPU_CHECKERROR(cudaMalloc((void **)g_particles,
                              sizeof(grid_gpu_block_t)*num_particles));

    // allocate neighbors array (num_particles * num_neighbors * int)
    GPU_CHECKERROR(cudaMalloc((void **)g_neighbors,
                              sizeof(int)*num_particles*kgrid_NUM_NEIGHBORS));

    // allocate grid index array (num_particles * int)
    GPU_CHECKERROR(cudaMalloc((void **)g_gridIndex,
                              sizeof(int)*num_particles));


    int gridSize = ceil(num_particles / (kgrid_BLOCKSIZE_1D*1.0));
    kgrid_initializePositions <<< gridSize, kgrid_BLOCKSIZE_1D
                              >>> (*g_particles, g_volumes, num_particles, num_volumes);
    GPU_CHECKERROR(cudaGetLastError());

    //setup bounding box constants
    scalar h_minX = h_boundingBox->minX();
    scalar h_maxX = h_boundingBox->maxX();
    scalar h_minY = h_boundingBox->minY();
    scalar h_maxY = h_boundingBox->maxY();
    scalar h_minZ = h_boundingBox->minZ();
    scalar h_maxZ = h_boundingBox->maxZ();

    GPU_CHECKERROR(cudaMemcpyToSymbol(c_minX, &h_minX,
                                      sizeof(scalar)));
    GPU_CHECKERROR(cudaMemcpyToSymbol(c_maxX, &h_maxX,
                                      sizeof(scalar)));
    GPU_CHECKERROR(cudaMemcpyToSymbol(c_minY, &h_minY,
                                      sizeof(scalar)));
    GPU_CHECKERROR(cudaMemcpyToSymbol(c_maxY, &h_maxY,
                                      sizeof(scalar)));
    GPU_CHECKERROR(cudaMemcpyToSymbol(c_minZ, &h_minZ,
                                      sizeof(scalar)));
    GPU_CHECKERROR(cudaMemcpyToSymbol(c_maxZ, &h_maxZ,
                                      sizeof(scalar)));

    // figure out dimensions of grid
    int gridSizeX, gridSizeY, gridSizeZ;
    hgrid_getGridSize(h_boundingBox, h, gridSizeX, gridSizeY, gridSizeZ);

    GPU_CHECKERROR(cudaMemcpyToSymbol(c_gridSizeX, &gridSizeX,
                                      sizeof(int)));
    GPU_CHECKERROR(cudaMemcpyToSymbol(c_gridSizeY, &gridSizeY,
                                      sizeof(int)));
    GPU_CHECKERROR(cudaMemcpyToSymbol(c_gridSizeZ, &gridSizeZ,
                                      sizeof(int)));
    GPU_CHECKERROR(cudaMemcpyToSymbol(c_h, &h,
                                      sizeof(scalar)));

    // allocate grid
    GPU_CHECKERROR(cudaMalloc((void **)g_grid,
                              sizeof(int)*gridSizeX*gridSizeY*gridSizeZ));

    GPU_CHECKERROR(cudaThreadSynchronize());

    cudaFree(g_volumes); // we don't use this anymore
}

__global__ void kgrid_initializePositions(grid_gpu_block_t *g_particles, FluidVolume* g_volumes,
                                     int num_particles, int num_volumes) {

    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid >= num_particles)
        return;

    int volume_index = -1;
    int offset = 0;
    int volume_size = 0;
    do {
        volume_index++;
        offset += volume_size;
        volume_size = g_volumes[volume_index].m_numParticles;
    } while (offset + volume_size < gid);

    FluidVolume& volume = g_volumes[volume_index];

    g_particles[gid].pos = kgrid_getFluidVolumePosition(volume, gid - offset);
    g_particles[gid].vec1 = Vector3s(0, 0, 0); // velocity
    g_particles[gid].vec3 = Vector3s(0,0,0); //ext-force

    // load colors
    g_particles[gid].r = volume.m_color.r * 255.0f;
    g_particles[gid].g = volume.m_color.g * 255.0f;
    g_particles[gid].b = volume.m_color.b * 255.0f;
    g_particles[gid].a = volume.m_color.a * 255.0f;

    g_particles[gid].num_neighbors = 0;
}

/// Update VBO

void grid_updateVBO(float *vboptr, grid_gpu_block_t *g_particles, int num_particles) {

    if (vboptr == NULL) {
        printf("oh no!!\n");
    }
    int gridSize = ceil(num_particles / (kgrid_BLOCKSIZE_1D*1.0));
    kgrid_updateVBO <<< gridSize, kgrid_BLOCKSIZE_1D
                    >>> (vboptr, g_particles, num_particles);

    cudaError_t err = cudaGetLastError();
    if(err != cudaSuccess){
        grid_deviceHappy = false;
        fprintf(stderr, "%s in %s at line %d\n", cudaGetErrorString(err), __FILE__, __LINE__);
        std::cout << "vboptr: " << vboptr << std::endl;
        return;
    }
    else {
        grid_deviceHappy = true;
    }

    GPU_CHECKERROR(cudaDeviceSynchronize());
}

__global__ void kgrid_updateVBO(float* vbo, grid_gpu_block_t *g_particles, int num_particles) {

    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid < num_particles) {
    //if(gid < 10){
        grid_gpu_block_t my_particle = g_particles[gid];
        vbo[gid*4+0] = my_particle.pos.x;
        vbo[gid*4+1] = my_particle.pos.y;
        vbo[gid*4+2] = my_particle.pos.z;
        char *colors = (char *)&vbo[gid*4+3];
        scalar depth = (my_particle.pos.y - c_minY) / (c_maxY - c_minY);
        scalar num_neighbors = my_particle.num_neighbors;
        num_neighbors = kgrid_MAX_CELL_SIZE - num_neighbors - 10; // 5 to 0
        if (num_neighbors < 0) num_neighbors = 0;
        num_neighbors /= kgrid_MAX_CELL_SIZE - 10; // 1 to 0
        colors[0] = (char)(9 + (num_neighbors * (65-9)));
        colors[1] = (char)(24 + (num_neighbors * (191-24)));
        colors[2] = (char)(84 + (num_neighbors * (229-84)));
        colors[3] = (char)178;
    }
}

/// Step function

void grid_stepFluid(int **g_neighbors, int **g_gridIndex,
                    int **g_grid,
                    grid_gpu_block_t **g_particles,
                    int num_particles,
                    FluidBoundingBox* h_boundingBox,
                    int iters,
                    scalar mass,
                    scalar h,
                    scalar p0,
                    Vector3s accumForce,
                    scalar dt) {


    int gridSizeX, gridSizeY, gridSizeZ;
    hgrid_getGridSize(h_boundingBox, h, gridSizeX, gridSizeY, gridSizeZ);
    int grid_size = gridSizeX*gridSizeY*gridSizeZ;

    int blocksPerParticles = ceil(num_particles / (kgrid_BLOCKSIZE_1D*1.0));
    int blocksPerGridCells = ceil(grid_size / (kgrid_BLOCKSIZE_1D*1.0));
    int blocksPerPartReduced = ceil(num_particles / (kgrid_BLOCKSIZE_REDUCED*1.0));

    // step 1: apply forces, predict position
    kgrid_applyForces <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                      >>> (*g_particles, num_particles, accumForce, mass, dt);
    GPU_CHECKERROR(cudaGetLastError());

    // step 2: find k nearest neighbors
    hgrid_findKNearestNeighbors(g_neighbors, g_gridIndex,
                                g_grid,
                                g_particles,
                                num_particles,
                                h,
                                grid_size);
    GPU_CHECKERROR(cudaGetLastError());

    for (int i = 0; i< iters; i++) {

        // step 3: calculate lambda
        size_t lambda_shared_bytes = sizeof(Vector3s) * kgrid_NUM_NEIGHBORS * kgrid_BLOCKSIZE_1D;
        kgrid_calculateLambda <<< blocksPerParticles, kgrid_BLOCKSIZE_1D, lambda_shared_bytes
                              >>> (*g_particles, num_particles,
                                   *g_neighbors, mass, h, p0);
        GPU_CHECKERROR(cudaGetLastError());

        // step 4: calculate dpos
        kgrid_calculateDPos <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                            >>> (*g_particles, num_particles,
                                 *g_neighbors, h, p0);
        GPU_CHECKERROR(cudaGetLastError());

        // step 5: preserve fluid boundary
        kgrid_preserveFluidBoundary <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                                    >>> (*g_particles, num_particles);

        GPU_CHECKERROR(cudaGetLastError());

        // step 6: update ppos
        kgrid_updatePPos <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                         >>> (*g_particles, num_particles);
        GPU_CHECKERROR(cudaGetLastError());

    }


    // step 7: update velocity
    kgrid_updateVelocity <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                      >>> (*g_particles, num_particles, dt);
    GPU_CHECKERROR(cudaGetLastError());


    // step 8a: apply XSPH and set omega
    kgrid_applyXSPHAndOmega <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                            >>> (*g_particles, num_particles,
                                 *g_neighbors, h);
    GPU_CHECKERROR(cudaGetLastError());


    // step 8b: apply vorticity
    kgrid_applyVorticity <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                         >>> (*g_particles, num_particles,
                              *g_neighbors, h);
    GPU_CHECKERROR(cudaGetLastError());


    // step 9: update position
    kgrid_updatePosition <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                      >>> (*g_particles, num_particles);
    GPU_CHECKERROR(cudaGetLastError());


    GPU_CHECKERROR(cudaDeviceSynchronize());
}

// find k nearest neighbors

__host__ void hgrid_findKNearestNeighbors(int **g_neighbors, int **g_gridIndex,
                                          int **g_grid,
                                          grid_gpu_block_t **g_particles,
                                          int num_particles,
                                          scalar h,
                                          int grid_size) {
    int blocksPerParticles = ceil(num_particles / (kgrid_BLOCKSIZE_1D*1.0));
    int blocksPerGridCells = ceil(grid_size / (kgrid_BLOCKSIZE_1D*1.0));
    int blocksPerPartReduced = ceil(num_particles / (kgrid_BLOCKSIZE_REDUCED*1.0));

    // step 2a: reset grid
    kgrid_clearGrid <<< blocksPerGridCells, kgrid_BLOCKSIZE_1D
                    >>> (*g_grid, grid_size);
    GPU_CHECKERROR(cudaGetLastError());

    // step 2b: get gridIDs
    kgrid_getGridIndices <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                         >>> (*g_particles, num_particles, *g_gridIndex);
    GPU_CHECKERROR(cudaGetLastError());

    // step 2c: sort particles by gridID
    thrust::device_ptr<int> t_gridIndex = thrust::device_pointer_cast(*g_gridIndex);
    thrust::device_ptr<grid_gpu_block_t> t_particles =
        thrust::device_pointer_cast(*g_particles);

    thrust::sort_by_key(t_gridIndex, t_gridIndex+num_particles, t_particles);
    GPU_CHECKERROR(cudaGetLastError());

    // step 2d: set grid cells
    kgrid_setGridCells <<< blocksPerParticles, kgrid_BLOCKSIZE_1D
                       >>> (*g_gridIndex, num_particles, *g_grid, grid_size);
    GPU_CHECKERROR(cudaGetLastError());


    // step 2f: find k nearest neighbors

    assert(sizeof(int) == sizeof(float));
    size_t knn_shared_bytes = sizeof(int) * kgrid_MAX_CELL_SIZE * kgrid_BLOCKSIZE_REDUCED * 2;
    kgrid_findKNearestNeighbors <<< blocksPerPartReduced, kgrid_BLOCKSIZE_REDUCED, knn_shared_bytes
                                >>> (*g_particles, num_particles, *g_neighbors,
                                     *g_gridIndex, *g_grid, grid_size, h);
    GPU_CHECKERROR(cudaGetLastError());
}

/// Apply Forces

__global__ void kgrid_applyForces(grid_gpu_block_t *g_particles,
                                  int num_particles,
                                  Vector3s accumForce,
                                  scalar mass,
                                  scalar dt) {
    int id = blockIdx.x * blockDim.x + threadIdx.x;
    if (id < num_particles) {
        Vector3s pos = g_particles[id].pos;
        Vector3s vel = g_particles[id].vec1;
        Vector3s ext_force = g_particles[id].vec3;
        vel += dt * (accumForce + ext_force) / mass;
        Vector3s ppos = pos + dt * vel;
        g_particles[id].vec1 = vel; //velocity
        g_particles[id].vec2 = ppos; // predicted pos
    }
}

/// Reset Grid

__global__ void kgrid_clearGrid(int *g_grid, int grid_size) {
    int id = blockIdx.x * blockDim.x + threadIdx.x;
    if (id < grid_size) {
        g_grid[id] = -1; // indicates no particle
    }
}

/// Get Grid Indices

__global__ void kgrid_getGridIndices(grid_gpu_block_t *g_particles,
                                     int num_particles,
                                     int *g_gridIndex) {
    int id = blockIdx.x * blockDim.x + threadIdx.x;
    if (id < num_particles) {
        Vector3s pos = g_particles[id].pos;
        int i, j, k;
        kgrid_getGridLocation(pos, i, j, k);
        int index = kgrid_getGridIndex(i, j, k);
        g_gridIndex[id] = index;
    }
}

/// Set grid cells

__global__ void kgrid_setGridCells(int *g_gridIndex,
                                   int num_particles,
                                   int *g_grid,
                                   int num_cells) {
    int id = blockIdx.x * blockDim.x + threadIdx.x;
    if (id < num_particles) {
        int gridCell = g_gridIndex[id];
        if (id == 0) {
            g_grid[gridCell] = id;
        }
        else if (gridCell != g_gridIndex[id - 1]) {
            if (gridCell < 0 || num_cells <= gridCell) {
                return;
            }
            g_grid[gridCell] = id;
        }
    }
}

/// find k nearest neighbors (by particle)
/// shared memory size: max_cell_size * 2 * blockSize * sizeof(int)
__global__ void kgrid_findKNearestNeighbors(grid_gpu_block_t *g_particles,
                                            int num_particles,
                                            int *g_neighbors,
                                            int *g_gridIndex,
                                            int *g_grid,
                                            int num_cells,
                                            scalar h) {
    extern __shared__ int s_mem[]; // 32 bits for both float and int

    const int array_size = kgrid_MAX_CELL_SIZE * 2;
    const int thread_offset = array_size * threadIdx.x;
    const int local_offset = kgrid_MAX_CELL_SIZE;

    int* s_particles = s_mem + thread_offset;
    float* s_distances = (float*)(s_particles + local_offset);

    // int s_particles[kgrid_MAX_CELL_SIZE];
    // float s_distances[kgrid_MAX_CELL_SIZE];

    int particle_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (particle_id >= num_particles)
        return;

    // if (particle_id != 0)
        // return;

    Vector3s pos = g_particles[particle_id].vec2;
    int grid_index = g_gridIndex[particle_id];
    int i, j, k;
    kgrid_getGridLocationFromIndex(grid_index, i, j, k);

    int num_candidates = 0;
    for (int cur_i = i-1; cur_i <= i+1; cur_i++) {
        for (int cur_j = j-1; cur_j <= j+1; cur_j++) {
            for (int cur_k = k-1; cur_k <= k+1; cur_k++) {

                if (cur_i < 0 || cur_i >= c_gridSizeX)
                    continue;
                if (cur_j < 0 || cur_j >= c_gridSizeY)
                    continue;
                if (cur_k < 0 || cur_k >= c_gridSizeZ)
                    continue;
                if (num_candidates >= kgrid_MAX_CELL_SIZE)
                    goto nearest_postloop;

                int cur_grid_index = kgrid_getGridIndex(cur_i, cur_j, cur_k);

                int first_particle_id = g_grid[cur_grid_index];
                if (first_particle_id == -1)
                    continue;

                int cur_particle_id = first_particle_id;
                Vector3s cur_pos;
                scalar dist;

                scalar maxDist = 0;
                int max = 0;

                while(cur_particle_id < num_particles &&
                      cur_grid_index == g_gridIndex[cur_particle_id]) {

                    // printf("while : %d - %d\n", particle_id, cur_particle_id);

                    if (cur_particle_id < 0 || cur_particle_id >= num_particles) {
                        printf("oh god oh god: %d - %d", particle_id, cur_particle_id);
                    }

                    cur_pos = g_particles[cur_particle_id].vec2;

                    dist = glm::length(cur_pos - pos);

                    if (dist < h) {

                        if (num_candidates >= kgrid_MAX_CELL_SIZE) {

                            // don't increment num_candidates
                            // check for maxDist
                            if (dist < maxDist) {
                                // we deserve a spot! replace id with
                                // max.
                                maxDist = dist;


                                s_particles[max] = cur_particle_id;
                                s_distances[max] = dist;

                                // recalculate maxdist
                                for (int r=0; r<kgrid_MAX_CELL_SIZE; r++) {
                                    scalar my_dist = s_distances[r];
                                    if (my_dist > maxDist) {
                                        maxDist = my_dist;
                                        max = r;
                                    }
                                }
                            }
                        }
                        else {

                            s_particles[num_candidates] = cur_particle_id;
                            s_distances[num_candidates] = dist;

                            //update max dist
                            if (dist > maxDist) {
                                maxDist = dist;
                                max = num_candidates;
                            }

                            num_candidates++;

                        }

                    }
                    cur_particle_id++;
                }

            }
        }
    }

 nearest_postloop:
    // printf("sorting!\n");

    // now that the arrays are loaded, let's sort them
    thrust::device_ptr<int> t_particles = thrust::device_pointer_cast(s_particles);
    thrust::device_ptr<float> t_distances = thrust::device_pointer_cast(s_distances);

    thrust::sort_by_key(thrust::seq, t_distances, t_distances+num_candidates,
                        t_particles);

    int *g_my_neighbors = g_neighbors + (kgrid_NUM_NEIGHBORS * particle_id);

    // take first k particles and put them in neighbors list
    // put -1 if candidates don't exist
    Vector3s delta(0,0,0);

    for (int n_i = 0; n_i < kgrid_NUM_NEIGHBORS; n_i++) {
        if (n_i < num_candidates) {
            g_my_neighbors[n_i] = s_particles[n_i];

            Vector3s other_pos = g_particles[s_particles[n_i]].vec2;
            delta += (other_pos - pos);

        }
        else {
            g_my_neighbors[n_i] = -1;
        }
    }

    delta /= num_candidates;
    delta *= 100.0f;
    g_particles[particle_id].num_neighbors = num_candidates;
}

/// calculate lambda - by particle
/// input (vec2 = ppos) --> (sca1 = lambda)
/// s_mem size: num_neighbors * block_size * size(Vector3s)
__global__ void kgrid_calculateLambda(grid_gpu_block_t *g_particles,
                                      int num_particles,
                                      int *g_neighbors,
                                      scalar mass,
                                      scalar h,
                                      scalar p0) {
    extern __shared__ Vector3s s_neighbor_ppos[];

    int particle_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (particle_id >= num_particles)
        return;

    // note that this is a copy of a struct. Don't output to this!
    grid_gpu_block_t my_particle = g_particles[particle_id];

    // copy over global memory to shared block
    // also keep track of actual neighbor count
    int neighbor_count;
    int *g_my_neighbors = g_neighbors + (kgrid_NUM_NEIGHBORS * particle_id);
    Vector3s *s_my_neighbor_ppos = &s_neighbor_ppos[kgrid_NUM_NEIGHBORS * threadIdx.x];

    //copy over data from global memory to shared memory
    for (neighbor_count=0; neighbor_count<kgrid_NUM_NEIGHBORS; neighbor_count++) {
        int neighbor_id = g_my_neighbors[neighbor_count];
        if (neighbor_id == -1)
            break;

        // copy over vec2 attribute (ppos)
        s_my_neighbor_ppos[neighbor_count] = g_particles[neighbor_id].vec2;
    }

    // get our own ppos
    Vector3s ppos = my_particle.vec2;

    scalar press = 0;
    // iterate over neighbor array

    for (int i=0; i<neighbor_count; i++) {
        Vector3s &other_ppos = s_my_neighbor_ppos[i];
        press += kgrid_Poly6Kernel(ppos, other_ppos, h);
    }
    press *= mass;
    if (neighbor_count == 0) {
        press = p0;
    }

    scalar top = (press / p0) - 1.0;

    // accumulate Ci gradients
    scalar gradSum = 0;
    scalar gradL;
    for (int i=0; i<neighbor_count; i++) {
        Vector3s &other_ppos = s_my_neighbor_ppos[i];
        gradL = glm::length(kgrid_calcGradConstraint(ppos, other_ppos, p0, h));
        gradSum = gradL*gradL;
    }
    //add self
    gradL = glm::length(kgrid_calcGradConstraintAtI(ppos,
                                                    s_my_neighbor_ppos,
                                                    neighbor_count,
                                                    p0, h));
    gradSum += gradL*gradL;
    gradSum += kgrid_RELAXATION;

    scalar lambda = -1.0f * top / gradSum;
    g_particles[particle_id].sca1 = lambda;
}

// Calculate dpos
// (vec2 = ppos, sca1 = lambda) --> (vec3 = dpos)
__global__ void kgrid_calculateDPos(grid_gpu_block_t *g_particles,
                                    int num_particles,
                                    int *g_neighbors,
                                    scalar h, scalar p0) {

    int particle_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (particle_id >= num_particles)
        return;

    // note that this is a copy of a struct. Don't output to this!
    grid_gpu_block_t my_particle = g_particles[particle_id];

    int *g_my_neighbors = g_neighbors + (kgrid_NUM_NEIGHBORS * particle_id);

    // get our own ppos and lambda
    Vector3s ppos = my_particle.vec2;
    scalar lambda = my_particle.sca1;

    Vector3s dp(0, 0, 0);
#if GRID_ART_PRESSURE == 1
    // some distance from position
    Vector3s q = kgrid_DELTA_Q_SCALE*h * glm::vec3(1.0f) + ppos;
#endif

    scalar scorr = 0;
    for (int i=0; i<kgrid_NUM_NEIGHBORS; i++) {
        int neighbor_id = g_my_neighbors[i];
        if (neighbor_id == -1)
            break;

        grid_gpu_block_t other_particle = g_particles[neighbor_id];
        Vector3s other_ppos = other_particle.vec2;
        scalar other_lambda = other_particle.sca1;

#if GRID_ART_PRESSURE == 1
        scalar top = kgrid_Poly6Kernel(ppos, other_ppos, h);
        scalar dq_kernel = kgrid_Poly6Kernel(ppos, q, h);
        scorr = -1.0f * kgrid_ART_PRESSURE_K * pow(top/dq_kernel, kgrid_ART_PRESSURE_N);
#endif
        dp += (other_lambda + lambda + scorr) * kgrid_SpikyKernelGrad(ppos, other_ppos, h);
    }

    g_particles[particle_id].vec3 = dp / p0; // delta pos mapped to vec3
}

// preserve fluid boundary
__global__ void kgrid_preserveFluidBoundary(grid_gpu_block_t *g_particles,
                                            int num_particles) {
    int particle_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (particle_id >= num_particles)
        return;

    // needless hack to randomize epsilon
    scalar shift = (particle_id%124) * 1.0 / 10000.0;

    grid_gpu_block_t my_particle = g_particles[particle_id];
    Vector3s ppos = my_particle.vec2;
    Vector3s dpos = my_particle.vec3;
    Vector3s pos = ppos + dpos;
    scalar posX = pos.x;
    scalar posY = pos.y;
    scalar posZ = pos.z;

    if (posX < c_minX)
        posX = c_minX + kgrid_EPS + shift;
    else if (posX > c_maxX)
        posX = c_maxX - kgrid_EPS - shift;
    if (posY < c_minY)
        posY = c_minY + kgrid_EPS + shift;
    else if (posY > c_maxY)
        posY = c_maxY - kgrid_EPS - shift;
    if (posZ < c_minZ)
        posZ = c_minZ + kgrid_EPS + shift;
    else if (posZ > c_maxZ)
        posZ = c_maxZ - kgrid_EPS - shift;

    g_particles[particle_id].vec3 = Vector3s(posX, posY, posZ) - ppos;
}

// update ppos
__global__ void kgrid_updatePPos(grid_gpu_block_t *g_particles,
                                 int num_particles) {
    int particle_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (particle_id >= num_particles)
        return;

    grid_gpu_block_t my_particle = g_particles[particle_id];
    Vector3s ppos = my_particle.vec2;
    Vector3s dpos = my_particle.vec3;

    ppos += dpos;

    g_particles[particle_id].vec2 = ppos;
}


/// update velocity

__global__ void kgrid_updateVelocity(grid_gpu_block_t *g_particles,
                                     int num_particles,
                                     scalar dt) {
    int id = blockIdx.x * blockDim.x + threadIdx.x;
    if (id < num_particles) {
        Vector3s pos = g_particles[id].pos; // pos
        Vector3s ppos = g_particles[id].vec2; // ppos
        Vector3s vel = (ppos - pos) / dt;
        g_particles[id].vec1 = vel; //velocity
    }
}

// apply xsph and viscosity
// (vec2 = ppos, vec1 = vel) --> (pos = vel, vec3 = omega)
__global__ void kgrid_applyXSPHAndOmega(grid_gpu_block_t *g_particles,
                                        int num_particles,
                                        int *g_neighbors,
                                        scalar h) {
    int particle_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (particle_id >= num_particles)
        return;

    grid_gpu_block_t my_particle = g_particles[particle_id];
    Vector3s vel = my_particle.vec1;
    Vector3s ppos = my_particle.vec2;

    Vector3s dv(0,0,0);
#if GRID_VORTICITY == 1
    Vector3s omega(0,0,0);
#endif
    int *g_my_neighbors = g_neighbors + (kgrid_NUM_NEIGHBORS * particle_id);

    for (int i=0; i<kgrid_NUM_NEIGHBORS; i++) {
        int neighbor_id = g_my_neighbors[i];
        if (neighbor_id == -1)
            break;

        grid_gpu_block_t other_particle = g_particles[neighbor_id];
        Vector3s other_vel = other_particle.vec1;
        Vector3s other_ppos = other_particle.vec2;
        Vector3s vij = other_vel - vel;

        dv += vij * kgrid_Poly6Kernel(ppos, other_ppos, h);
#if GRID_VORTICITY == 1
        omega += glm::cross(vij, kgrid_SpikyKernelGrad(ppos, other_ppos, h));
#endif
    }

    dv *= kgrid_XSPH_C;
    vel += dv;
    g_particles[particle_id].pos = vel;

#if GRID_VORTICITY == 1
    g_particles[particle_id].vec3 = omega;
#endif
}

// apply vorticity
// (pos = vel, vec2 = ppos, vec3 = omega) -> (vec1 = vel, vec3 = ext force?)
__global__ void kgrid_applyVorticity(grid_gpu_block_t *g_particles,
                                     int num_particles,
                                     int *g_neighbors,
                                     scalar h) {
    int particle_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (particle_id >= num_particles)
        return;

    grid_gpu_block_t my_particle = g_particles[particle_id];
    Vector3s ppos = my_particle.vec2;
    Vector3s vel = my_particle.pos;
    Vector3s omega = my_particle.vec3;

    Vector3s vort(0,0,0);
    Vector3s grad(0,0,0);

    int *g_my_neighbors = g_neighbors + (kgrid_NUM_NEIGHBORS * particle_id);

    for (int i=0; i<kgrid_NUM_NEIGHBORS; i++) {
        int neighbor_id = g_my_neighbors[i];
        if (neighbor_id == -1)
            break;

        grid_gpu_block_t other_particle = g_particles[neighbor_id];
        Vector3s other_ppos = other_particle.vec2;
        Vector3s other_vel = other_particle.pos;
        Vector3s other_omega = other_particle.vec3;

        scalar dom = glm::length(omega - other_omega);
        Vector3s dp = other_ppos - ppos;
        vort.x += dom / (dp.x+0.001);
        vort.y += dom / (dp.y+0.001);
        vort.z += dom / (dp.z+0.001);
    }

    vort /= (glm::length(vort) + kgrid_EPS);

    g_particles[particle_id].vec1 = vel;

#if GRID_VORTICITY == 1
    Vector3s ext_force = 1.0f * kgrid_VORTICITY_EPS * glm::cross(vort, omega);
    g_particles[particle_id].vec3 = ext_force;
#else
    g_particles[particle_id].vec3 = Vector3s(0,0,0);
#endif
}

/// update position

__global__ void kgrid_updatePosition(grid_gpu_block_t *g_particles,
                                     int num_particles) {
    int id = blockIdx.x * blockDim.x + threadIdx.x;
    if (id < num_particles) {
        Vector3s ppos = g_particles[id].vec2; // ppos
        g_particles[id].pos = ppos; //pos = ppos
    }

}



////////////////////////////////////////
/// Helper functions
////////////////////////////////////////

__host__ void hgrid_getGridSize(FluidBoundingBox* fbox, scalar h,
                               int &gridSizeX, int &gridSizeY, int &gridSizeZ) {
    gridSizeX = ceil(fbox->width() / h);
    gridSizeY = ceil(fbox->height() / h);
    gridSizeZ = ceil(fbox->depth() / h);
}

__device__ void kgrid_getGridLocation(Vector3s pos, int &i, int &j, int &k) {

    scalar x = pos.x;
    scalar y = pos.y;
    scalar z = pos.z;

    i = (x - c_minX) / c_h;
    j = (y - c_minY) / c_h;
    k = (z - c_minZ) / c_h;
}

__device__ int kgrid_getGridIndex(int i, int j, int k) {
    return (c_gridSizeX * c_gridSizeY * k) + (c_gridSizeX * j) + i;
}

__device__ void kgrid_getGridLocationFromIndex(int id, int &i, int &j, int &k) {
    i = id % c_gridSizeX;
    j = (id / c_gridSizeX) % c_gridSizeY;
    k = (id / c_gridSizeX / c_gridSizeY) % c_gridSizeZ;
}

__device__ Vector3s kgrid_getFluidVolumePosition(FluidVolume& volume, int k) {

    if (volume.m_mode == kFLUID_VOLUME_MODE_BOX) {

        //random mode not supported
        int xlen = (volume.m_maxX - volume.m_minX) / volume.m_dens_cbrt;
        int ylen = (volume.m_maxY - volume.m_minY) / volume.m_dens_cbrt;
        int zlen = (volume.m_maxZ - volume.m_minZ) / volume.m_dens_cbrt;

        int xindex = (k / zlen / ylen) % xlen;
        int yindex = (k / zlen) % ylen;
        int zindex = k % zlen;

        // add small epsilon to semi-randomize particles
        scalar xeps = volume.m_dens_cbrt*0.01 * ((yindex+zindex)%2);
        scalar yeps = volume.m_dens_cbrt*0.01 * ((xindex+zindex)%2);
        scalar zeps = volume.m_dens_cbrt*0.01 * ((xindex+yindex)%2);

        // printf("%f - %d, %d, %d\n", volume.m_dens_cbrt, xindex, yindex, zindex);

        scalar x = xindex * volume.m_dens_cbrt + xeps;
        scalar y = yindex * volume.m_dens_cbrt + yeps;
        scalar z = zindex * volume.m_dens_cbrt + zeps;
        return Vector3s(x, y, z);
    }
    // sphere mode not supported
    return Vector3s(0, 0, 0);
}

///kernel functions

__device__ scalar kgrid_Poly6Kernel(Vector3s& pi, Vector3s& pj, scalar H){
    scalar r = glm::distance(pi, pj);
    if(r > H || r < 0)
        return 0;

    r = ((H * H) - (r * r));
    r = r * r * r; // (h^2 - r^2)^3
    return r * (315.0 / (64.0 * PI * H * H * H * H * H * H * H * H * H));

}

__device__ Vector3s kgrid_SpikyKernelGrad(Vector3s& pi, Vector3s& pj, scalar H){
    Vector3s dp = pi - pj;
    scalar r = glm::length(dp);
    if(r > H || r < 0)
        return Vector3s(0.0, 0.0, 0.0);
    scalar scale = 45.0 / (PI * H * H * H * H * H * H) * (H - r) * (H - r);
    return scale / (r + 0.001f) * dp;
}

// gradient functions

__device__ Vector3s kgrid_calcGradConstraint(Vector3s& pi, Vector3s& pj, scalar p0, scalar h){
    return -1.0f * kgrid_SpikyKernelGrad(pi, pj, h) / p0;
}

__device__ Vector3s kgrid_calcGradConstraintAtI(Vector3s &pi,
                                                Vector3s* neighbor_ppos, int neighbor_count,
                                                scalar p0, scalar h) {
    Vector3s sumGrad(0.0, 0.0, 0.0);

    for (int i=0; i<neighbor_count; i++) {
        Vector3s other_ppos = neighbor_ppos[i];
        sumGrad += kgrid_SpikyKernelGrad(pi, other_ppos, h);
    }

    return sumGrad / p0;
}


#endif
