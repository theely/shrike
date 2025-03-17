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
REQUIRED_NODES=4

# The application/command you would like to run on the
# vetted nodes.
MAIN_JOB_COMMAND=hostname
#---------------------------------------------------------

echo "███████╗ █████╗ ███╗   ██╗██╗████████╗██╗   ██╗"
echo "██╔════╝██╔══██╗████╗  ██║██║╚══██╔══╝╚██╗ ██╔╝"
echo "███████╗███████║██╔██╗ ██║██║   ██║    ╚████╔╝ "
echo "╚════██║██╔══██║██║╚██╗██║██║   ██║     ╚██╔╝  "
echo "███████║██║  ██║██║ ╚████║██║   ██║      ██║   "
echo "╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝   ╚═╝      ╚═╝   "


# Set-up environment and node vetting cli
rm -rf shrike-deploy
git clone https://github.com/theely/shrike.git shrike-deploy
cd shrike-deploy
python3.11 -m venv .venv-shrike
source .venv-shrike/bin/activate
python -m pip --no-cache-dir install --upgrade pip
pip install --no-cache-dir -r ./requirements.txt
cd src
touch sanity-results.txt

# Run nodes vettin
srun python -m shrike diagnose ../templates/simple-config.yaml >> sanity-results.txt

# Extract node lists
grep '^Cordon:' sanity-results.txt | awk '{print $2}' > cordoned-nodes.txt
grep '^Vetted:' sanity-results.txt | awk '{print $2}' > vetted-nodes.txt

#Run on healthy nodes only
if [ $(wc -l < vetted-nodes.txt) -ge $REQUIRED_NODES ]; then
    srun -N $REQUIRED_NODES --exclude=./cordoned-nodes.txt $MAIN_JOB_COMMAND
else
    echo "Job canceled!"
    echo "Rrason: too few vetted nodes."
fi
