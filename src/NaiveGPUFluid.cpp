#ifdef GPU_ENABLED
#include "NaiveGPUFluid.h"
#include "gpu/NaiveGPUFluidKernel.h"
#include "FluidSimpleGravityForce.h"
#include "Scene.h"

#include <iostream>
NaiveGPUFluid::NaiveGPUFluid(scalar mass, scalar p0, scalar h, int iters, int maxNeighbors, int minNeighbors, bool random) 
: Fluid(mass, p0, h, iters, maxNeighbors, minNeighbors)
, m_eps(0.01)
, m_random(random)
{
}

NaiveGPUFluid::NaiveGPUFluid(NaiveGPUFluid& otherFluid)
: Fluid(otherFluid)
, m_eps(0.01)
{

}

NaiveGPUFluid::~NaiveGPUFluid() {
    // clean up
    naive_cleanUp(&d_pos, &d_vel, &d_ppos, &d_dpos, &d_omega, 
                        &d_pcalc, &d_lambda, &d_grid, &d_gridCount, &d_gridInd, &d_color); 
    //free(m_colors);
}

void NaiveGPUFluid::stepSystem(Scene& scene, scalar dt) {

  Vector3s accumForce = Vector3s(0, 0, 0);

  std::vector<FluidForce*> &forces = scene.getFluidForces();
  for (std::vector<FluidForce*>::size_type i=0;
       i < forces.size(); i++) {

    FluidForce *force = forces[i];

    // check if simple gravity force
    FluidSimpleGravityForce *gravityForce = dynamic_cast<FluidSimpleGravityForce*>(force);

    if (gravityForce) {
      accumForce += gravityForce->getGlobalForce();
    }
  }

    naive_stepFluid(d_pos, d_vel, d_ppos, d_dpos, d_omega, d_pcalc, d_lambda, m_fpmass,
                      getNumParticles(), m_maxNeighbors, d_grid, d_gridCount, d_gridInd, m_iters, m_p0,  
                      m_boundingBox,
                      m_h,
                      accumForce,
                      dt);
 
    /*
  naive_stepFluid(&d_neighbors, &d_gridIndex,
                 &d_grid,
                 &d_gridUniqueIndex, &d_partUniqueIndex,
                 &d_particles,
                 getNumParticles(),
                 m_boundingBox, m_h,
                 accumForce,
                 dt);
*/

}

void NaiveGPUFluid::loadFluidVolumes() {

    FluidVolume h_volumes[m_volumes.size()];
    for (int i=0; i<m_volumes.size(); i++) {
        h_volumes[i] = m_volumes[i];
    }

    /*
    m_colors = (Vector4s *)malloc(getNumParticles() * sizeof(Vector4s)); 
    int offset = 0; 
    for (std::vector<FluidVolume>::size_type i=0; i<m_volumes.size(); i++) {
        FluidVolume& volume = m_volumes[i];
        volume.setParticleColors(m_colors, offset);
        offset += volume.m_numParticles;
    }
    */

 naive_initGPUFluid(&d_pos, &d_vel, &d_ppos, &d_dpos, &d_omega, 
                        &d_pcalc, &d_lambda, &d_grid, &d_gridCount, &d_gridInd, &d_color, m_maxNeighbors,
                        h_volumes, m_volumes.size(), m_boundingBox, m_h, m_random);

}

void NaiveGPUFluid::updateVBO(float* dptrvert) {
    naive_updateVBO(dptrvert, d_pos, d_color, getNumParticles());
}
#endif
