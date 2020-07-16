# Distributed Join Project

## Compilation

This project depends on CUDA, UCX, MPI and cuDF.

The Makefile uses `pkg-config` to determine the installation path of UCX, so make sure `ucx.pc` is in `PKG_CONFIG_PATH`.

To compile, make sure the variables `CUDA_HOME`, `CUDF_HOME`, `CUB_HOME`, `MPI_HOME` are pointing to the installation path of CUDA, cuDF, CUB and MPI, repectively.

The variable `THIRD_PARTY_HOME` should point to [this repo](https://github.com/rapidsai/thirdparty-freestanding).

To compile, run
```bash
make -j
```

## Command line arguments

`benchmark/distributed_join` accepts the following arguments.

**--key-type {int32_t,int64_t}**
Data type for the key columns. Default: `int64_t`.

**--payload-type {int32_t,int64_t}**
Data type for the payload columns. Default: `int64_t`.

**--build-table-nrows [INTEGER]**
Number of rows in the build table per GPU. Default: `100'000'000`.

**--probe-table-nrows [INTEGER]**
Number of rows in the probe table per GPU. Default: `100'000'000`.

**--selectivity [FLOAT]**
On average, how many rows in the probe table matches each row in the build table. Default: `0.3`.

**--duplicate-build-keys**
If specified, key columns of the build table are allowed to have duplicates.

**--over-decomposition-factor [INTEGER]**
Used for computation-communication overlap. `1` means no overlap. Default: `1`.

**--use-buffer-communicator**
Whether buffer communicator should be used.

## Running

To run on systems not needing Infiniband (e.g. single-node DGX-2):

```bash
UCX_MEMTYPE_CACHE=n UCX_TLS=sm,cuda_copy,cuda_ipc mpirun -n 16 --cpus-per-rank 3 benchmark/distributed_join
```

On systems needing Infiniband communication (e.g. single or multi-node DGX-1Vs):

* Make sure you are using `--use-buffer-communicator` for reusing communication buffer.
* GPU-NIC affinity is critical on systems with multiple GPUs and NICs, please refer to [this page from QUDA](https://github.com/lattice/quda/wiki/Multi-GPU-Support#maximizing-gdr-performance) for more detailed info. Also, you could modify run script included in the benchmark folder.
* Depending on whether you're running with `srun` or `mpirun`, update `run_sample.sh` to set `lrank` to `$SLURM_LOCALID` or `$OMPI_COMM_WORLD_LOCAL_RANK` correspondingly.

Example run on a single DGX-1V (all 8 GPUs):
```bash
$ mpirun -n 8 --bind-to none --mca pml ucx --mca btl ^openib,smcuda benchmark/run_sample.sh
rank 0 gpu list 0,1,2,3,4,5,6,7 cpu bind 1-4 ndev mlx5_0:1
rank 1 gpu list 0,1,2,3,4,5,6,7 cpu bind 5-8 ndev mlx5_0:1
rank 2 gpu list 0,1,2,3,4,5,6,7 cpu bind 10-13 ndev mlx5_1:1
rank 3 gpu list 0,1,2,3,4,5,6,7 cpu bind 15-18 ndev mlx5_1:1
rank 4 gpu list 0,1,2,3,4,5,6,7 cpu bind 21-24 ndev mlx5_2:1
rank 6 gpu list 0,1,2,3,4,5,6,7 cpu bind 30-33 ndev mlx5_3:1
rank 7 gpu list 0,1,2,3,4,5,6,7 cpu bind 35-38 ndev mlx5_3:1
rank 5 gpu list 0,1,2,3,4,5,6,7 cpu bind 25-28 ndev mlx5_2:1
Device count: 8
Rank 4 select 4/8 GPU
Device count: 8
Rank 5 select 5/8 GPU
Device count: 8
Rank 3 select 3/8 GPU
Device count: 8
Rank 7 select 7/8 GPU
Device count: 8
Rank 0 select 0/8 GPU
Device count: 8
Rank 1 select 1/8 GPU
Device count: 8
Rank 2 select 2/8 GPU
Device count: 8
Rank 6 select 6/8 GPU
========== Parameters ==========
Key type: int64_t
Payload type: int64_t
Number of rows in the build table: 800 million
Number of rows in the probe table: 800 million
Selectivity: 0.3
Keys in build table are unique: true
Over-decomposition factor: 1
Buffer communicator: true
================================
Elasped time (s) 0.431553
```

## File Structure

```
benchmark/
    all_to_all.cu               Benchmark the throughput of all-to-all communications.
    distributed_join.cu         Benchmark the throughput of distributed join.
src/
    topology.cuh                Initialize MPI and set CUDA devices.
    comm.cuh                    Communication related helper functions.
    communicator.cu             Different implementations for the common send/recv interface definced in the header file.
    distributed_join.cuh        Distributed join and all-to-all communication implementation.
    distribute_table.cuh        Table distribution/collection between the root rank and all worker ranks.
    error.cuh                   Error checking macros.
test/
    buffer_communicator.cu      Test the correctness of the buffer communicator.
    compare_against_shared.cu   Test the correctness of the distributed-join compared to shared-memory implementation on random tables.
    prebuild.cu                 Test the correctness of the distributed-join compared to known solution.
```
