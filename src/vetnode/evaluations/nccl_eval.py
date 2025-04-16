
import asyncio
import datetime
import os
from typing import Literal
import numpy as np 
from pydantic import BaseModel


from vetnode.commands.scontrol.scontrol_command import ScontrolCommand
from vetnode.evaluations.base_eval import BaseEval
import torch
import torch.distributed as dist
from vetnode.evaluations.models import BandwithSize, BinaryByteSize


# following the common networking hw spec convention which uses base 10, instead of 2 for bps/Bps (it makes speed look bigger than it is)
conv_to_GBps = lambda v : v/10**9




class NCCLEvalWarmUp(BaseModel):
    payload:BinaryByteSize= '256 MB'
    runs:int= 3

class NCCLEval(BaseEval):
    name:str
    type: Literal["vetnode.evaluations.nccl_eval.NCCLEval"]
    requirements: Literal[[['torch','--index-url','https://download.pytorch.org/whl/cu126'],"numpy"]]
    scheduler:  Literal["slurm","openPBS"]
    payload: BinaryByteSize = '4 GB'
    method: Literal["broadcast","roundrobin","allreduce"] = "broadcast"
    warmup: NCCLEvalWarmUp
    min_bandwidth: BandwithSize = '15 GB/s'
    def verify(self)->bool:
        return True

    async def check(self,executor)->bool:
        return await asyncio.get_event_loop().run_in_executor(executor, self._check)


    def _check(self)->tuple[bool,dict]:

        #only uses GPU 0 - this could be randomized or all GPUs could be tested.
        local_rank = 0
        rank=0
        nodes = None
        master_node = None
        match self.scheduler:
            case "slurm":
                rank = int(os.environ["SLURM_PROCID"])
                nodes = asyncio.run(ScontrolCommand().run()).hostnames
                master_node = nodes[0]
            case _:
                raise NotImplementedError("Support for the rquested scheduler has not been implemented.")

        dist.init_process_group(
            backend="nccl",
            init_method="tcp://{}:{}".format(master_node, 6001),
            timeout=datetime.timedelta(seconds=5),
            rank=rank,
            world_size=len(nodes),
        )
        torch.cuda.set_device(local_rank)
        
        tensor = None
        # /4 is for 4 bytes in fp32
        tensor = torch.rand(self.warmup.payload//4, 1, dtype=torch.float32).cuda(local_rank)
        for i in range(self.warmup.runs):
             self.timed_allreduce(local_rank,rank,tensor,self.warmup.payload,len(nodes))

        # /4 is for 4 bytes in fp32
        tensor = torch.rand(self.payload//4, 1, dtype=torch.float32).cuda(local_rank)
        match self.method:
            case "allreduce":
                bandwith = self.timed_allreduce(local_rank,rank,tensor,self.payload,len(nodes))
            case "roundrobin":
                bandwith = self.timed_roundrobin(local_rank,rank,tensor,self.payload,len(nodes))
            case "broadcast":
                bandwith = self.timed_broadcast(local_rank,rank,tensor,self.payload,len(nodes))
            case _:
                raise NotImplementedError("Bandwidth test method not implemented.")
        
        dist.destroy_process_group()
        
        return bandwith > self.min_bandwidth, {"bandwith":f"{conv_to_GBps(bandwith):6.2f} GB/s"}
    

    def timed_allreduce(self,local_rank,rank,tensor,size,ranks):
        
        start_event = torch.cuda.Event(enable_timing=True)
        end_event = torch.cuda.Event(enable_timing=True)
        
        dist.barrier(device_ids=[local_rank])
        start_event.record()
        dist.all_reduce(tensor)
        end_event.record()
        torch.cuda.synchronize()
        duration = start_event.elapsed_time(end_event) / 1000
        bandwith = size/duration        
        return bandwith * (2*(ranks - 1) / ranks)
    
    def timed_roundrobin(self,local_rank,rank,tensor,size,ranks):
        start_event = torch.cuda.Event(enable_timing=True)
        end_event = torch.cuda.Event(enable_timing=True)
        measurments = np.array([])
        for i in range(ranks):
            for j in [j for j in range(ranks) if j != i]:

                #All processes wait here    
                dist.barrier(device_ids=[local_rank])
                
                if rank == i or rank == j:
                    start_event.record()
                    if rank == i:
                        dist.send(tensor=tensor, dst=j)
                    else:
                        dist.recv(tensor=tensor, src=i)
                    end_event.record()
                    torch.cuda.synchronize()
                    duration = start_event.elapsed_time(end_event) / 1000
                    if rank == i:
                        measurments = np.append(measurments, size/duration )     
        return np.mean(measurments) 

    def timed_broadcast(self,local_rank,rank,tensor,size,ranks):
        start_event = torch.cuda.Event(enable_timing=True)
        end_event = torch.cuda.Event(enable_timing=True)
        bandwidth = 0
        for i in range(ranks):
                #All processes wait here    
                dist.barrier(device_ids=[local_rank])
                start_event.record()
                dist.broadcast(tensor, i)
                end_event.record()
                torch.cuda.synchronize()
                duration = start_event.elapsed_time(end_event) / 1000
                if rank == i:
                    bandwidth= size/duration  
        return bandwidth 


