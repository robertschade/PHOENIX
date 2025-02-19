#include <omp.h>

// Include Cuda Kernel headers
#include "cuda/typedef.cuh"
#include "kernel/kernel_compute.cuh"
#include "system/system_parameters.hpp"
#include "cuda/cuda_matrix.cuh"
#include "solver/gpu_solver.hpp"
#include "misc/commandline_io.hpp"

/*
* Helper variable for caching the current time for FFT evaluations.
* We dont need this variable anywhere else, so we just create it
* locally to this file here.
*/
PHOENIX::Type::real fft_cached_t = 0.0;
bool first_time = true;

/**
 * Iterates the Runge-Kutta-Method on the GPU
 * Note, that all device arrays and variables have to be initialized at this point
 * @param t Current time, will be updated to t + dt
 * @param dt Time step, will be updated to the next time step
 * @param N_c Number of grid points in one dimension
 * @param N_r Number of grid points in the other dimension
 */
bool PHOENIX::Solver::iterate() {
    // First, check if the maximum time has been reached
#ifndef BENCH
    if ( system.p.t >= system.t_max )
        return false;
#endif

    // If required, calculate new set of random numbers.
    // TODO: move this back into subgrids, because for large number of subgrids this will look very correlated!
    if ( system.evaluateStochastic() ) {
        auto args = generateKernelArguments();
        auto [block_size, grid_size] = getLaunchParameters( 1, system.p.subgrid_N2_with_halo );
        if ( first_time ) {
            first_time = false;
            CALL_FULL_KERNEL( PHOENIX::Kernel::initialize_random_number_generator, "random_number_init", grid_size, block_size, 0, system.random_seed, args.dev_ptrs.random_state, system.p.subgrid_N2_with_halo );
            std::cout << PHOENIX::CLIO::prettyPrint( "Initialized Random Number Generator", PHOENIX::CLIO::Control::Info ) << std::endl;
        }
        CALL_FULL_KERNEL( PHOENIX::Kernel::generate_random_numbers, "random_number_gen", grid_size, block_size, 0, args.dev_ptrs.random_state, args.dev_ptrs.random_number, system.p.subgrid_N2_with_halo, system.p.stochastic_amplitude * std::sqrt( system.p.dt ), system.p.stochastic_amplitude * std::sqrt( system.p.dt ) );
    }
    // TODO: Hide this in a solver.updateKernelArgs function
    system.pulse.updateTemporal( system.p.t );
    system.potential.updateTemporal( system.p.t );
    system.pump.updateTemporal( system.p.t );
    // Update the time struct. This is required for variable time steps, and when the kernels need t or dt.
    Type::host_vector<Type::real> new_time = { system.p.t, system.p.dt };
    // And update the solver struct accordingly
    dev_pulse_oscillation.amp = system.pulse.temporal_envelope;
    dev_potential_oscillation.amp = system.potential.temporal_envelope;
    dev_pump_oscillation.amp = system.pump.temporal_envelope;
    time = new_time;

    // Iterate RK4(45)/ssfm/itp
    iterator[system.iterator].iterate();

    // Call the normalization for imaginary time propagation if required
    if ( system.imag_time_amplitude != 0.0 )
        normalizeImaginaryTimePropagation();

    // Increase t.
    system.p.t = system.p.t + system.p.dt;

    // For statistical purposes, increase the iteration counter
    system.iteration++;

    // FFT Guard
    if ( system.p.t - fft_cached_t < system.fft_every )
        return true;

    // Calculate the FFT
    fft_cached_t = system.p.t;
    applyFFTFilter( system.fft_mask.size() > 0 );

    return true;
}
