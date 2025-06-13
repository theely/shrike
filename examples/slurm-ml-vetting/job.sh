#!/bin/bash

#SBATCH --nodes=6
#SBATCH --time=0-00:15:00
#SBATCH --account=a-csstaff

#---------------------------------------------------------                                               
#Parameters
#---------------------------------------------------------

# Set the exact number of nodes required to run the job.
# You can allocate (#SBATCH --nodes=xy) more nodes than 
# required to account for non healthy ones. 
REQUIRED_NODES=6

# The application/command you would like to run on the
# vetted nodes.
MAIN_JOB_COMMAND="python -u -m torch.distributed.run --nproc_per_node=1 --nnodes ${REQUIRED_NODES} --rdzv_endpoint $(hostname):6000 --rdzv_backend c10d all_reduce_bench.py"

#---------------------------------------------------------

echo "██╗   ██╗███████╗████████╗███╗   ██╗ ██████╗ ██████╗ ███████╗"
echo "██║   ██║██╔════╝╚══██╔══╝████╗  ██║██╔═══██╗██╔══██╗██╔════╝"
echo "██║   ██║█████╗     ██║   ██╔██╗ ██║██║   ██║██║  ██║█████╗  "
echo "╚██╗ ██╔╝██╔══╝     ██║   ██║╚██╗██║██║   ██║██║  ██║██╔══╝  "
echo " ╚████╔╝ ███████╗   ██║   ██║ ╚████║╚██████╔╝██████╔╝███████╗"
echo "  ╚═══╝  ╚══════╝   ╚═╝   ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝"
                                                             

# Set-up environment and node vetting cli
WORK_DIR="vetnode-$SLURM_JOB_ID"
mkdir $WORK_DIR

# Download vetnode source code
git clone https://github.com/theely/vetnode.git $WORK_DIR
touch "./$WORK_DIR/sanity-results.txt"
cd $WORK_DIR

python3.11 -m venv .venv
source .venv/bin/activate
python -m pip --no-cache-dir install --upgrade pip
pip install --no-cache-dir -r ./requirements.txt

#Add CUDA
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/nvidia/hpc_sdk/Linux_aarch64/24.3/cuda/12.3/lib64/

#Add NCCL Libfabric support
mkdir aws-ofi-nccl
mkdir aws-ofi-nccl/lib
arch=$(uname -m)
curl -o ./aws-ofi-nccl/lib/libnccl-net.so https://jfrog.svc.cscs.ch/artifactory/aws-ofi-nccl-gen-dev/v1.14.1-cae0941/${arch}/SLES/15.5/cuda12/lib/libnccl-net.so
export PATH_PLUGIN=$(pwd)/aws-ofi-nccl

# Activate AWS NCCL plugin
export LD_LIBRARY_PATH=/opt/nvidia/hpc_sdk/Linux_aarch64/24.3/cuda/12.3/lib64/:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/opt/cray/libfabric/1.22.0/lib64/:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=$PATH_PLUGIN/lib/:$LD_LIBRARY_PATH
export LD_PRELOAD=$PATH_PLUGIN/lib/libnccl-net.so 

# Official flags https://eth-cscs.github.io/cscs-docs/software/communication/nccl/
#export NCCL_NET_PLUGIN="ofi"  # with uenv export NCCL_NET="AWS Libfabric"
export NCCL_NET_GDR_LEVEL="PHB"
export FI_CXI_DEFAULT_CQ_SIZE=131072
export FI_CXI_DEFAULT_TX_SIZE=32768
export FI_CXI_DISABLE_HOST_REGISTER=1
export FI_CXI_RX_MATCH_MODE=software
export FI_MR_CACHE_MONITOR="userfaultfd"
export MPICH_GPU_SUPPORT_ENABLED=0

# Other flags 
# export CXI_FORK_SAFE="1"
# export CXI_FORK_SAFE_HP="1"
export FI_CXI_DISABLE_CQ_HUGETLB="1"
export NCCL_CROSS_NIC="1"
export NCCL_DEBUG="Error"

ld $LD_PRELOAD
if [[ $? -ne 0 ]]
then
    echo "Job aborted!"
    echo "Reason: unable to load aws-ofi-nccl plugin"
    exit $?
fi

#Run vetting from src code
cd src

#Setup node vetting on main node
python -m vetnode setup ../examples/slurm-ml-vetting/config.yaml &>> ../results.txt

# Run nodes vetting
srun --nodes=6 --tasks-per-node=1 --kill-on-bad-exit=0 python -m vetnode diagnose ../examples/slurm-ml-vetting/config.yaml &>> ../results.txt

#back to root folder
cd ..

# Extract node lists
grep '^Cordon:' ./results.txt | awk '{print $2}' > ./cordoned-nodes.txt
grep '^Vetted:' ./results.txt | awk '{print $2}' > ./vetted-nodes.txt

#Run on healthy nodes only
if [ $(wc -l < ./vetted-nodes.txt) -ge $REQUIRED_NODES ]; then
    
    pip install torch --index-url https://download.pytorch.org/whl/cu126
    curl -o all_reduce_bench.py https://raw.githubusercontent.com/theely/vetnode/refs/heads/main/examples/slurm-ml-vetting/all_reduce_bench.py
    

    EXCLUDE_ARG=""
    if [[ -s cordoned-nodes.txt ]]; then
        EXCLUDE_ARG="--exclude=./cordoned-nodes.txt"
    fi

    srun -N $REQUIRED_NODES $EXCLUDE_ARG --tasks-per-node=1 $MAIN_JOB_COMMAND

else
    echo "Job aborted!"
    echo "Reason: too few vetted nodes."
fi
