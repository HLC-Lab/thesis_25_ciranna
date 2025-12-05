from teccl.input_data import TopologyParams
from teccl.topologies.topology import Topology

class Star(Topology):
    def __init__(self, topo_input: TopologyParams):
        super().__init__(topo_input)
        self.construct_topology(topo_input)

    def construct_topology(self, topo_input: TopologyParams):
            self.central_switch = 1
            leaf_switches = topo_input.leaf_routers
            hosts_per_switch = topo_input.hosts_per_router

            self.node_per_chassis = leaf_switches * hosts_per_switch + self.central_switch
            self.capacity = [[0] * self.node_per_chassis for _ in range(self.node_per_chassis)]
            self.alpha = [[-1] * self.node_per_chassis for _ in range(self.node_per_chassis)]

            speed = 100 / topo_input.chunk_size  # Velocità unica per tutti i link

            central_idx = 0
            for leaf in range(leaf_switches):  # da 0 a leaf_switches-1
                for host in range(hosts_per_switch):
                    node_idx = 1 + leaf * hosts_per_switch + host  # shift di +1 per saltare nodo centrale
                    self.capacity[central_idx][node_idx] = speed
                    self.capacity[node_idx][central_idx] = speed
                    self.alpha[central_idx][node_idx] = topo_input.alpha[0]
                    self.alpha[node_idx][central_idx] = topo_input.alpha[0]


    def set_switch_indicies(self) -> None:
        super().set_switch_indicies()
