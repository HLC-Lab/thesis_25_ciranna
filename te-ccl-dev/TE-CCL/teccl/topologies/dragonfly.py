
from teccl.input_data import TopologyParams
from teccl.topologies.topology import Topology


class Dragonfly(Topology):
    def __init__(self, topo_input: TopologyParams):
        super().__init__(topo_input)
        self.construct_topology(topo_input)

    def construct_topology(self, topo_input: TopologyParams):
        num_groups = topo_input.num_groups
        routers_per_group = topo_input.routers_per_group
        nodes_per_router = topo_input.hosts_per_router

        speed = 100 / self.chunk_size
        alpha_intra = topo_input.alpha[0] if len(topo_input.alpha) > 0 else 1.0
        alpha_global = topo_input.alpha[1] if len(topo_input.alpha) > 1 else alpha_intra * 10

        self.node_per_chassis = num_groups * routers_per_group * nodes_per_router
        self.capacity = [[0 for _ in range(self.node_per_chassis)] for _ in range(self.node_per_chassis)]
        self.alpha = [[-1 for _ in range(self.node_per_chassis)] for _ in range(self.node_per_chassis)]

        def get_node_id(group, router, local_id):
            return group * routers_per_group * nodes_per_router + router * nodes_per_router + local_id

        # 1) Intra-router connections (host-to-host within same router)
        for group in range(num_groups):
            for router in range(routers_per_group):
                node_ids = [get_node_id(group, router, i) for i in range(nodes_per_router)]
                for i in node_ids:
                    for j in node_ids:
                        if i != j:
                            self.capacity[i][j] = speed
                            self.alpha[i][j] = alpha_intra

        # 2) Intra-group router connections (full mesh between routers in the same group)
        for group in range(num_groups):
            for r1 in range(routers_per_group):
                for r2 in range(r1 + 1, routers_per_group):
                    for local_id in range(nodes_per_router):
                        i = get_node_id(group, r1, local_id)
                        j = get_node_id(group, r2, local_id)
                        self.capacity[i][j] = speed
                        self.capacity[j][i] = speed
                        self.alpha[i][j] = alpha_intra
                        self.alpha[j][i] = alpha_intra

        # 3) Inter-group global links (fully connect routers with same index across groups)
        # For each router index, connect corresponding routers in all groups in a ring or full mesh
        for router in range(routers_per_group):
            for g1 in range(num_groups):
                for g2 in range(g1 + 1, num_groups):
                    for local_id in range(nodes_per_router):
                        i = get_node_id(g1, router, local_id)
                        j = get_node_id(g2, router, local_id)
                        self.capacity[i][j] = speed
                        self.capacity[j][i] = speed
                        self.alpha[i][j] = alpha_global
                        self.alpha[j][i] = alpha_global

    def set_switch_indicies(self) -> None:
        super().set_switch_indicies()


