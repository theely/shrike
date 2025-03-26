from typing import Literal, Optional

import socket
from vetnode.evaluations.base_eval import BaseEval


class InternetAccessEval(BaseEval):
    name:str
    type: Literal["vetnode.evaluations.internet_access.InternetAccessEval"]
    host:str
    port:Optional[int]=53
    timeout:Optional[int]=3

    async def check(self,executor)->bool:
        socket.setdefaulttimeout(self.timeout)
        socket.socket(socket.AF_INET, socket.SOCK_STREAM).connect((self.host, self.port))
        return True
