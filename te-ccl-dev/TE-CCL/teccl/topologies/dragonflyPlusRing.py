from teccl.input_data import TopologyParams
from teccl.topologies.topology import Topology

class DragonflyPlusRing(Topology):
    def __init__(self, topo_input: TopologyParams):
        self.leaf_routers = getattr(topo_input, 'leaf_routers', None)
        self.spine_routers = getattr(topo_input, 'spine_routers', None)
        super().__init__(topo_input)
        self.construct_topology(topo_input)

    def construct_topology(self, topo_input: TopologyParams):
        num_groups = topo_input.num_groups
        nodes_per_router = topo_input.hosts_per_router

        if self.leaf_routers is None or self.spine_routers is None:
            raise ValueError("Devi specificare sia leaf_routers che spine_routers in TopologyParams")

        r = self.leaf_routers + self.spine_routers

        speed_leaf = 220 / self.chunk_size
        speed_spine = 80 / self.chunk_size

        alpha_intra = topo_input.alpha[0] if len(topo_input.alpha) > 0 else 1.0
        alpha_global = topo_input.alpha[1] if len(topo_input.alpha) > 1 else alpha_intra * 10

        self.node_per_chassis = num_groups * r * nodes_per_router
        self.capacity = [[0 for _ in range(self.node_per_chassis)] for _ in range(self.node_per_chassis)]
        self.alpha = [[-1 for _ in range(self.node_per_chassis)] for _ in range(self.node_per_chassis)]

        def get_node_id(group, router, local_id):
            return group * r * nodes_per_router + router * nodes_per_router + local_id

        # 1) Host connessi solo ai leaf router (intra-router host connections)
        for group in range(num_groups):
            for leaf in range(self.leaf_routers):
                node_ids = [get_node_id(group, leaf, i) for i in range(nodes_per_router)]
                for i in node_ids:
                    for j in node_ids:
                        if i != j:
                            self.capacity[i][j] = speed_leaf
                            self.alpha[i][j] = alpha_intra

        # 2) Intra-group leaf-spine connections (bipartite completo)
        for group in range(num_groups):
            for leaf in range(self.leaf_routers):
                for spine in range(self.leaf_routers, r):
                    for local_id in range(nodes_per_router):
                        i = get_node_id(group, leaf, local_id)
                        j = get_node_id(group, spine, local_id)
                        self.capacity[i][j] = speed_leaf
                        self.capacity[j][i] = speed_leaf
                        self.alpha[i][j] = alpha_intra
                        self.alpha[j][i] = alpha_intra

        # 3) Global links tra spine router di gruppi diversi (anello)
        # Ogni spine router di un gruppo è collegato al corrispondente spine router del gruppo successivo
        for spine in range(self.leaf_routers, r):
            for g1 in range(num_groups):
                g2 = (g1 + 1) % num_groups  # gruppo successivo in anello
                for local_id in range(nodes_per_router):
                    i = get_node_id(g1, spine, local_id)
                    j = get_node_id(g2, spine, local_id)
                    self.capacity[i][j] = speed_spine
                    self.capacity[j][i] = speed_spine
                    self.alpha[i][j] = alpha_global
                    self.alpha[j][i] = alpha_global

    def set_switch_indicies(self) -> None:
        super().set_switch_indicies()
    

