from teccl.input_data import TopologyParams
from teccl.topologies.topology import Topology
import json

class DragonflyPlus(Topology):
    def __init__(self, topo_input: TopologyParams):
        self.leaf_routers = getattr(topo_input, 'leaf_routers', None)
        self.spine_routers = getattr(topo_input, 'spine_routers', None)
        self.topo_input = topo_input

        # Valore chunk_size per calcolo velocità link
        self.chunk_size = getattr(topo_input, 'chunk_size', 1)

        # >>> NUOVO: fattore di scala per la banda <<<
        self.link_speed = 200
        self.bandwidth_scale = 1


        super().__init__(topo_input)
        # Il costruttore base chiama construct_topology e set_switch_indicies

    def construct_topology(self, topo_input: TopologyParams):
        if self.leaf_routers is None or self.spine_routers is None:
            raise ValueError("Devi specificare sia leaf_routers che spine_routers in TopologyParams")

        num_groups = topo_input.num_groups
        hosts_per_leaf = topo_input.hosts_per_router  # host per leaf router
        leaf_count = self.leaf_routers
        spine_count = self.spine_routers

        total_hosts = num_groups * leaf_count * hosts_per_leaf

        # Indici:
        # hosts: [0, total_hosts-1]
        # leaf routers: [total_hosts, total_hosts + num_groups*leaf_count -1]
        # spine routers: [total_hosts + num_groups*leaf_count, total_hosts + num_groups*leaf_count + num_groups*spine_count -1]

        self.node_per_chassis = total_hosts + num_groups * leaf_count + num_groups * spine_count

        speed_leaf = self.link_speed / self.chunk_size
        speed_spine = (self.bandwidth_scale *  self.link_speed ) / self.chunk_size


        alpha_intra = topo_input.alpha[0] if hasattr(topo_input, 'alpha') and len(topo_input.alpha) > 0 else 1.0
        alpha_global = topo_input.alpha[1] if hasattr(topo_input, 'alpha') and len(topo_input.alpha) > 1 else alpha_intra * 10

        # Inizializza matrici capacity e alpha
        self.capacity = [[0 for _ in range(self.node_per_chassis)] for _ in range(self.node_per_chassis)]
        self.alpha = [[-1 for _ in range(self.node_per_chassis)] for _ in range(self.node_per_chassis)]

        # Liste di nodi per gruppo ottimizzate

        # Hosts per gruppo
        host_nodes_per_group = []
        for group in range(num_groups):
            hosts_in_group = []
            base_host_index = group * leaf_count * hosts_per_leaf
            for leaf in range(leaf_count):
                for h in range(hosts_per_leaf):
                    host_index = base_host_index + leaf * hosts_per_leaf + h
                    hosts_in_group.append(host_index)
            host_nodes_per_group.append(hosts_in_group)

        # Leaf routers per gruppo
        leaf_nodes_per_group = []
        base_leaf_index = total_hosts
        for group in range(num_groups):
            leaves_in_group = []
            for leaf in range(leaf_count):
                leaf_index = base_leaf_index + group * leaf_count + leaf
                leaves_in_group.append(leaf_index)
            leaf_nodes_per_group.append(leaves_in_group)

        # Spine routers per gruppo
        spine_nodes_per_group = []
        base_spine_index = total_hosts + num_groups * leaf_count
        for group in range(num_groups):
            spines_in_group = []
            for spine in range(spine_count):
                spine_index = base_spine_index + group * spine_count + spine
                spines_in_group.append(spine_index)
            spine_nodes_per_group.append(spines_in_group)

        # --- Popolazione matrici ---

        # 1) No collegamenti host-host: ignorati!

        # 2) Collegamenti host-leaf router
        for group in range(num_groups):
            for leaf in range(leaf_count):
                leaf_node = leaf_nodes_per_group[group][leaf]
                for h in range(hosts_per_leaf):
                    host_node = host_nodes_per_group[group][leaf * hosts_per_leaf + h]
                    self.capacity[host_node][leaf_node] = speed_leaf
                    self.capacity[leaf_node][host_node] = speed_leaf
                    self.alpha[host_node][leaf_node] = alpha_intra
                    self.alpha[leaf_node][host_node] = alpha_intra

        # 3) Connessioni bipartite leaf-spine dentro lo stesso gruppo
        for group in range(num_groups):
            for leaf_node in leaf_nodes_per_group[group]:
                for spine_node in spine_nodes_per_group[group]:
                    self.capacity[leaf_node][spine_node] = speed_leaf
                    self.capacity[spine_node][leaf_node] = speed_leaf
                    self.alpha[leaf_node][spine_node] = alpha_intra
                    self.alpha[spine_node][leaf_node] = alpha_intra

        # 4) Connessioni spine-spine tra gruppi diversi (mesh completa)
        for spine_idx in range(spine_count):
            for g1 in range(num_groups):
                node_g1 = spine_nodes_per_group[g1][spine_idx]
                for g2 in range(g1 + 1, num_groups):
                    node_g2 = spine_nodes_per_group[g2][spine_idx]
                    self.capacity[node_g1][node_g2] = speed_spine
                    self.capacity[node_g2][node_g1] = speed_spine
                    self.alpha[node_g1][node_g2] = alpha_global
                    self.alpha[node_g2][node_g1] = alpha_global

        # Assicuriamoci che capacity[i][i] = 0 e alpha[i][i] = -1 (no autocollegamenti)
        for i in range(self.node_per_chassis):
            self.capacity[i][i] = 0
            self.alpha[i][i] = -1

        # Stampa mapping host->leaf->spine per debug
        #print("Mappatura host -> leaf -> spine per gruppo (ottimizzata):")
        for group in range(num_groups):
            for leaf in range(leaf_count):
                leaf_node = leaf_nodes_per_group[group][leaf]
                spine_nodes = spine_nodes_per_group[group]
                for h in range(hosts_per_leaf):
                    host_node = host_nodes_per_group[group][leaf * hosts_per_leaf + h]
                    #print(f"Gruppo {group} - Host node {host_node} collegato a Leaf node {leaf_node} con spine nodes {spine_nodes}")


    def set_switch_indicies(self) -> None:
        self.switch_indices = []
        if not hasattr(self, 'topo_input'):
            raise ValueError("self.topo_input non presente, serve per set_switch_indicies")

        num_groups = self.topo_input.num_groups
        hosts_per_leaf = self.topo_input.hosts_per_router
        leaf_count = self.leaf_routers
        spine_count = self.spine_routers

        total_hosts = num_groups * leaf_count * hosts_per_leaf

        base_leaf_index = total_hosts  # leaf routers start after all hosts
        base_spine_index = total_hosts + num_groups * leaf_count  # spine routers start after leaf routers

        # Inserisci leaf router come switch
        for group in range(num_groups):
            for leaf in range(leaf_count):
                node_id = base_leaf_index + group * leaf_count + leaf
                self.switch_indices.append(node_id)

        # Inserisci spine router come switch
        for group in range(num_groups):
            for spine in range(spine_count):
                node_id = base_spine_index + group * spine_count + spine
                self.switch_indices.append(node_id)

        self.switch_indices = sorted(set(self.switch_indices))

    def get_hosts(self) -> list:
        all_nodes = set(range(self.node_per_chassis))
        switches = set(self.switch_indices)
        hosts = list(all_nodes - switches)
        hosts.sort()
        return 

    def save_hosts_to_json(self, num_groups, leaf_count, hosts_per_leaf, nodes_per_group):
        host_list = []
        for group in range(num_groups):
            base = group * nodes_per_group
            for leaf in range(leaf_count):
                for h in range(hosts_per_leaf):
                    host_node = base + leaf * hosts_per_leaf + h
                    host_list.append(host_node)

        host_dict = {"host": host_list}

        with open("hosts.json", "w") as json_file:
            json.dump(host_dict, json_file, indent=4)
