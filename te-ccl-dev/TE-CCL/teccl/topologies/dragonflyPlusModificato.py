from teccl.input_data import TopologyParams
from teccl.topologies.topology import Topology

class DragonflyPlus(Topology):
    def __init__(self, topo_input: TopologyParams):
        # Inizializza prima gli attributi
        self.leaf_routers = getattr(topo_input, 'leaf_routers', None)
        self.spine_routers = getattr(topo_input, 'spine_routers', None)
        # Poi chiama il costruttore base
        super().__init__(topo_input)
        self.construct_topology(topo_input)

    def construct_topology(self, topo_input: TopologyParams):
        num_groups = topo_input.num_groups
        nodes_per_router = topo_input.hosts_per_router

        # Verifica che leaf e spine siano specificati
        if self.leaf_routers is None or self.spine_routers is None:
            raise ValueError("Devi specificare sia leaf_routers che spine_routers in TopologyParams")

        # Calcola dimensione gruppo come somma di leaf e spine
        r = self.leaf_routers + self.spine_routers

        # Velocità differenziate
        speed_leaf = 220 / self.chunk_size    # velocità link leaf (host-host e leaf-spine)
        speed_spine = 80 / self.chunk_size    # velocità link spine (globali)

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

        # 3) Global links tra spine router di gruppi diversi (fully connected)
        for spine in range(self.leaf_routers, r):
            for g1 in range(num_groups):
                for g2 in range(g1 + 1, num_groups):
                    for local_id in range(nodes_per_router):
                        i = get_node_id(g1, spine, local_id)
                        j = get_node_id(g2, spine, local_id)
                        self.capacity[i][j] = speed_spine
                        self.capacity[j][i] = speed_spine
                        self.alpha[i][j] = alpha_global
                        self.alpha[j][i] = alpha_global

    def set_switch_indicies(self) -> None:
        """
        Imposta la lista degli indici dei nodi che sono switch (router) nella topologia.
        Nel DragonflyPlus, tipicamente:
        - I nodi associati ai leaf router (intermedi fra host e spine) sono switch
        - I nodi associati ai spine router sono switch
        - Gli host sono quelli connessi ai leaf router (ossia i nodi locali a ciascun leaf router)
        """

        self.switch_indices = []
        num_groups = getattr(self.topo_input, 'num_groups', None)
        if num_groups is None:
            raise ValueError("Devi specificare num_groups in TopologyParams")

        r = self.leaf_routers + self.spine_routers
        nodes_per_router = self.topo_input.hosts_per_router

        # I nodi sono indicizzati come: group * r * nodes_per_router + router * nodes_per_router + local_id

        # Gli host sono i nodi con router < leaf_routers, quindi i nodi router (leaf e spine) sono quelli con router >= 0 fino a r-1, ma
        # consideriamo switch sia i router leaf che spine.

        # Per tutti i gruppi, consideriamo come switch i nodi associati ai router leaf e spine (ossia tutti i router),
        # ovvero tutti i nodi che rappresentano router, non gli host interni (local_id nei router)

        for group in range(num_groups):
            for router in range(r):
                # Per ogni router (leaf o spine), i nodi corrispondenti sono tutti i local_id ma non sono host, bensì switch
                # In DragonflyPlus però gli host sono considerati i nodi local_id < hosts_per_router solo sui leaf router
                # quindi i nodi switch sono tutti quelli associati ai router interi (senza host)

                # Assumiamo che ogni router sia un nodo switch a prescindere dai local_id
                # Se la topologia rappresenta router come nodi singoli non con host al loro interno, prende i nodi dei router stessi.

                # Però nella tua definizione il nodo rappresenta ognuno un host o router: 
                # la differenza è nel valore di router: router < leaf_routers -> host (local_id sono nodi host), router >= leaf_routers sono spine router
                # ALLORA switch_indices sono TUTTI i nodi con router >= leaf_routers (spine router) 
                # ed eventualmente i router leaf se li consideri switch (dipende dal modello).

                # Poiché già nel costruttore consideri host come i nodi con router < leaf_routers e local_id
                # allora switch_indices sono i nodi con router >= leaf_routers (spine router) + *(opzionale)* anche i leaf router se li vuoi considerare switch.

                if router >= self.leaf_routers:
                    # spine router → tutti i nodi (local_id) associati sono switch
                    for local_id in range(nodes_per_router):
                        node_id = group * r * nodes_per_router + router * nodes_per_router + local_id
                        self.switch_indices.append(node_id)

        # Se vuoi considerare anche i leaf router come switch (escludendo solo gli host veri), aggiungi qui:
        # Aggiunta dei leaf router come switch (cioè tutti i nodi dei leaf router)
        for group in range(num_groups):
            for router in range(self.leaf_routers):
                for local_id in range(nodes_per_router):
                    node_id = group * r * nodes_per_router + router * nodes_per_router + local_id
                    # Se vuoi escludere gli host effettivi, ma nella tua definizione host sono locali ai leaf router,
                    # sono quelli con router < leaf_routers e local_id sotto qualche soglia (es 0?), ma probabilmente sono gli host. 
                    # Perciò se consideri switch solo i nodi con local_id che rappresentano router e non gli host
                    # devi filtrare local_id per escludere quelli che rappresentano host
                    # Nella topologia DragonflyPlus come definita, **gli host sono infatti tutti i local_id dei leaf router**,
                    # quindi non li aggiungiamo come switch. 
                    # Quindi NON aggiungere questi nodi come switch qui.
                    pass

        # Se vuoi escludere gli host reali e considerare solo spine router come switch lasci solo la parte sopra.

        # Elimina eventuali duplicati
        self.switch_indices = list(set(self.switch_indices))
        self.switch_indices.sort()
