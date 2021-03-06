#ifndef __NAIVE_GPU_FLUID_H__
#define __NAIVE_GPU_FLUID_H__

#include "MathDefs.h"
#include "FluidBoundingBox.h"
#include "FluidVolume.h"
#include "Fluid.h"
#include "gpu/NaiveGPUFluidKernel.h"

class Scene;

// Header for the naive GPU fluid
class NaiveGPUFluid : public Fluid {

public:
    NaiveGPUFluid(scalar mass, scalar p0, scalar h, int iters=2, int maxNeigh = 20, int minNeighbor = 3, bool random = true);
    NaiveGPUFluid(NaiveGPUFluid& otherFluid);
    virtual ~NaiveGPUFluid();

    virtual void stepSystem(Scene& scene, scalar dt);
    virtual void loadFluidVolumes();
    virtual void updateVBO(float* dptrvert);

private:
    scalar m_eps;
    Vector3s *d_pos;
    Vector3s *d_vel;
    Vector3s *d_ppos;
    Vector3s *d_dpos;
    Vector3s *d_omega;
    scalar *d_pcalc; 
    scalar *d_lambda;
    int *d_grid; // scene gridded into 3D buckets, store the particles inside: size (width/h)*(height/h)*(depth/h)*max_neighbors 
    int *d_gridCount; // store the number of particles per grid
    int *d_gridInd; // for each particle store the id of the grid it's in
    bool m_random; // when initializing, use grid or assign randomly?
    char *d_color; // particle colors
};
#endif
